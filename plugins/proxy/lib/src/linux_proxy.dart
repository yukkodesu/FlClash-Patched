import 'dart:io';

import 'package:path/path.dart' as path;

import 'proxy_command.dart';
import 'owned_proxy_settings.dart';

enum LinuxProxyBackend { gnome, mate, kde }

enum _ProxyType { http, https, socks }

const _fallbackBackends = [LinuxProxyBackend.gnome, LinuxProxyBackend.kde];

class LinuxProxy {
  final ProxyCommandRunner _commandRunner;
  final ProxyExecutableChecker _executableChecker;
  final _settings = OwnedProxySettings();

  LinuxProxy({
    required ProxyCommandRunner commandRunner,
    ProxyExecutableChecker? executableChecker,
  }) : _commandRunner = commandRunner,
       _executableChecker =
           executableChecker ??
           ((executable) => _hasExecutable(commandRunner, executable));

  Future<bool> start(
    int port,
    List<String> bypassDomain, {
    required String? desktop,
    required String? homeDir,
  }) async {
    if (!await _commandRunner.releaseProcesses()) return false;
    if (homeDir == null || homeDir.isEmpty) {
      return false;
    }
    final selection = await _resolveBackend(desktop);
    if (selection == null) {
      return false;
    }
    final commands = LinuxProxyCommands.buildStartForBackend(
      port: port,
      bypassDomain: bypassDomain,
      homeDir: homeDir,
      backend: selection.backend,
      kdeConfigWriter: selection.executable,
    );
    final missing =
        '__flclash_meow_absent_${pid}_${DateTime.now().microsecondsSinceEpoch}__';
    return _settings.install(
      commands.map((command) {
        final gsettings = selection.backend != LinuxProxyBackend.kde;
        final key = gsettings ? command.args[2] : command.args[5];
        final expected = gsettings
            ? _variant(command.args.last, key)!
            : command.args.last;
        return ProxySetting(
          installed: expected,
          endpoint:
              key == 'host' ||
              key == 'port' ||
              key.endsWith('Proxy') && key != 'NoProxyFor',
          activation: key == 'mode' || key == 'ProxyType',
          read: () async {
            final read = gsettings
                ? ProxyCommand('gsettings', ['get', command.args[1], key])
                : ProxyCommand(
                    selection.executable.replaceFirst('kwrite', 'kread'),
                    [...command.args.take(6), '--default', missing],
                  );
            try {
              final result = await _commandRunner.process(
                read.executable,
                read.args,
              );
              if (result.exitCode != 0) return null;
              final output = result.stdout.toString();
              final value = gsettings
                  ? output.trim()
                  : output.replaceFirst(RegExp(r'\r?\n$'), '');
              if (gsettings && value.isEmpty) return null;
              return gsettings ? _variant(value, key) : value;
            } on ProcessException {
              return null;
            }
          },
          write: (value) => _commandRunner.run([
            ProxyCommand(
              command.executable,
              gsettings
                  ? ['set', command.args[1], key, value]
                  : [
                      ...command.args.take(6),
                      if (value == missing) '--delete' else value,
                    ],
            ),
          ]),
        );
      }).toList(),
    );
  }

  Future<bool> stop({
    bool onlyIfNeeded = false,
    required String? desktop,
    required String? homeDir,
  }) async =>
      await _commandRunner.releaseProcesses() && await _settings.restore();

  static String? _variant(String value, String key) {
    if (key == 'port') {
      final number = int.tryParse(
        value.replaceFirst(RegExp(r'^(?:u?int(?:16|32|64))\s+'), ''),
      );
      return number?.toString();
    }
    if (key == 'ignore-hosts') {
      value = value.replaceFirst(RegExp(r'^@as\s+'), '');
      if (!value.startsWith('[') || !value.endsWith(']')) return null;
      final strings = <String>[];
      var index = 1;
      while (index < value.length - 1) {
        if (value[index].trim().isEmpty || value[index] == ',') {
          index++;
          continue;
        }
        final decoded = _quoted(value, index);
        if (decoded == null) return null;
        strings.add(decoded.$1);
        index = decoded.$2;
      }
      return LinuxProxyCommands._formatGSettingsStringList(strings);
    }
    if (value.startsWith("'") || value.startsWith('"')) {
      final decoded = _quoted(value, 0);
      return decoded == null || decoded.$2 != value.length
          ? null
          : _quote(decoded.$1);
    }
    return _quote(value);
  }

