import 'dart:io';
import 'dart:convert';

import 'proxy_command.dart';
import 'owned_proxy_settings.dart';

class MacosProxy {
  final ProxyCommandRunner _commandRunner;
  final _settings = OwnedProxySettings();

  MacosProxy({required ProxyCommandRunner commandRunner})
    : _commandRunner = commandRunner;

  Future<bool> start(int port, List<String> bypassDomain) async {
    if (!await _commandRunner.releaseProcesses()) return false;
    final services = await _networkServices();
    if (services.isEmpty) return false;
    final settings = <ProxySetting>[];
    for (final service in services) {
      for (final type in const [
        'webproxy',
        'securewebproxy',
        'socksfirewallproxy',
      ]) {
        final endpoint = _MacEndpoint(_commandRunner, service, type);
        settings.add(endpoint.setting(port));
      }
      settings.add(
        ProxySetting(
          installed: jsonEncode(bypassDomain),
          read: () async {
            final output = await _read(['-getproxybypassdomains', service]);
            if (output == null) return null;
            return jsonEncode(
              output.startsWith("There aren't any bypass domains set")
                  ? <String>[]
                  : output
                        .split('\n')
                        .where((line) => line.isNotEmpty)
                        .toList(),
            );
          },
          write: (value) => _commandRunner.run([
            MacosProxyCommands.buildProxyBypass(
              service,
              (jsonDecode(value) as List).cast<String>(),
            ),
          ]),
        ),
      );
    }
    return _settings.install(settings);
  }

  Future<bool> stop({bool onlyIfNeeded = false}) async =>
      await _commandRunner.releaseProcesses() && await _settings.restore();

  Future<String?> _read(List<String> args) async {
    try {
      final result = await _commandRunner.process(
        '/usr/sbin/networksetup',
        args,
      );
      return result.exitCode == 0 ? result.stdout.toString().trim() : null;
    } on ProcessException {
      return null;
    }
  }

  Future<List<String>> _networkServices() async {
    try {
      final result = await _commandRunner.process('/usr/sbin/networksetup', [
        '-listallnetworkservices',
      ]);
      if (result.exitCode != 0) {
        return [];
      }
      return MacosProxyCommands.parseNetworkServices(result.stdout.toString());
    } on ProcessException {
      return [];
    }
  }
}

class MacosProxyCommands {
  static List<ProxyCommand> buildStart(
    String service,
    int port,
    List<String> bypassDomain,
  ) {
    return [
      ProxyCommand('/usr/sbin/networksetup', [
        '-setwebproxy',
        service,
        proxyHost,
        '$port',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsecurewebproxy',
        service,
        proxyHost,
        '$port',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsocksfirewallproxy',
        service,
        proxyHost,
        '$port',
      ]),
      buildProxyBypass(service, bypassDomain),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setwebproxystate',
        service,
        'on',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsecurewebproxystate',
        service,
        'on',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsocksfirewallproxystate',
        service,
        'on',
      ]),
    ];
  }

  static ProxyCommand buildProxyBypass(
    String service,
    List<String> bypassDomain,
  ) {
    return ProxyCommand('/usr/sbin/networksetup', [
      '-setproxybypassdomains',
      service,
      if (bypassDomain.isEmpty) 'Empty' else ...bypassDomain,
    ]);
  }

  static List<String> parseNetworkServices(String stdout) {
    return stdout
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .where((line) => !line.startsWith('*'))
        .where((line) => !line.startsWith('An asterisk '))
        .toList();
  }
}

class _MacEndpoint {
  final ProxyCommandRunner runner;
  final String service;
  final String type;
  final ownedValues = <String>{};

  _MacEndpoint(this.runner, this.service, this.type);

  ProxySetting setting(int port) {
    final installed = jsonEncode([proxyHost, port, true]);
    ownedValues.add(installed);
    return ProxySetting(
      installed: installed,
      endpoint: true,
      read: read,
      write: write,
      matchesInstalled: ownedValues.contains,
    );
  }

  Future<String?> read() async {
    try {
      final result = await runner.process('/usr/sbin/networksetup', [
        '-get$type',
        service,
      ]);
      if (result.exitCode != 0) return null;
      final fields = <String, String>{};
      for (final line in result.stdout.toString().split('\n')) {
        final colon = line.indexOf(':');
        if (colon >= 0) {
          fields[line.substring(0, colon)] = line.substring(colon + 1).trim();
        }
      }
      final port = int.tryParse(fields['Port'] ?? '');
      final enabled = fields['Enabled'];
      if (port == null ||
          !const ['Yes', 'No'].contains(enabled) ||
          fields['Server'] == null ||
          fields['Authenticated Proxy Enabled'] != '0') {
        return null;
      }
      return jsonEncode([fields['Server'], port, enabled == 'Yes']);
    } on ProcessException {
      return null;
    }
  }

  Future<bool> write(String value) async {
    final target = jsonDecode(value) as List;
    final prior = await read();
    if (prior == null) return false;
    final previous = jsonDecode(prior) as List;
    final endpointWritten = await runner.run([
      ProxyCommand('/usr/sbin/networksetup', [
        '-set$type',
        service,
        target[0] as String,
        '${target[1]}',
      ]),
    ]);
    final intermediate = await read();
    // networksetup enables the endpoint before the separate state command.
    final candidates = {
      jsonEncode([target[0], target[1], previous[2]]),
      jsonEncode([target[0], target[1], true]),
    };
    if (intermediate != null && candidates.contains(intermediate)) {
      ownedValues.clear();
      ownedValues.add(intermediate);
    }
    if (!endpointWritten ||
        intermediate == null ||
        !candidates.contains(intermediate)) {
      return false;
    }
    final enabledWritten = await runner.run([
      ProxyCommand('/usr/sbin/networksetup', [
        '-set${type}state',
        service,
        target[2] == true ? 'on' : 'off',
      ]),
    ]);
    final current = await read();
    if (current == value) {
      ownedValues.clear();
      ownedValues.add(value);
    }
    return enabledWritten && current == value;
  }
}
