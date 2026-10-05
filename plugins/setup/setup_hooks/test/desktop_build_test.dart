import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:setup_hooks/src/build.dart';
import 'package:setup_hooks/src/error.dart';
import 'package:setup_hooks/src/target.dart';
import 'package:test/test.dart';

void main() {
  test(
    'packages the Rust host and matching Helper, preserving a failed build',
    () async {
      final root = Directory.systemTemp.createTempSync('meow_desktop_build_');
      addTearDown(() => root.deleteSync(recursive: true));
      final target = Target.resolve(
        platform: Platform.operatingSystem,
        arch: Platform.version.contains('arm64') ? 'arm64' : 'amd64',
      );
      void write(String name, String value) {
        File(p.join(root.path, name))
          ..createSync(recursive: true)
          ..writeAsStringSync(value);
      }

      write('core/meow-rs/Cargo.toml', '''
[package]
name = "flclash-meow-host"
version = "0.1.0"
edition = "2021"
''');
      write(
        'core/meow-rs/src/main.rs',
        'fn main() { println!("first {}", env!("MEOW_HOST_COMMIT")); }',
      );
      write('core/meow-rs/build.rs', r'''
fn main() {
    println!("cargo:rustc-env=MEOW_HOST_COMMIT={}", std::env::var("MEOW_HOST_COMMIT").unwrap());
    println!("cargo:rerun-if-env-changed=MEOW_HOST_COMMIT");
}
''');
      write('services/helper/Cargo.toml', '''
[package]
name = "helper"
version = "0.1.0"
edition = "2021"
[features]
windows-service = []
''');
      write('services/helper/build.rs', r'''
fn main() {
    println!("cargo:rustc-env=CORE_SHA256={}", std::env::var("CORE_SHA256").unwrap());
    println!("cargo:rerun-if-env-changed=CORE_SHA256");
}
''');
      write(
        'services/helper/src/main.rs',
        'fn main() { println!(env!("CORE_SHA256")); }',
      );
      for (final dir in ['core/meow-rs', 'services/helper']) {
        final result = Process.runSync('cargo', [
          'generate-lockfile',
        ], workingDirectory: p.join(root.path, dir));
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }
      final coreDir = p.join(root.path, 'core', 'meow-rs');
      for (final args in [
        ['init'],
        ['add', '.'],
        [
          '-c',
          'user.name=Build fixture',
          '-c',
          'user.email=build@example.invalid',
          'commit',
          '-m',
          'fixture',
        ],
      ]) {
        final result = Process.runSync('git', args, workingDirectory: coreDir);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }
      final commit =
          (Process.runSync('git', [
                    'rev-parse',
                    'HEAD',
                  ], workingDirectory: coreDir).stdout
                  as String)
              .trim();
      final request = BuildRequest(rootDir: root.path, target: target);
      final core = File(
        p.join(
          root.path,
          'libclash',
          target.platformDir,
          'FlClashMeowCore${target.executableExtension}',
        ),
      );
      final helper = File(
        p.join(
          core.parent.path,
          'FlClashMeowHelperService${target.executableExtension}',
        ),
      );
      final manifest = File(p.join(core.parent.path, 'manifest.json'));

      expect((await buildPlatform(request)).rebuilt, isTrue);
      expect(
        (Process.runSync(core.path, []).stdout as String).trim(),
        'first $commit',
      );
      final firstCore = await core.readAsBytes();
      final firstHash = sha256.convert(firstCore).toString();
      if (target.hasHelper) {
        expect(
          (Process.runSync(helper.path, []).stdout as String).trim(),
          firstHash,
        );
        expect(jsonDecode(await manifest.readAsString()), {
          'coreSha256': firstHash,
        });
      }
      expect((await buildPlatform(request)).rebuilt, isFalse);

      final advance = Process.runSync('git', [
        '-c',
        'user.name=Build fixture',
        '-c',
        'user.email=build@example.invalid',
        'commit',
        '--allow-empty',
        '-m',
        'advance pin',
      ], workingDirectory: coreDir);
      expect(advance.exitCode, 0, reason: '${advance.stderr}');
      final advancedCommit =
          (Process.runSync('git', [
                    'rev-parse',
                    'HEAD',
                  ], workingDirectory: coreDir).stdout
                  as String)
              .trim();
      expect((await buildPlatform(request)).rebuilt, isTrue);
      expect(
        (Process.runSync(core.path, []).stdout as String).trim(),
        'first $advancedCommit',
      );
      expect((await buildPlatform(request)).rebuilt, isFalse);

      write('core/meow-rs/src/main.rs', 'fn main() { println!("second"); }');
      expect((await buildPlatform(request)).rebuilt, isTrue);
      final secondCore = await core.readAsBytes();
      expect(secondCore, isNot(firstCore));
      if (target.hasHelper) {
        expect(
          (Process.runSync(helper.path, []).stdout as String).trim(),
          sha256.convert(secondCore).toString(),
        );
      }
      final previousManifest = manifest.existsSync()
          ? manifest.readAsStringSync()
          : null;
      write('core/meow-rs/src/main.rs', 'compile_error!("invalid host");');
      await expectLater(
        buildPlatform(request),
        throwsA(isA<CommandFailedException>()),
      );
      expect(await core.readAsBytes(), secondCore);
      if (previousManifest != null) {
        expect(await manifest.readAsString(), previousManifest);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