  static String _quote(String value) =>
      "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('\n', r'\n').replaceAll('\r', r'\r').replaceAll('\t', r'\t')}'";

  static (String, int)? _quoted(String value, int offset) {
    final quote = value[offset];
    if (quote != "'" && quote != '"') return null;
    final decoded = StringBuffer();
    for (var index = offset + 1; index < value.length; index++) {
      final char = value[index];
      if (char == quote) return (decoded.toString(), index + 1);
      if (char != r'\') {
        decoded.write(char);
        continue;
      }
      if (++index >= value.length) return null;
      final escaped = value[index];
      if (escaped == 'u' || escaped == 'U') {
        final count = escaped == 'u' ? 4 : 8;
        if (index + count >= value.length) return null;
        final code = int.tryParse(
          value.substring(index + 1, index + count + 1),
          radix: 16,
        );
        if (code == null || code > 0x10ffff) return null;
        decoded.writeCharCode(code);
        index += count;
      } else {
        decoded.write(switch (escaped) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          _ => escaped,
        });
      }
    }
    return null;
  }

  Future<_LinuxBackendSelection?> _resolveBackend(String? desktop) async {
    final preferredBackend = LinuxProxyCommands.preferredBackend(desktop);
    if (preferredBackend != null) {
      return _resolveSelection(preferredBackend);
    }
    for (final backend in _fallbackBackends) {
      final selection = await _resolveSelection(backend);
      if (selection != null) {
        return selection;
      }
    }
    return null;
  }

  Future<_LinuxBackendSelection?> _resolveSelection(
    LinuxProxyBackend backend,
  ) async {
    switch (backend) {
      case LinuxProxyBackend.gnome:
      case LinuxProxyBackend.mate:
        if (await _executableChecker('gsettings')) {
          return _LinuxBackendSelection(backend, 'gsettings');
        }
        return null;
      case LinuxProxyBackend.kde:
        for (final executable in const ['kwriteconfig6', 'kwriteconfig5']) {
          if (await _executableChecker(executable) &&
              await _executableChecker(
                executable.replaceFirst('kwrite', 'kread'),
              )) {
            return _LinuxBackendSelection(backend, executable);
          }
        }
    }
    return null;
  }

  static Future<bool> _hasExecutable(
    ProxyCommandRunner runner,
    String executable,
  ) async {
    try {
      final result = await runner.process('which', [executable]);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }
}

class LinuxProxyCommands {
  static LinuxProxyBackend? preferredBackend(String? desktop) {
    final desktops = _desktops(desktop);
    if (desktops.contains('KDE')) {
      return LinuxProxyBackend.kde;
    }
    if (desktops.contains('MATE')) {
      return LinuxProxyBackend.mate;
    }
    if (desktops.any(
      (desktop) =>
          const {'GNOME', 'CINNAMON', 'BUDGIE', 'UNITY'}.contains(desktop),
    )) {
      return LinuxProxyBackend.gnome;
    }
    return null;
  }

  static List<ProxyCommand> buildStart({
    required int port,
    required List<String> bypassDomain,
    required String? desktop,
    required String homeDir,
    Set<String>? availableExecutables,
  }) {
    final backend = _resolveBackend(
      desktop: desktop,
      availableExecutables: availableExecutables,
    );
    if (backend == null) {
      return [];
    }
    return buildStartForBackend(
      port: port,
      bypassDomain: bypassDomain,
      homeDir: homeDir,
      backend: backend,
      kdeConfigWriter: _resolveKdeConfigWriter(availableExecutables),
    );
  }

  static List<ProxyCommand> buildStartForBackend({
    required int port,
    required List<String> bypassDomain,
    required String homeDir,
    required LinuxProxyBackend backend,
    required String kdeConfigWriter,
  }) {
    return switch (backend) {
      LinuxProxyBackend.gnome => _buildGSettingsStart(
        port: port,
        bypassDomain: bypassDomain,
        schemaPrefix: 'org.gnome.system.proxy',
      ),
      LinuxProxyBackend.mate => _buildGSettingsStart(
        port: port,
        bypassDomain: bypassDomain,
        schemaPrefix: 'org.mate.system.proxy',
      ),
      LinuxProxyBackend.kde => _buildKdeStart(
        port: port,
        bypassDomain: bypassDomain,
        homeDir: homeDir,
        executable: kdeConfigWriter,
      ),
    };
  }

