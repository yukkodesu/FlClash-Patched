import 'dart:async';

import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingListener with CoreEventListener {
  _RecordingListener({this.onLoadedCallback});

  final void Function()? onLoadedCallback;
  final List<String> loaded = [];
  final List<Log> logs = [];

  @override
  void onLog(Log log) {
    logs.add(log);
  }

  @override
  void onLoaded(String providerName) {
    loaded.add(providerName);
    onLoadedCallback?.call();
  }
}

class _HeldFailingListener with CoreEventListener {
  final released = Completer<void>();

  @override
  Future<void> onLoaded(String providerName) async {
    await released.future;
    throw StateError('Listener failed asynchronously');
  }
}

void main() {
  test(
    'async listener failures are isolated without delaying other listeners',
    () async {
      final errors = <Object>[];
      final failing = _HeldFailingListener();
      final healthy = _RecordingListener();
      coreEventManager.addListener(failing);
      coreEventManager.addListener(healthy);
      addTearDown(() {
        coreEventManager.removeListener(failing);
        coreEventManager.removeListener(healthy);
      });
      await runZonedGuarded(() async {
        coreEventManager.sendEvent(
          const CoreEvent(type: CoreEventType.loaded, data: 'provider-a'),
        );
        await pumpEventQueue();
        expect(healthy.loaded, ['provider-a']);
        failing.released.complete();
        await pumpEventQueue();
        coreEventManager.sendEvent(
          const CoreEvent(type: CoreEventType.loaded, data: 'provider-b'),
        );
        await pumpEventQueue();
        expect(healthy.loaded, ['provider-a', 'provider-b']);
      }, (error, _) => errors.add(error));
      expect(errors, isEmpty);
    },
  );

  test('live Core logs carry the Core source', () async {
    final listener = _RecordingListener();
    coreEventManager.addListener(listener);
    addTearDown(() => coreEventManager.removeListener(listener));

    coreEventManager.sendEvent(
      const CoreEvent(
        type: CoreEventType.log,
        data: {'LogLevel': 'info', 'Payload': 'Core log'},
      ),
    );
    await pumpEventQueue();

    final log = listener.logs.single;
    expect(log.source, LogSource.core);
    expect(log.logLevel, LogLevel.info);
    expect(log.payload, 'Core log');
    expect(LogsState(logs: [log], sources: {LogSource.app}).list, isEmpty);
    expect(LogsState(logs: [log], sources: {LogSource.core}).list, [log]);
  });

  test(
    'a listener may unregister itself while an event is dispatched',
    () async {
      late _RecordingListener first;
      final second = _RecordingListener();
      first = _RecordingListener(
        onLoadedCallback: () => coreEventManager.removeListener(first),
      );

      coreEventManager.addListener(first);
      coreEventManager.addListener(second);
      addTearDown(() {
        coreEventManager.removeListener(first);
        coreEventManager.removeListener(second);
      });

      coreEventManager.sendEvent(
        const CoreEvent(type: CoreEventType.loaded, data: 'provider-a'),
      );
      await pumpEventQueue();

      expect(first.loaded, ['provider-a']);
      expect(second.loaded, ['provider-a']);

      coreEventManager.sendEvent(
        const CoreEvent(type: CoreEventType.loaded, data: 'provider-b'),
      );
      await pumpEventQueue();

      expect(first.loaded, ['provider-a']);
      expect(second.loaded, ['provider-a', 'provider-b']);
    },
  );
}
