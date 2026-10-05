import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'discovers the selected Apple SDK for Cargo and invalidates stale output',
    () {
      final root = Directory.systemTemp.createTempSync('meow_apple_build_');
      addTearDown(() => root.deleteSync(recursive: true));
      void write(String name, String value) {
        File(p.join(root.path, name))
          ..createSync(recursive: true)
          ..writeAsStringSync(value);
      }

      write('core/meow-rs/Cargo.toml', '[package]\nname = "fixture"\n');
      final core = p.join(root.path, 'core/meow-rs');
      for (final args in [
        ['init'],
        ['add', '.'],
        [
          '-c',
          'user.name=Fixture',
          '-c',
          'user.email=fixture@example.invalid',
          'commit',
          '-m',
          'fixture',
        ],
      ]) {
        final result = Process.runSync('git', args, workingDirectory: core);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }
      write('driver.dart', '''
import 'dart:convert';
import 'dart:io';
import 'package:setup_hooks/src/build.dart';
import 'package:setup_hooks/src/target.dart';
Future<void> main(List<String> args) async {
  final report = await buildPlatform(BuildRequest(rootDir: args[0], target: Target.resolve(platform: 'macos', arch: args[1]), macOSCompiler: Uri.file(args[2])));
  stdout.writeln(jsonEncode({'rebuilt': report.rebuilt, 'inputs': report.inputs, 'outputs': report.outputs}));
}
''');
      write('tools.dart', r'''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> arguments) async {
  final args = arguments.toList();
  final tool = args.removeAt(0);
  final sdk = Platform.environment['FIXTURE_SDK']!;
  if (tool == 'xcrun') {
    final developer = Directory(sdk).parent.parent.path.replaceAll(r'\', '/');
    if (Platform.environment['DEVELOPER_DIR']?.replaceAll(r'\', '/') != developer) {
      throw StateError('SDK discovery ignored the compiler-selected Xcode');
    }
    if (args.join(' ') == '--sdk macosx --show-sdk-path') {
      stdout.writeln(sdk);
    } else if (args.join(' ') == '--sdk macosx --show-sdk-version') {
      stdout.writeln('26.2');
    } else if (args.length == 4 && args[2] == '--find') {
      stdout.writeln('$sdk/../../Toolchains/XcodeDefault.xctoolchain/usr/bin/${args[3]}');
    } else {
      throw StateError('Unexpected SDK discovery command: $args');
    }
    return;
  }
  if (tool != 'cargo' || args.contains('--version')) {
    stdout.writeln('Fixture $tool version 1');
    return;
  }
  final environment = Platform.environment;
  final target = args[args.indexOf('--target') + 1];
  final triple = target.replaceAll('-', '_');
  final compiler = environment['CC_$triple'];
  if (environment['SDKROOT'] != sdk ||
      compiler == null || !compiler.contains('XcodeDefault.xctoolchain') ||
      environment['MACOSX_DEPLOYMENT_TARGET'] != '12.0' ||
      environment['CMAKE_OSX_SYSROOT'] != sdk ||
      environment['DEVELOPER_DIR'] == null ||
      !('${environment['BINDGEN_EXTRA_CLANG_ARGS_$triple']}'.contains(sdk))) {
    stderr.writeln('Missing selected Apple SDK/compiler/deployment target at actual Cargo process');
    exitCode = 7;
    return;
  }
  final directory = args[args.indexOf('--target-dir') + 1];
  final output = File('$directory/$target/release/flclash-meow-host');
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(jsonEncode({
    'sdk': environment['SDKROOT'],
    'compiler': compiler,
    'deployment': environment['MACOSX_DEPLOYMENT_TARGET'],
    'arguments': args,
  }));
}
''');
      final tools = p.join(root.path, 'tools.dart');
      final dart = Platform.resolvedExecutable;
      for (final tool in ['cargo', 'rustc', 'cmake', 'xcrun']) {
        final file = p.join('bin', '$tool${Platform.isWindows ? '.cmd' : ''}');
        write(
          file,
          Platform.isWindows
              ? '@echo off\r\n"$dart" "$tools" $tool %*\r\n'
              : '#!/bin/sh\nexec "$dart" "$tools" $tool "\$@"\n',
        );
        if (!Platform.isWindows) {
          expect(
            Process.runSync('chmod', ['+x', p.join(root.path, file)]).exitCode,
            0,
          );
        }
      }
      String sdk(String name) {
        final path = p.normalize(
          p.join(root.path, name, 'Contents/Developer/SDKs/MacOSX26.2.sdk'),
        );
        Directory(path).createSync(recursive: true);
        File(
          p.join(path, 'SDKSettings.json'),
        ).writeAsStringSync('{"Version":"26.2"}');
        for (final tool in ['clang', 'clang++', 'ar']) {
          final file = File(
            p.join(
              root.path,
              name,
              'Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/$tool${Platform.isWindows ? '.cmd' : ''}',
            ),
          );
          file.parent.createSync(recursive: true);
          file.writeAsStringSync(
            Platform.isWindows
                ? '@echo off\r\n"$dart" "$tools" $tool %*\r\n'
                : '#!/bin/sh\nexec "$dart" "$tools" $tool "\$@"\n',
          );
          if (!Platform.isWindows) {
            expect(Process.runSync('chmod', ['+x', file.path]).exitCode, 0);
          }
        }
        return path;
      }

      final firstSdk = sdk('Xcode first.app');
      final secondSdk = sdk('Xcode second.app');
      Map<String, dynamic> build(String sdk, String arch) {
        final separator = Platform.isWindows ? ';' : ':';
        final result = Process.runSync(
          dart,
          [
            '--packages=${p.absolute('.dart_tool/package_config.json')}',
            p.join(root.path, 'driver.dart'),
            root.path,
            arch,
            p.normalize(
              p.join(
                sdk,
                '../../Toolchains/XcodeDefault.xctoolchain/usr/bin/clang',
              ),
            ),
          ],
          environment: {
            'PATH':
                '${p.join(root.path, 'bin')}$separator${Platform.environment['PATH']}',
            'FIXTURE_SDK': sdk,
          },
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        return jsonDecode((result.stdout as String).trim().split('\n').last)
            as Map<String, dynamic>;
      }

      for (final arch in ['amd64', 'arm64']) {
        expect(build(firstSdk, arch)['rebuilt'], true);
        final cached = build(firstSdk, arch);
        expect(cached['rebuilt'], false);
        expect(
          cached['inputs'],
          contains(p.join(firstSdk, 'SDKSettings.json')),
        );
        File(
          p.join(firstSdk, 'SDKSettings.json'),
        ).writeAsStringSync('{"Version":"changed-$arch"}');
        expect(build(firstSdk, arch)['rebuilt'], true);
        expect(build(secondSdk, arch)['rebuilt'], true);
        final output = jsonDecode(
          File(
            p.join(root.path, 'libclash/macos/FlClashMeowCore'),
          ).readAsStringSync(),
        );
        expect(output['sdk'], secondSdk);
        expect(output['deployment'], '12.0');
        expect(
          output['arguments'],
          containsAll([
            '--locked',
            '--release',
            '--package',
            'flclash-meow-host',
          ]),
        );
      }
    },
  );
}
