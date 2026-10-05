class ProxySetting {
  final Future<String?> Function() read;
  final Future<bool> Function(String value) write;
  final String installed;
  final bool endpoint;
  final bool activation;
  final bool Function(String value)? matchesInstalled;

  const ProxySetting({
    required this.read,
    required this.write,
    required this.installed,
    this.endpoint = false,
    this.activation = false,
    this.matchesInstalled,
  });

  bool owns(String value) =>
      matchesInstalled?.call(value) ?? value == installed;
}

class _OwnedSetting {
  final ProxySetting setting;
  final String before;
  bool released = false;

  _OwnedSetting(this.setting, this.before);
}

class OwnedProxySettings {
  final _owned = <_OwnedSetting>[];

  Future<bool> install(List<ProxySetting> settings) async {
    if (!await restore()) return false;
    final snapshots = <String>[];
    for (final setting in settings) {
      final before = await setting.read();
      if (before == null) return false;
      snapshots.add(before);
    }
    if (settings.indexed.every(
      (entry) => snapshots[entry.$1] == entry.$2.installed,
    )) {
      return true;
    }
    for (var index = 0; index < settings.length; index++) {
      final setting = settings[index];
      final before = snapshots[index];
      _owned.add(_OwnedSetting(setting, before));
      if (before == setting.installed) continue;
      if (!await setting.write(setting.installed) ||
          await setting.read() != setting.installed) {
        return false;
      }
    }
    return true;
  }

  Future<bool> restore() async {
    if (_owned.isEmpty) return true;
    final current = <_OwnedSetting, String>{};
    for (final owned in _owned) {
      final value = await owned.setting.read();
      if (value == null) return false;
      current[owned] = value;
    }
    // A foreign endpoint can depend on the unchanged manual-mode value.
    final foreignEndpoint = _owned.any(
      (owned) =>
          owned.setting.endpoint &&
          !owned.setting.owns(current[owned]!) &&
          current[owned] != owned.before,
    );
    var success = true;
    for (final owned in _owned.reversed.toList()) {
      final setting = owned.setting;
      if (owned.released || owned.before == setting.installed) continue;
      if (current[owned] == owned.before ||
          !setting.owns(current[owned]!) ||
          (setting.activation && foreignEndpoint)) {
        owned.released = true;
        continue;
      }
      if (await setting.write(owned.before) &&
          await setting.read() == owned.before) {
        owned.released = true;
      } else {
        success = false;
      }
    }
    if (success) _owned.clear();
    return success;
  }
}
