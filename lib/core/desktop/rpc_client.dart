import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter/foundation.dart' show compute, visibleForTesting;

import 'transport.dart';
import 'model.dart';

/// How many timeout windows a request may be extended across while Core keeps
/// answering other requests, before it fails regardless.
const _maxTimeoutExtension = 3;

const _maxExtensionGrace = Duration(seconds: 30);

const _connectTimeout = Duration(seconds: 10);

const _backgroundDecodeThreshold = 51200;

Map<String, Object?> _decodeFrame(Uint8List frame) {
  final decoded = json.decode(utf8.decode(frame));
  if (decoded is! Map) {
    throw const FormatException('Core transport data is not an object');
  }
  return Map<String, Object?>.from(decoded);
}

abstract interface class CoreRpcChannel {
  Future<T?> invoke<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  });

  void beginShutdown();

  Future<void> close();
}

final class CoreRpcClient implements CoreRpcChannel {
  final DesktopCoreTransport transport;
  final Duration extensionGrace;
  final Map<String, Completer<Object?>> _pending = {};
  late final StreamSubscription<Uint8List> _frameSubscription;
  late final StreamSubscription<DesktopTransportEvent> _eventSubscription;

  int _methodCallId = 0;
  bool _shutdownRequested = false;
  bool _stoppingSession = false;
  String? _shutdownId;
  Completer<Object?>? _shutdownResponse;
  Future<void>? _closeOperation;
  Future<void> _frameWork = Future<void>.value();
  int _frameGeneration = 0;
  int? _connectionGeneration;

  /// Time since Core last answered any request. A method timeout is a liveness
  /// guard for a stalled link (a restart mid-flight, a stream that stopped
  /// carrying data), not a budget for how long a single method may take — so a
  /// request that is still waiting while Core demonstrably keeps replying to
  /// its siblings gets its window re-armed instead of being failed.
  final Stopwatch _sinceLastResponse = Stopwatch()..start();

  CoreRpcClient(
    this.transport, {
    @visibleForTesting this.extensionGrace = _maxExtensionGrace,
  }) {
    _frameSubscription = transport.frames.listen(
      _handleFrame,
      onError: _handleFrameError,
    );
    _eventSubscription = transport.events.listen(_handleTransportEvent);
  }

  int get pendingCount => _pending.length;

