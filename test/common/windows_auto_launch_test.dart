import 'dart:typed_data';

import 'package:fl_clash/common/windows_auto_launch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win32/win32.dart';
import 'package:win32_registry/win32_registry.dart';

const _product = 'FlClash-Meow';
const _executable = r'C:\Program Files\FlClash-Meow\FlClash-Meow.exe';

class _Registry {
  final values = <WindowsStartupKey, Map<String, RegistryValue>>{};
  WindowsStartupKey? deniedKey;
  WindowsStartupKey? failedWrite;
  WindowsStartupKey? failedRemove;
  bool denyWrites = false;
  int opened = 0;
  int closed = 0;

  WindowsStartupKeyHandle open(
    WindowsStartupKey key, {
    required bool create,
    required bool writable,
  }) {
    if (key == deniedKey || (writable && denyWrites)) {
      throw WindowsException(ERROR_ACCESS_DENIED.toHRESULT());
    }
    final entries = values[key];
    if (entries == null && !create) {
      throw WindowsException(ERROR_FILE_NOT_FOUND.toHRESULT());
    }
    opened++;
    return _Handle(this, key, values.putIfAbsent(key, () => {}), writable);
  }
}

class _Handle implements WindowsStartupKeyHandle {
  _Handle(this.registry, this.key, this.values, this.writable);

  final _Registry registry;
  final WindowsStartupKey key;
  final Map<String, RegistryValue> values;
  final bool writable;

  @override
  RegistryValue? read(String name) => values[name];

  @override
  void write(String name, RegistryValue value) {
    expect(writable, isTrue);
    if (key == registry.failedWrite) {
      throw WindowsException(ERROR_ACCESS_DENIED.toHRESULT());
    }
    values[name] = value;
  }

  @override
  void remove(String name) {
    expect(writable, isTrue);
    if (key == registry.failedRemove) {
      throw WindowsException(ERROR_ACCESS_DENIED.toHRESULT());
    }
    values.remove(name);
  }

  @override
  void close() => registry.closed++;
}

