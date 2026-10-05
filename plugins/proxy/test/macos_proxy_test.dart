import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy/src/macos_proxy.dart';
import 'package:proxy/src/proxy_command.dart';

class _NetworkSettings {
  final endpoints = <String, List<Object>>{};
  final bypass = <String, List<String>>{
    'Wi-Fi': ['original'],
  };
  final calls = <List<String>>[];
  var services = ['Wi-Fi'];
  String? failCommand;
  bool failAfterWrite = false;
  var authenticated = false;
  _NetworkSettings() {
    for (final type in ['webproxy', 'securewebproxy', 'socksfirewallproxy']) {
      endpoints['Wi-Fi/$type'] = ['foreign', 8080, false];
    }
  }
  Future<ProcessResult> run(
    String executable,
    List<String> args, {
    bool runInShell = false,
  }) async {
    calls.add(args);
    final command = args.first;
    if (command == '-listallnetworkservices') {
      return ProcessResult(1, 0, services.join('\n'), '');
    }
    final service = args[1];
    if (command == '-getproxybypassdomains') {
      return ProcessResult(1, 0, bypass[service]!.join('\n'), '');
    }
    if (command.startsWith('-get')) {
      final tuple = endpoints['$service/${command.substring(4)}'];
      if (tuple == null) return ProcessResult(1, 1, '', '');
      return ProcessResult(
        1,
        0,
        'Enabled: ${tuple[2] == true ? 'Yes' : 'No'}\nServer: ${tuple[0]}\nPort: ${tuple[1]}\nAuthenticated Proxy Enabled: ${authenticated ? 1 : 0}\n',
        '',
      );
    }
    if (command == failCommand && !failAfterWrite) {
      return ProcessResult(1, 1, '', '');
    }
    if (command == '-setproxybypassdomains') {
      bypass[service] = args[2] == 'Empty' ? [] : args.sublist(2);
    } else if (command.endsWith('state')) {
      endpoints['$service/${command.substring(4, command.length - 5)}']![2] =
          args[2] == 'on';
    } else {
      final tuple = endpoints['$service/${command.substring(4)}']!;
      tuple[0] = args[2];
      tuple[1] = int.parse(args[3]);
      tuple[2] = true;
    }
    return ProcessResult(1, command == failCommand ? 1 : 0, '', '');
  }

  MacosProxy create() => MacosProxy(commandRunner: ProxyCommandRunner(run));
}

void main() {
  late _NetworkSettings os;
  late MacosProxy proxy;
  setUp(() {
    os = _NetworkSettings();
    proxy = os.create();
  });
  test('inactive ordinary stop preserves foreign proxy and PAC', () async {
    expect(await proxy.stop(), isTrue);
    expect(os.calls, isEmpty);
  });
  test(
    'restores original settings on original services and never disables PAC',
    () async {
      expect(await proxy.start(7890, ['local']), isTrue);
      os.services = ['USB'];
      expect(await proxy.stop(), isTrue);
      expect(os.endpoints.values, everyElement(['foreign', 8080, false]));
      expect(os.bypass['Wi-Fi'], ['original']);
      expect(
        os.calls.where((args) => args.first.contains('autoproxy')),
        isEmpty,
      );
      expect(os.calls.where((args) => args.contains('USB')), isEmpty);
    },
  );
  test('later writer preserves its endpoint and bypass', () async {
    expect(await proxy.start(7890, ['local']), isTrue);
    os.endpoints['Wi-Fi/webproxy'] = ['later', 8081, true];
    os.bypass['Wi-Fi'] = ['later'];
    expect(await proxy.stop(), isTrue);
    expect(os.endpoints['Wi-Fi/webproxy'], ['later', 8081, true]);
    expect(os.bypass['Wi-Fi'], ['later']);
  });
  test('partially applied failed setter is restored', () async {
    os.failCommand = '-setsecurewebproxy';
    os.failAfterWrite = true;
    expect(await proxy.start(7890, ['local']), isFalse);
    os.failCommand = null;
    expect(await proxy.stop(), isTrue);
    expect(os.endpoints.values, everyElement(['foreign', 8080, false]));
    expect(os.bypass['Wi-Fi'], ['original']);
  });
  test(
    'partial restore retains current owned intermediate for retry',
    () async {
      expect(await proxy.start(7890, ['local']), isTrue);
      os.failCommand = '-setwebproxystate';
      expect(await proxy.stop(), isFalse);
      expect(await proxy.start(7891, []), isFalse);
      os.failCommand = null;
      expect(await proxy.stop(), isTrue);
      expect(os.endpoints.values, everyElement(['foreign', 8080, false]));
    },
  );
  test(
    'unreadable authenticated credentials reject setup before any write',
    () async {
      os.authenticated = true;
      expect(await proxy.start(7890, []), isFalse);
      expect(os.calls.where((args) => args.first.startsWith('-set')), isEmpty);
    },
  );
}