  @override
  Future<T?> invoke<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) async {
    if (_shutdownRequested || _stoppingSession) {
      return null;
    }
    final id = '${++_methodCallId}';
    final completer = Completer<Object?>();
    _pending[id] = completer;
    final requestTimeout = timeout ?? const Duration(minutes: 3);
    final stopwatch = Stopwatch()..start();
    try {
      final connection = await Future.any<Object?>([
        transport.waitUntilConnected(_shorter(_connectTimeout, requestTimeout)),
        completer.future,
      ]);
      if (completer.isCompleted) {
        return await completer.future as T?;
      }
      if (connection is TransportConnected) {
        _connectionGeneration = connection.generation;
      }
      final sendTimeout = requestTimeout - stopwatch.elapsed;
      if (sendTimeout <= Duration.zero) {
        throw TimeoutException('Core method ${method.name} timed out');
      }
      await transport
          .send(
            json.encode(
              CoreMethodCall(id: id, method: method, arguments: arguments),
            ),
          )
          .timeout(sendTimeout);
      return await _awaitResponse(
            method: method,
            completer: completer,
            idleTimeout: requestTimeout,
            elapsed: stopwatch,
          )
          as T?;
    } on TimeoutException {
      commonPrint.log(
        'Core method ${method.name} timed out after '
        '${stopwatch.elapsedMilliseconds}ms',
        logLevel: LogLevel.warning,
      );
      _removePending(id, completer);
      return null;
    } on CoreMethodException {
      _pending.remove(id);
      rethrow;
    } catch (error) {
      _removePending(id, completer);
      if (_shutdownRequested || _stoppingSession) {
        return null;
      }
      throw CoreMethodException(
        code: 'transport_error',
        message: 'Unable to send ${method.name} to Core',
        details: error.toString(),
      );
    } finally {
      stopwatch.stop();
    }
  }

  /// Waits for [completer], re-arming the window every time Core proves the
  /// link is still alive by answering some other request, so a slow method is
  /// not failed on behalf of a healthy link. Two things still end the wait:
  /// [idleTimeout] of silence, and a hard deadline set by whichever of
  /// [_maxTimeoutExtension] windows and [extensionGrace] on top binds first —
  /// a Core answering everything except this request has to surface as well.
  Future<Object?> _awaitResponse({
    required CoreMethod method,
    required Completer<Object?> completer,
    required Duration idleTimeout,
    required Stopwatch elapsed,
  }) async {
    final hardDeadline = _shorter(
      idleTimeout * _maxTimeoutExtension,
      idleTimeout + extensionGrace,
    );
    while (true) {
      // Silence is measured from the last response or from this request's own
      // start, whichever is later: an idle app must not shorten a fresh window.
      final silence = _shorter(_sinceLastResponse.elapsed, elapsed.elapsed);
      final remaining = _shorter(
        idleTimeout - silence,
        hardDeadline - elapsed.elapsed,
      );
      if (remaining <= Duration.zero) {
        throw TimeoutException('Core method ${method.name} timed out');
      }
      try {
        return await completer.future.timeout(remaining);
      } on TimeoutException {
        continue;
      }
    }
  }

  static Duration _shorter(Duration a, Duration b) => a < b ? a : b;

  Future<void> shutdownSession(
    DesktopCoreSession session,
    Duration timeout,
  ) async {
    _stoppingSession = true;
    _completePending();
    final response = Completer<Object?>();
    response.future.ignore();
    final id = '${++_methodCallId}';
    _shutdownId = id;
    _shutdownResponse = response;
    try {
      await (() async {
        if (transport.state != DesktopTransportState.connected) {
          throw const CoreMethodException(
            code: 'transport_disconnected',
            message: 'Core session is no longer connected',
          );
        }
        final connection = await transport.waitUntilConnected(timeout);
        if (!identical(_shutdownResponse, response) ||
            connection.generation != session.connectionGeneration ||
            (connection.pid != null && connection.pid != session.pid)) {
          throw StateError('Core shutdown connection does not match its lease');
        }
        _connectionGeneration = connection.generation;
        await transport.send(
          json.encode(CoreMethodCall(id: id, method: CoreMethod.shutdown)),
        );
        if (await response.future != true) {
          throw StateError('Core did not confirm resource cleanup');
        }
      })().timeout(timeout);
    } finally {
      if (identical(_shutdownResponse, response)) {
        _shutdownId = null;
        _shutdownResponse = null;
      }
    }
  }

  void _removePending(String id, Completer<Object?> completer) {
    final removed = _pending.remove(id);
    if (identical(removed, completer) && !completer.isCompleted) {
      completer.complete(null);
    }
  }

  void _handleFrame(Uint8List frame) {
    final generation = _frameGeneration;
    _frameWork = _frameWork.then((_) => _processFrame(frame, generation));
  }

  Future<void> _processFrame(Uint8List frame, int generation) async {
    if (generation != _frameGeneration) return;
    try {
      final data = frame.length >= _backgroundDecodeThreshold
          ? await compute(_decodeFrame, frame, debugLabel: 'Core IPC decode')
          : _decodeFrame(frame);
      if (generation != _frameGeneration) return;
      if (data.containsKey('method')) {
        if (!_shutdownRequested && !_stoppingSession) {
          _handleMethodCall(CoreMethodCall.fromJson(data));
        }
      } else {
        _handleResponse(CoreMethodResponse.fromJson(data));
      }
    } catch (error) {
      commonPrint.log(
        'Failed to parse transport data: $error',
        logLevel: LogLevel.error,
      );
    }
  }

  void _handleMethodCall(CoreMethodCall call) {
    if (call.method != CoreMethod.message) {
      commonPrint.log(
        'Unknown core callback method: ${call.method.name}',
        logLevel: LogLevel.warning,
      );
      return;
    }
    for (final event in coreEventsFromData(call.arguments)) {
      coreEventManager.sendEvent(event);
    }
  }

  void _handleResponse(CoreMethodResponse response) {
    // Proof of life for every pending request, including a late response whose
    // own caller already gave up.
    _sinceLastResponse
      ..reset()
      ..start();
    final id = response.id;
    final completer = id == _shutdownId
        ? _shutdownResponse
        : id == null
        ? null
        : _pending.remove(id);
    if (completer == null || completer.isCompleted) {
      return;
    }
    final error = response.error;
    if (error != null) {
      completer.completeError(
        CoreMethodException(
          code: error.code,
          message: error.message,
          details: error.details,
        ),
      );
      return;
    }
    completer.complete(response.result);
  }

  void _handleFrameError(Object error, StackTrace stackTrace) {
    commonPrint.log(
      'Transport data stream error: $error',
      logLevel: LogLevel.debug,
    );
  }

  void _handleTransportEvent(DesktopTransportEvent event) {
    switch (event) {
      case TransportDisconnected(:final generation):
        if (_connectionGeneration != null &&
            generation != _connectionGeneration) {
          return;
        }
        const error = CoreMethodException(
          code: 'transport_disconnected',
          message: 'Core transport disconnected',
        );
        if (_stoppingSession) {
          unawaited(
            _frameWork.then((_) {
              if (_connectionGeneration == generation) _disconnect(error);
            }),
          );
        } else {
          _disconnect(error);
        }
      case TransportFailed(:final error):
        _invalidateFrames();
        _failPending(
          CoreMethodException(
            code: 'transport_error',
            message: 'Core transport failed',
            details: error.toString(),
          ),
        );
      case TransportConnected(:final generation):
        _connectionGeneration = generation;
        _stoppingSession = false;
      case TransportReady():
        break;
    }
  }

  void _disconnect(CoreMethodException error) {
    _invalidateFrames();
    _failPending(error);
  }

  void _invalidateFrames() {
    _frameGeneration++;
    _frameWork = Future<void>.value();
  }

  void _failPending(CoreMethodException error) {
    final completers = _pending.values.toList(growable: false);
    _pending.clear();
    for (final completer in completers) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    final shutdown = _shutdownResponse;
    if (shutdown != null && !shutdown.isCompleted) {
      shutdown.completeError(error);
    }
  }

  void _completePending() {
    final completers = _pending.values.toList(growable: false);
    _pending.clear();
    for (final completer in completers) {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    }
  }

  @override
  void beginShutdown() {
    if (_shutdownRequested) {
      return;
    }
    _shutdownRequested = true;
    if (!_stoppingSession) _invalidateFrames();
    _completePending();
  }

  @override
  Future<void> close() {
    return _closeOperation ??= _close();
  }

  Future<void> _close() async {
    beginShutdown();
    await _frameSubscription.cancel();
    await _eventSubscription.cancel();
  }
}