void main() {
  late _Registry registry;
  late WindowsAutoLaunch launcher;

  setUp(() {
    registry = _Registry();
    launcher = WindowsAutoLaunch(openKey: registry.open)
      ..setup(appName: _product, appPath: _executable);
  });

  tearDown(() {
    expect(registry.closed, registry.opened);
  });

  test(
    'own Run registration works when the approval key does not exist',
    () async {
      registry.values[WindowsStartupKey.run] = {
        _product: const RegistryValue.string(_executable),
        'FlClash': const RegistryValue.string('other.exe'),
      };

      expect(await launcher.isEnabled(), isTrue);
      expect(registry.values.containsKey(WindowsStartupKey.approval), isFalse);
      expect(
        (registry.values[WindowsStartupKey.run]!['FlClash']! as StringValue)
            .value,
        'other.exe',
      );
    },
  );

  test(
    'fresh user can enable, disable and enable their product registration',
    () async {
      expect(await launcher.isEnabled(), isFalse);
      expect(registry.values, isEmpty);

      expect(await launcher.enable(), isTrue);
      expect(await launcher.isEnabled(), isTrue);
      expect(await launcher.disable(), isTrue);
      expect(await launcher.isEnabled(), isFalse);
      expect(await launcher.enable(), isTrue);
      expect(await launcher.isEnabled(), isTrue);
    },
  );

  test(
    'disable removes own Run entry without requiring an approval key',
    () async {
      registry.values[WindowsStartupKey.run] = {
        _product: const RegistryValue.string(_executable),
        'FlClash': const RegistryValue.string('other.exe'),
      };

      expect(await launcher.disable(), isTrue);
      expect(
        registry.values[WindowsStartupKey.run]!.containsKey(_product),
        isFalse,
      );
      expect(
        registry.values[WindowsStartupKey.run]!['FlClash'],
        const RegistryValue.string('other.exe'),
      );
      expect(registry.values.containsKey(WindowsStartupKey.approval), isFalse);
      expect(await launcher.disable(), isTrue);
    },
  );

  test('inactive product does not create startup keys when disabled', () async {
    expect(await launcher.disable(), isTrue);
    expect(registry.values, isEmpty);
  });

  test('system-disabled approval is reported without resetting it', () async {
    registry.values[WindowsStartupKey.run] = {
      _product: const RegistryValue.string(_executable),
    };
    final blocked = RegistryValue.binary(Uint8List.fromList([3, 1, 2, 3]));
    registry.values[WindowsStartupKey.approval] = {_product: blocked};

    expect(await launcher.isEnabled(), isFalse);
    expect(registry.values[WindowsStartupKey.approval]![_product], blocked);
    expect(await launcher.disable(), isTrue);
    expect(registry.values[WindowsStartupKey.run], isEmpty);
    expect(registry.values[WindowsStartupKey.approval], isEmpty);
  });

  test('enable and disable leave other products registered', () async {
    const otherRun = RegistryValue.string('other.exe');
    final otherApproval = RegistryValue.binary(Uint8List.fromList([3]));
    registry.values[WindowsStartupKey.run] = {'FlClash': otherRun};
    registry.values[WindowsStartupKey.approval] = {'FlClash': otherApproval};

    expect(await launcher.enable(), isTrue);
    expect(await launcher.isEnabled(), isTrue);
    expect(await launcher.disable(), isTrue);
    expect(registry.values[WindowsStartupKey.run], {'FlClash': otherRun});
    expect(registry.values[WindowsStartupKey.approval], {
      'FlClash': otherApproval,
    });
  });

  test(
    'different executable does not count as this product registration',
    () async {
      registry.values[WindowsStartupKey.run] = {
        _product: const RegistryValue.string('old.exe'),
      };
      registry.deniedKey = WindowsStartupKey.approval;

      expect(await launcher.isEnabled(), isFalse);
    },
  );

  test(
    'approval query permission failure is not treated as approval',
    () async {
      registry.values[WindowsStartupKey.run] = {
        _product: const RegistryValue.string(_executable),
      };
      registry.deniedKey = WindowsStartupKey.approval;

      await expectLater(launcher.isEnabled(), throwsA(_accessDenied));
    },
  );

  test(
    'startup inspection does not require registry write permission',
    () async {
      await launcher.enable();
      registry.denyWrites = true;

      expect(await launcher.isEnabled(), isTrue);
      await expectLater(launcher.disable(), throwsA(_accessDenied));
    },
  );

  test(
    'partial enable failure is reported and can be disabled and retried',
    () async {
      registry.failedWrite = WindowsStartupKey.approval;
      await expectLater(launcher.enable(), throwsA(_accessDenied));
      expect(
        registry.values[WindowsStartupKey.run]![_product],
        const RegistryValue.string('"$_executable"'),
      );

      expect(await launcher.disable(), isTrue);
      expect(await launcher.isEnabled(), isFalse);
      registry.failedWrite = null;
      expect(await launcher.enable(), isTrue);
      expect(await launcher.isEnabled(), isTrue);
    },
  );

  test(
    'partial disable failure remains observable until retry succeeds',
    () async {
      await launcher.enable();
      registry.failedRemove = WindowsStartupKey.approval;

      await expectLater(launcher.disable(), throwsA(_accessDenied));
      expect(
        registry.values[WindowsStartupKey.run]!.containsKey(_product),
        isFalse,
      );
      expect(
        registry.values[WindowsStartupKey.approval]!.containsKey(_product),
        isTrue,
      );
      registry.failedRemove = null;
      expect(await launcher.disable(), isTrue);
      expect(registry.values[WindowsStartupKey.approval], isEmpty);
    },
  );

  test(
    'Run command quotes the executable while retaining startup arguments',
    () async {
      launcher.setup(
        appName: _product,
        appPath: _executable,
        args: ['--minimized'],
      );

      expect(await launcher.enable(), isTrue);
      expect(
        registry.values[WindowsStartupKey.run]![_product],
        const RegistryValue.string('"$_executable" --minimized'),
      );
      expect(await launcher.isEnabled(), isTrue);
    },
  );
}

final _accessDenied = isA<WindowsException>().having(
  (error) => error.hr,
  'HRESULT',
  ERROR_ACCESS_DENIED.toHRESULT(),
);
