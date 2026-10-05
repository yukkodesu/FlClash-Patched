import 'dart:convert';
import 'dart:io';

import 'package:proxy/src/linux_proxy.dart';
import 'package:proxy/src/macos_proxy.dart';
import 'package:proxy/src/proxy_command.dart';

Future<void> main() async {
  final environment = Platform.environment;
  if (environment['GITHUB_ACTIONS'] != 'true' ||
      environment['RUNNER_ENVIRONMENT'] != 'github-hosted' ||
      environment['FLCLASH_MEOW_PROXY_NATIVE_ACCEPTANCE'] != '1') {
    stdout.writeln(
      'SKIP: native proxy acceptance requires an opted-in disposable GitHub runner',
    );
    return;
  }
  if (!Platform.isLinux && !Platform.isMacOS) {
    throw StateError('Windows uses the native proxy_test executable');
  }
  final runner = ProxyCommandRunner(null);
  Future<String> read(String executable, List<String> args) async {
    final result = await runner.process(executable, args);
    if (result.exitCode != 0) {
      throw StateError('$executable $args failed: ${result.stderr}');
    }
    return result.stdout.toString().trim();
  }

  Future<void> write(List<ProxyCommand> commands) async {
    if (!await runner.run(commands)) {
      throw StateError('Native proxy fixture write failed');
    }
  }

  final evidence = <String, Object>{'platform': Platform.operatingSystem};
  late Future<Map<String, String>> Function() snapshot;
  late Future<void> Function(Map<String, String>) restore;
  late Future<void> Function(int, List<String>) foreign;
  late Future<bool> Function(int) start;
  late Future<bool> Function() stop;
  if (Platform.isLinux) {
    final home = environment['HOME'];
    if (home == null) throw StateError('HOME is unavailable');
    const schema = 'org.gnome.system.proxy';
    final keys = <String, List<String>>{
      'mode': [schema, 'mode'],
      'bypass': [schema, 'ignore-hosts'],
      for (final type in ['http', 'https', 'socks']) ...{
        '$type.host': ['$schema.$type', 'host'],
        '$type.port': ['$schema.$type', 'port'],
      },
    };
    snapshot = () async => {
      for (final entry in keys.entries)
        entry.key: await read('gsettings', ['get', ...entry.value]),
    };
    restore = (values) => write([
      for (final entry in keys.entries.where((entry) => entry.key != 'mode'))
        ProxyCommand('gsettings', ['set', ...entry.value, values[entry.key]!]),
      ProxyCommand('gsettings', ['set', schema, 'mode', values['mode']!]),
    ]);
    foreign = (port, bypass) => write(
      LinuxProxyCommands.buildStartForBackend(
        port: port,
        bypassDomain: bypass,
        homeDir: home,
        backend: LinuxProxyBackend.gnome,
        kdeConfigWriter: '',
      ),
    );
    final proxy = LinuxProxy(commandRunner: runner);
    start = (port) =>
        proxy.start(port, ['meow-owned'], desktop: 'GNOME', homeDir: home);
    stop = () =>
        proxy.stop(onlyIfNeeded: true, desktop: 'CHANGED', homeDir: '/changed');
  } else {
    final services = MacosProxyCommands.parseNetworkServices(
      await read('/usr/sbin/networksetup', ['-listallnetworkservices']),
    );
    if (services.isEmpty) throw StateError('No enabled network service');
    const getters = [
      'webproxy',
      'securewebproxy',
      'socksfirewallproxy',
      'proxybypassdomains',
      'autoproxyurl',
    ];
    snapshot = () async => {
      for (final service in services)
        for (final type in getters)
          '$service/$type': await read('/usr/sbin/networksetup', [
            '-get$type',
            service,
          ]),
    };
    restore = (values) async {
      final commands = <ProxyCommand>[];
      for (final service in services) {
        for (final type in getters.take(3)) {
          final fields = <String, String>{};
          for (final line in values['$service/$type']!.split('\n')) {
            final colon = line.indexOf(':');
            if (colon >= 0) {
              fields[line.substring(0, colon)] = line
                  .substring(colon + 1)
                  .trim();
            }
          }
          if (fields['Authenticated Proxy Enabled'] != '0') {
            throw StateError('Cannot restore authenticated proxy credentials');
          }
          commands.addAll([
            ProxyCommand('/usr/sbin/networksetup', [
              '-set$type',
              service,
              fields['Server']!,
              fields['Port']!,
            ]),
            ProxyCommand('/usr/sbin/networksetup', [
              '-set${type}state',
              service,
              fields['Enabled'] == 'Yes' ? 'on' : 'off',
            ]),
          ]);
        }
        final bypass = values['$service/proxybypassdomains']!;
        commands.add(
          MacosProxyCommands.buildProxyBypass(
            service,
            bypass.startsWith("There aren't any bypass domains set")
                ? []
                : bypass.split('\n'),
          ),
        );
      }
      await write(commands);
    };
    foreign = (port, bypass) => write([
      for (final service in services)
        ...MacosProxyCommands.buildStart(service, port, bypass),
    ]);
    final proxy = MacosProxy(commandRunner: runner);
    start = (port) => proxy.start(port, ['meow-owned']);
    stop = () => proxy.stop(onlyIfNeeded: true);
  }
  void equal(Object actual, Object expected, String label) {
    if (jsonEncode(actual) != jsonEncode(expected)) {
      throw StateError(
        '$label mismatch: ${jsonEncode(actual)} != ${jsonEncode(expected)}',
      );
    }
  }

  final baseline = await snapshot();
  evidence['baseline'] = baseline;
  if (Platform.isMacOS &&
      baseline.values.any(
        (value) => value.contains('Authenticated Proxy Enabled: 1'),
      )) {
    throw StateError(
      'Fixture refuses to overwrite unreadable authenticated credentials',
    );
  }
  try {
    await foreign(8088, ['foreign-original']);
    final before = await snapshot();
    evidence['before'] = before;
    if (!await stop()) throw StateError('Inactive stop failed');
    equal(await snapshot(), before, 'Inactive owner changed foreign settings');
    if (!await start(7890)) throw StateError('Native proxy start failed');
    evidence['installed'] = await snapshot();
    if (!await stop()) throw StateError('Native proxy restore failed');
    final after = await snapshot();
    evidence['after'] = after;
    equal(after, before, 'Original settings restoration');
    if (!await start(7890)) {
      throw StateError('Second native proxy start failed');
    }
    await foreign(8089, ['foreign-later']);
    final later = await snapshot();
    evidence['laterWriter'] = later;
    if (!await stop()) throw StateError('Later-writer cleanup failed');
    final finalState = await snapshot();
    evidence['afterLaterWriter'] = finalState;
    equal(finalState, later, 'Later writer preservation');
    evidence['outcome'] = 'passed';
  } catch (error) {
    evidence['outcome'] = 'failed';
    evidence['error'] = '$error';
    rethrow;
  } finally {
    try {
      await stop();
      await restore(baseline);
      final finalBaseline = await snapshot();
      evidence['finalBaseline'] = finalBaseline;
      equal(finalBaseline, baseline, 'Fixture baseline restoration');
    } catch (error) {
      evidence['outcome'] = 'failed';
      evidence['cleanupError'] = '$error';
      rethrow;
    } finally {
      final json = jsonEncode(evidence);
      stdout.writeln(json);
      final path = environment['FLCLASH_MEOW_PROXY_EVIDENCE_PATH'];
      if (path != null) await File(path).writeAsString('$json\n');
    }
  }
}
