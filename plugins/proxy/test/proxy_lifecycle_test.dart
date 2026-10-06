import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy/proxy.dart';
import 'package:proxy/src/proxy_command.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'terminal close drains an active start and fences queued and future starts',
    () async {
      final entered = Completer<void>();
      final resume = Completer<void>();
      final calls = <String>[];
      final values = <String, String>{};
      final endpoints = {
        for (final type in ['webproxy', 'securewebproxy', 'socksfirewallproxy'])
          type: <Object>['foreign', 8080, false],
      };
      var bypass = <String>['original'];
      Future<void> gate(String command) async {
        calls.add(command);
        if (!entered.isCompleted) {
          entered.complete();
          await resume.future;
        }
      }

      const channel = MethodChannel('proxy');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            await gate(call.method);
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final proxy = Proxy(
        executableChecker: (_) async => true,
        processRunner: (executable, args, {runInShell = false}) async {
          await gate(args.first);
          if (args.first == '-listallnetworkservices') {
            return ProcessResult(1, 0, 'Wi-Fi', '');
          }
          if (args.first == '-getproxybypassdomains') {
            return ProcessResult(1, 0, bypass.join('\n'), '');
          }
          if (args.first.startsWith('-get')) {
            final tuple = endpoints[args.first.substring(4)]!;
            return ProcessResult(
              1,
              0,
              'Enabled: ${tuple[2] == true ? 'Yes' : 'No'}\nServer: ${tuple[0]}\nPort: ${tuple[1]}\nAuthenticated Proxy Enabled: 0',
              '',
            );
          }
          if (args.first == '-setproxybypassdomains') {
            bypass = args[2] == 'Empty' ? [] : args.sublist(2);
          } else if (args.first.startsWith('-set')) {
            final state = args.first.endsWith('state');
            final tuple =
                endpoints[args.first.substring(
                  4,
                  state ? args.first.length - 5 : null,
                )]!;
            if (state) {
              tuple[2] = args[2] == 'on';
            } else {
              tuple[0] = args[2];
              tuple[1] = int.parse(args[3]);
              tuple[2] = true;
            }
          } else if (args.first == 'get' || args.first == 'set') {
            final key = '${args[1]}/${args[2]}';
            if (args.first == 'get') {
              final original = switch (args[2]) {
                'port' => '8080',
                'ignore-hosts' => "['original']",
                'mode' => "'auto'",
                _ => "'foreign'",
              };
              return ProcessResult(1, 0, values[key] ?? original, '');
            }
            values[key] = args.last;
          } else {
            final key = args[5];
            if (executable.startsWith('kread')) {
              return ProcessResult(1, 0, values[key] ?? args.last, '');
            }
            if (args.last == '--delete') {
              values.remove(key);
            } else {
              values[key] = args.last;
            }
          }
          return ProcessResult(1, 0, '', '');
        },
      );
      final first = proxy.startProxy(7890, ['local']);
      await entered.future;
      final queued = proxy.startProxy(7891);
      final close = proxy.close();
      resume.complete();
      expect(await first, isTrue);
      expect(await queued, isFalse);
      expect(await close, isTrue);
      final count = calls.length;
      expect(await proxy.startProxy(7892), isFalse);
      expect(calls.length, count);
      if (Platform.isWindows) expect(calls, ['StartProxy', 'StopProxy']);
      if (Platform.isMacOS) {
        expect(endpoints.values, everyElement(['foreign', 8080, false]));
        expect(bypass, ['original']);
      }
      if (Platform.isLinux) expect(values.values, isNot(contains('7890')));
    },
  );

  test('owned command timeout kills and reaps a harmless child', () async {
    final runner = ProxyCommandRunner(
      null,
      commandTimeout: const Duration(milliseconds: 500),
    );
    final result = await runner.process(
      Platform.isWindows
          ? 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
          : '/bin/sleep',
      Platform.isWindows
          ? [
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              'Start-Sleep -Seconds 10',
            ]
          : ['10'],
    );
    expect(result.exitCode, -1);
    expect(await runner.releaseProcesses(), isTrue);
  });
  test(
    'owned command output remains capped and overflow fails visibly',
    () async {
      final runner = ProxyCommandRunner(null);
      final result = await runner.process(
        Platform.isWindows
            ? 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
            : '/usr/bin/head',
        Platform.isWindows
            ? [
                '-NoProfile',
                '-NonInteractive',
                '-Command',
                "[Console]::Out.Write(('x' * 2097152))",
              ]
            : ['-c', '2097152', '/dev/zero'],
      );
      expect(result.exitCode, -1);
      expect(result.stdout.toString().length, lessThanOrEqualTo(1024 * 1024));
      expect(await runner.releaseProcesses(), isTrue);
    },
  );
}