  static LinuxProxyBackend? _resolveBackend({
    required String? desktop,
    required Set<String>? availableExecutables,
  }) {
    final preferred = preferredBackend(desktop);
    if (preferred != null) {
      if (availableExecutables == null ||
          _isBackendAvailable(preferred, availableExecutables)) {
        return preferred;
      }
      return null;
    }
    if (availableExecutables == null) {
      return LinuxProxyBackend.gnome;
    }
    for (final backend in _fallbackBackends) {
      if (_isBackendAvailable(backend, availableExecutables)) {
        return backend;
      }
    }
    return null;
  }

  static bool _isBackendAvailable(
    LinuxProxyBackend backend,
    Set<String> availableExecutables,
  ) {
    return switch (backend) {
      LinuxProxyBackend.gnome ||
      LinuxProxyBackend.mate => availableExecutables.contains('gsettings'),
      LinuxProxyBackend.kde =>
        availableExecutables.contains('kwriteconfig6') ||
            availableExecutables.contains('kwriteconfig5'),
    };
  }

  static String _resolveKdeConfigWriter(Set<String>? availableExecutables) {
    if (availableExecutables?.contains('kwriteconfig6') ?? false) {
      return 'kwriteconfig6';
    }
    return 'kwriteconfig5';
  }

  static List<ProxyCommand> _buildGSettingsStart({
    required int port,
    required List<String> bypassDomain,
    required String schemaPrefix,
  }) {
    final commands = <ProxyCommand>[
      ProxyCommand('gsettings', [
        'set',
        schemaPrefix,
        'ignore-hosts',
        _formatGSettingsStringList(bypassDomain),
      ]),
    ];
    for (final type in _ProxyType.values) {
      commands.addAll([
        ProxyCommand('gsettings', [
          'set',
          '$schemaPrefix.${type.name}',
          'host',
          proxyHost,
        ]),
        ProxyCommand('gsettings', [
          'set',
          '$schemaPrefix.${type.name}',
          'port',
          '$port',
        ]),
      ]);
    }
    commands.add(
      ProxyCommand('gsettings', ['set', schemaPrefix, 'mode', 'manual']),
    );
    return commands;
  }

  static List<ProxyCommand> _buildKdeStart({
    required int port,
    required List<String> bypassDomain,
    required String homeDir,
    required String executable,
  }) {
    final configFile = path.posix.join(homeDir, '.config', 'kioslaverc');
    return [
      ProxyCommand(executable, [
        '--file',
        configFile,
        '--group',
        'Proxy Settings',
        '--key',
        'NoProxyFor',
        bypassDomain.join(','),
      ]),
      for (final type in _ProxyType.values)
        ProxyCommand(executable, [
          '--file',
          configFile,
          '--group',
          'Proxy Settings',
          '--key',
          '${type.name}Proxy',
          _kdeProxyUrl(type, port),
        ]),
      ProxyCommand(executable, [
        '--file',
        configFile,
        '--group',
        'Proxy Settings',
        '--key',
        'ReversedException',
        'false',
      ]),
      ProxyCommand(executable, [
        '--file',
        configFile,
        '--group',
        'Proxy Settings',
        '--key',
        'ProxyType',
        '1',
      ]),
    ];
  }

  static String _kdeProxyUrl(_ProxyType type, int port) {
    // kioslaverc scheme is the transport to the proxy. Mixed ports speak HTTP.
    final scheme = switch (type) {
      _ProxyType.socks => 'socks',
      _ProxyType.http || _ProxyType.https => 'http',
    };
    return '$scheme://$proxyHost:$port';
  }

  static String _formatGSettingsStringList(List<String> values) {
    return "[${values.map(LinuxProxy._quote).join(', ')}]";
  }

  static Set<String> _desktops(String? desktop) {
    if (desktop == null || desktop.isEmpty) {
      return {};
    }
    return desktop
        .split(':')
        .map((value) => value.trim().toUpperCase())
        .where((value) => value.isNotEmpty)
        .toSet();
  }
}

class _LinuxBackendSelection {
  final LinuxProxyBackend backend;
  final String executable;

  const _LinuxBackendSelection(this.backend, this.executable);
}
