import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/core/desktop/launcher.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native startup stderr is decoded as a plain Core error', () async {
    final bytes = utf8.encode(
      '\u001b[31mError: 内核 initialization failed\u001b[0m\n',
    );
    final process = _FakeProcess(
      pid: 42,
      exitCode: Future.value(1),
      stderr: Stream.fromIterable([bytes.sublist(0, 14), bytes.sublist(14)]),
    );
    final listener = _LogEvents();
    coreEventManager.addListener(listener);
    try {
      final launcher = DirectCoreLauncher(
        startProcess: (_, _) async => process,
        corePath: 'FlClashMeowCore',
      );
      await launcher.start(sessionId: 'session', address: 'address');
      final log = await listener.first.future.timeout(
        const Duration(seconds: 1),
      );
      expect(log.source, LogSource.core);
      expect(log.logLevel, LogLevel.error);
      expect(log.payload, 'Error: 内核 initialization failed');
    } finally {
      coreEventManager.removeListener(listener);
    }
  });

  test(
    'observing native exit releases a direct lease without killing it',
    () async {
      final exited = Completer<int>();
      final process = _FakeProcess(pid: 42, exitCode: exited.future);
      final lease = DirectCoreLease(
        sessionId: '0123456789abcdef0123456789abcdef',
        process: process,
      );
      final waiting = lease.waitForExit(const Duration(seconds: 1));
      expect(process.killed, isFalse);
      exited.complete(0);
      expect(await waiting, isTrue);

      expect(
        await lease.stop(const Duration(seconds: 1)),
        const CoreProcessStopResult(stopped: false, exitConfirmed: true),
      );
      expect(process.killed, isFalse);
    },
  );

  test('createCoreSessionId returns lowercase 128-bit hex', () {
    expect(createCoreSessionId(), matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('direct lease kills and confirms the owned process exit', () async {
    final process = _FakeProcess(pid: 42, exitCode: Future.value(0));
    String? executable;
    List<String>? arguments;
    final launcher = DirectCoreLauncher(
      startProcess: (value, valueArguments) async {
        executable = value;
        arguments = valueArguments;
        return process;
      },
      corePath: 'FlClashCore',
    );

    final lease = await launcher.start(
      sessionId: '0123456789abcdef0123456789abcdef',
      address: 'test-address',
    );
    final result = await lease.stop(const Duration(seconds: 1));

    expect(lease.owner, CoreProcessOwner.direct);
    expect(lease.pid, 42);
    expect(executable, 'FlClashCore');
    expect(arguments, ['test-address']);
    expect(process.killed, isTrue);
    expect(
      result,
      const CoreProcessStopResult(stopped: true, exitConfirmed: true),
    );
  });

  test('direct lease reports an unconfirmed exit after timeout', () async {
    final process = _FakeProcess(pid: 42, exitCode: Completer<int>().future);
    final launcher = DirectCoreLauncher(
      startProcess: (_, _) async => process,
      corePath: 'FlClashCore',
    );
    final lease = await launcher.start(
      sessionId: '0123456789abcdef0123456789abcdef',
      address: 'test-address',
    );

    final result = await lease.stop(Duration.zero);

    expect(result.stopped, isTrue);
    expect(result.exitConfirmed, isFalse);
  });

  test('direct lease rechecks exit after an unconfirmed timeout', () async {
    final exitCode = Completer<int>();
    final process = _FakeProcess(pid: 42, exitCode: exitCode.future);
    final launcher = DirectCoreLauncher(
      startProcess: (_, _) async => process,
      corePath: 'FlClashCore',
    );
    final lease = await launcher.start(
      sessionId: '0123456789abcdef0123456789abcdef',
      address: 'test-address',
    );

    final firstResult = await lease.stop(Duration.zero);
    exitCode.complete(0);
    final secondResult = await lease.stop(const Duration(seconds: 1));

    expect(firstResult.exitConfirmed, isFalse);
    expect(secondResult.exitConfirmed, isTrue);
  });
}

class _FakeProcess implements Process {
  @override
  final int pid;

  @override
  final Future<int> exitCode;

  @override
  final Stream<List<int>> stdout = const Stream.empty();

  @override
  final Stream<List<int>> stderr;

  bool killed = false;

  _FakeProcess({
    required this.pid,
    required this.exitCode,
    this.stderr = const Stream.empty(),
  });

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _LogEvents with CoreEventListener {
  final first = Completer<Log>();

  @override
  void onLog(Log log) {
    if (!first.isCompleted) first.complete(log);
  }
}
