import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy/src/linux_proxy.dart';
import 'package:proxy/src/proxy_command.dart';

class _DesktopSettings {
  final values = <String, String>{};
  final calls = <List<String>>[];
  String? failWrite;
  String? failRead;
  bool failAfterWrite = false;
  bool canonicalQuotes = false;

  String key(List<String> args) => args.first == 'get' || args.first == 'set'
      ? '${args[1]}/${args[2]}'
      : '${args[1]}/${args[5]}';

  Future<ProcessResult> run(
    String executable,
    List<String> args, {
    bool runInShell = false,
  }) async {
    calls.add([executable, ...args]);
    final name = key(args);
    final reading = args.first == 'get' || executable.startsWith('kread');
    if (reading) {
      var output = values[name] ?? (args.first == 'get' ? "''" : args.last);
      if (canonicalQuotes &&
          args.first == 'get' &&
          args[2] == 'ignore-hosts' &&
          output.contains(r"it\'s")) {
        output = r'''["it's", 'local\\host']''';
      }
      return ProcessResult(1, name == failRead ? 1 : 0, output, '');
    }
    if (name == failWrite && !failAfterWrite) {
      return ProcessResult(1, 1, '', '');
    }
    if (args.last == '--delete') {
      values.remove(name);
    } else {
      var value = args.last;
      if (args.first == 'set' &&
          args[2] != 'port' &&
          args[2] != 'ignore-hosts' &&
          !value.startsWith("'")) {
        value = "'$value'";
      }
      values[name] = value;
    }
    return ProcessResult(1, name == failWrite ? 1 : 0, '', '');
  }

  LinuxProxy create() => LinuxProxy(
    commandRunner: ProxyCommandRunner(run),
    executableChecker: (_) async => true,
  );
}

void main() {
  for (final desktop in ['GNOME', 'MATE', 'KDE']) {
    group('$desktop owned settings', () {
      late _DesktopSettings os;
      late LinuxProxy proxy;
      late String prefix;
      late String mode;
      late String host;
      late String bypass;
      Future<bool> start() =>
          proxy.start(7890, ['local'], desktop: desktop, homeDir: '/home/test');
      Future<bool> stop() => proxy.stop(
        onlyIfNeeded: true,
        desktop: 'OTHER',
        homeDir: '/other/home',
      );
      setUp(() {
        os = _DesktopSettings();
        proxy = os.create();
        prefix = desktop == 'KDE'
            ? '/home/test/.config/kioslaverc'
            : 'org.${desktop == 'MATE' ? 'mate' : 'gnome'}.system.proxy';
        mode = '$prefix/${desktop == 'KDE' ? 'ProxyType' : 'mode'}';
        host = desktop == 'KDE' ? '$prefix/httpProxy' : '$prefix.http/host';
        bypass = '$prefix/${desktop == 'KDE' ? 'NoProxyFor' : 'ignore-hosts'}';
        if (desktop != 'KDE') {
          for (final type in ['http', 'https', 'socks']) {
            os.values['$prefix.$type/host'] = "'foreign'";
            os.values['$prefix.$type/port'] = '8080';
          }
        }
        os.values.addAll({
          mode: desktop == 'KDE' ? '2' : "'auto'",
          host: desktop == 'KDE' ? 'http://foreign:8080' : "'foreign'",
          bypass: desktop == 'KDE' ? 'original' : "['original']",
        });
      });
      test('inactive stop leaves foreign settings untouched', () async {
        final before = Map.of(os.values);
        expect(
          await proxy.stop(desktop: desktop, homeDir: '/home/test'),
          isTrue,
        );
        expect(os.calls, isEmpty);
        expect(os.values, before);
      });
      test('restores original values and only the installed backend', () async {
        final before = Map.of(os.values);
        expect(await start(), isTrue);
        expect(os.values[mode], desktop == 'KDE' ? '1' : "'manual'");
        expect(
          os.values[host],
          desktop == 'KDE' ? 'http://127.0.0.1:7890' : "'127.0.0.1'",
        );
        expect(os.values[bypass], desktop == 'KDE' ? 'local' : "['local']");
        expect(await stop(), isTrue);
        expect(os.values, before);
        os.calls.clear();
        expect(await stop(), isTrue);
        expect(os.calls, isEmpty);
      });
      test('later endpoint writer keeps its manual activation', () async {
        expect(await start(), isTrue);
        os.values[host] = desktop == 'KDE' ? 'http://later:8081' : "'later'";
        final laterMode = os.values[mode];
        expect(await stop(), isTrue);
        expect(
          os.values[host],
          desktop == 'KDE' ? 'http://later:8081' : "'later'",
        );
        expect(os.values[mode], laterMode);
      });
      test(
        'canonical native bypass quoting remains owned and restorable',
        () async {
          final before = Map.of(os.values);
          os.canonicalQuotes = true;
          expect(
            await proxy.start(
              7890,
              ["it's", r'local\host'],
              desktop: desktop,
              homeDir: '/home/test',
            ),
            isTrue,
          );
          expect(await stop(), isTrue);
          expect(os.values, before);
        },
      );
      test('later bypass writer survives cleanup', () async {
        expect(await start(), isTrue);
        os.values[bypass] = desktop == 'KDE' ? 'later' : "['later']";
        expect(await stop(), isTrue);
        expect(os.values[bypass], desktop == 'KDE' ? 'later' : "['later']");
      });
      test('failed setter that wrote is restored on exit', () async {
        final before = Map.of(os.values);
        os.failWrite = host;
        os.failAfterWrite = true;
        expect(await start(), isFalse);
        os.failWrite = null;
        expect(await stop(), isTrue);
        expect(os.values, before);
      });
      test('read failure retains ownership for cleanup retry', () async {
        final before = Map.of(os.values);
        expect(await start(), isTrue);
        os.failRead = host;
        expect(await stop(), isFalse);
        expect(await start(), isFalse);
        os.failRead = null;
        expect(await stop(), isTrue);
        expect(os.values, before);
      });
      test('failed restore is retried before installing a successor', () async {
        final before = Map.of(os.values);
        expect(await start(), isTrue);
        os.failWrite = mode;
        expect(await stop(), isFalse);
        expect(await start(), isFalse);
        os.failWrite = null;
        expect(await stop(), isTrue);
        expect(os.values, before);
      });
    });
  }
}
