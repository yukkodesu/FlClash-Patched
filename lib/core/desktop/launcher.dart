import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';

import 'model.dart';

typedef CoreProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

abstract interface class CoreProcessLauncher {
  Future<CoreProcessLease> start({
    required String sessionId,
    required String address,
  });
}

abstract interface class DesktopCoreLauncherResolver {
  Future<CoreProcessLauncher> resolve();
}

final class DirectCoreLauncher implements CoreProcessLauncher {
  final CoreProcessStarter _startProcess;
  final String corePath;

  DirectCoreLauncher({CoreProcessStarter? startProcess, String? corePath})
    : _startProcess = startProcess ?? Process.start,
      corePath = corePath ?? appPath.corePath;

  @override
  Future<CoreProcessLease> start({
    required String sessionId,
    required String address,
  }) async {
    final process = await _startProcess(corePath, [address]);
    process.stdout.listen((_) {});
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          final error = line
              .replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '')
              .trim();
          if (error.isNotEmpty) {
            coreEventManager.sendEvent(
              CoreEvent(
                type: CoreEventType.log,
                data: {'LogLevel': LogLevel.error.name, 'Payload': error},
              ),
            );
          }
        });
    return DirectCoreLease(sessionId: sessionId, process: process);
  }
}

final class DirectCoreLease implements CoreProcessLease {
  @override
  final String sessionId;

  final Process _process;
  Future<CoreProcessStopResult>? _stopOperation;
  bool _exitConfirmed = false;

  DirectCoreLease({required this.sessionId, required Process process})
    : _process = process;

  @override
  CoreProcessOwner get owner => CoreProcessOwner.direct;

  @override
  int get pid => _process.pid;

  @override
  Future<bool> waitForExit(Duration timeout) async {
    if (_exitConfirmed) return true;
    try {
      await _process.exitCode.timeout(timeout);
      return _exitConfirmed = true;
    } on TimeoutException {
      return false;
    }
  }

  @override
  Future<CoreProcessStopResult> stop(Duration timeout) {
    final stopOperation = _stopOperation;
    if (stopOperation != null) {
      return stopOperation;
    }
    final nextOperation = _stop(timeout).then((result) {
      if (!result.exitConfirmed) {
        _stopOperation = null;
      }
      return result;
    });
    _stopOperation = nextOperation;
    return nextOperation;
  }

  Future<CoreProcessStopResult> _stop(Duration timeout) async {
    if (_exitConfirmed) {
      return const CoreProcessStopResult(stopped: false, exitConfirmed: true);
    }
    final stopped = _process.kill();
    return CoreProcessStopResult(
      stopped: stopped,
      exitConfirmed: await waitForExit(timeout),
    );
  }
}
