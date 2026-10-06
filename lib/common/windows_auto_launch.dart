import 'dart:typed_data';

import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:win32/win32.dart';
import 'package:win32_registry/win32_registry.dart';

enum WindowsStartupKey {
  run(r'Software\Microsoft\Windows\CurrentVersion\Run'),
  approval(
    r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
  );

  const WindowsStartupKey(this.path);

  final String path;
}

abstract interface class WindowsStartupKeyHandle {
  RegistryValue? read(String name);
  void write(String name, RegistryValue value);
  void remove(String name);
  void close();
}

typedef OpenWindowsStartupKey =
    WindowsStartupKeyHandle Function(
      WindowsStartupKey key, {
      required bool create,
      required bool writable,
    });

class WindowsAutoLaunch implements LaunchAtStartup {
  WindowsAutoLaunch({OpenWindowsStartupKey? openKey})
    : _openKey = openKey ?? _openRegistryKey;

  final OpenWindowsStartupKey _openKey;
  late String _name;
  late String _command;
  late String _legacyCommand;

  @override
  void setup({
    required String appName,
    required String appPath,
    String? packageName,
    List<String> args = const [],
  }) {
    if (packageName != null) {
      throw ArgumentError('Windows Run registration does not support MSIX');
    }
    _name = appName;
    final suffix = args.isEmpty ? '' : ' ${args.join(' ')}';
    _command = '"$appPath"$suffix';
    // Existing installs may still have the dependency's unquoted Run command.
    _legacyCommand = '$appPath$suffix';
  }

  RegistryValue? _read(WindowsStartupKey key) {
    final handle = _openExisting(key, writable: false);
    try {
      return handle?.read(_name);
    } finally {
      handle?.close();
    }
  }

  WindowsStartupKeyHandle? _openExisting(
    WindowsStartupKey key, {
    required bool writable,
  }) {
    try {
      return _openKey(key, create: false, writable: writable);
    } on WindowsException catch (error) {
      if (error.hr == ERROR_FILE_NOT_FOUND.toHRESULT()) return null;
      rethrow;
    }
  }

  @override
  Future<bool> isEnabled() async {
    final command = (_read(WindowsStartupKey.run) as StringValue?)?.value;
    if (command != _command && command != _legacyCommand) {
      return false;
    }
    final approval = (_read(WindowsStartupKey.approval) as BinaryValue?)?.value;
    return approval == null || approval.isEmpty || approval.first.isEven;
  }

  @override
  Future<bool> enable() async {
    _write(WindowsStartupKey.run, RegistryValue.string(_command));
    final approval = Uint8List(12)..[0] = 2;
    _write(WindowsStartupKey.approval, RegistryValue.binary(approval));
    return true;
  }

  @override
  Future<bool> disable() async {
    for (final key in WindowsStartupKey.values) {
      final handle = _openExisting(key, writable: true);
      try {
        if (handle?.read(_name) != null) handle!.remove(_name);
      } finally {
        handle?.close();
      }
    }
    return true;
  }

  void _write(WindowsStartupKey key, RegistryValue value) {
    final handle = _openKey(key, create: true, writable: true);
    try {
      handle.write(_name, value);
    } finally {
      handle.close();
    }
  }
}

WindowsStartupKeyHandle _openRegistryKey(
  WindowsStartupKey key, {
  required bool create,
  required bool writable,
}) {
  return _RegistryWindowsStartupKey(
    CURRENT_USER.open(
      key.path,
      config: RegistryOpenConfig(
        create: create,
        access: writable ? RegistryAccess.readWrite : RegistryAccess.read,
      ),
    ),
  );
}

class _RegistryWindowsStartupKey implements WindowsStartupKeyHandle {
  _RegistryWindowsStartupKey(this.key);

  final RegistryKey key;

  @override
  RegistryValue? read(String name) => key.getValue(name);

  @override
  void write(String name, RegistryValue value) => key.setValue(name, value);

  @override
  void remove(String name) => key.removeValue(name);

  @override
  void close() => key.close();
}
