import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'build_cache.dart';
import 'fingerprint.dart';
import 'options.dart';
import 'target.dart';
import 'util.dart';

final _log = Logger('rust_builder');

class RustBuilder {
  RustBuilder({
    required this.rootDir,
    required this.config,
    required this.cache,
    required this.notice,
    this.harnessInputs = const [],
  });

  final String rootDir;
  final BuildConfig config;
  final BuildCache cache;
  final BuildNotice notice;
  final List<String> harnessInputs;

  String get _helperPath => p.join(rootDir, config.helperDir);
  String get _outputPath => p.join(rootDir, config.outputDir);

  Future<BuildExecution> build(Target target, String coreSha256) async {
    final triple = target.rustTriple;
    final args = [
      'build',
      '--locked',
      '--target',
      triple,
      '--target-dir',
      p.join(_helperPath, 'target'),
      if (target.platform == 'windows') ...['--features', 'windows-service'],
      '--release',
    ];
    final env = {
      'CORE_SHA256': coreSha256,
      'CORE_NAME': '${config.coreName}${target.executableExtension}',
    };

    final srcPath = p.join(
      _helperPath,
      'target',
      triple,
      'release',
      'helper${target.executableExtension}',
    );
    final destDir = p.join(_outputPath, target.platformDir);
    final destPath = p.join(
      destDir,
      '${config.helperName}${target.executableExtension}',
    );
    return cache.run(
      key: '${target.platformDir}-${target.arch}-helper-release',
      fingerprint: () => _calculateFingerprint(
        target: target,
        coreSha256: coreSha256,
        args: args,
      ),
      primaryOutput: destPath,
      notice: notice,
      build: () async {
        _log.info('Building Rust helper: $target');

        await runCommandStream(
          'cargo',
          args,
          workingDirectory: _helperPath,
          environment: env,
        );

        ensureDir(destDir);
        copyFile(srcPath, destPath);

        _log.info('Built: $destPath');
        return [destPath];
      },
    );
  }

  Future<Fingerprint> _calculateFingerprint({
    required Target target,
    required String coreSha256,
    required List<String> args,
  }) async {
    final builder = FingerprintBuilder(rootDir: rootDir)
      ..addValue('cache_schema', BuildCache.schemaVersion)
      ..addValue('kind', 'helper')
      ..addValue('target', {'platform': target.platform, 'arch': target.arch})
      ..addValue('arguments', args)
      ..addValue('core_sha256', coreSha256)
      ..addValue('environment', rustEnvironment())
      ..addValue('config', config.toFingerprintMap());

    addRustToolchain(builder, workingDirectory: _helperPath);

    final inputs = collectFiles(
      _helperPath,
      excludedDirectories: const {'target', '.git', '.idea'},
    )..addAll(harnessInputs);
    builder.addFiles(inputs);
    return builder.finishWithInputs();
  }
}

Map<String, String> rustEnvironment() {
  const exactKeys = {
    'CARGO_BUILD_TARGET',
    'CARGO_ENCODED_RUSTFLAGS',
    'RUSTFLAGS',
    'RUSTUP_TOOLCHAIN',
    'RUSTC_WRAPPER',
    'RUSTC_WORKSPACE_WRAPPER',
    'CARGO_TARGET_DIR',
    'PATH',
    'CC',
    'CXX',
    'AR',
    'CFLAGS',
    'CXXFLAGS',
    'CMAKE_GENERATOR',
    'CMAKE_TOOLCHAIN_FILE',
    'LIBCLANG_PATH',
  };
  final values = <String, String>{};
  final entries = Platform.environment.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  for (final entry in entries) {
    if (exactKeys.contains(entry.key) ||
        entry.key.startsWith('CARGO_PROFILE_') ||
        entry.key.startsWith('CARGO_TARGET_') ||
        entry.key.startsWith('CMAKE_') ||
        entry.key.startsWith('BINDGEN_') ||
        entry.key.startsWith('CC_') ||
        entry.key.startsWith('CXX_') ||
        entry.key.startsWith('MEOW_') ||
        entry.key.startsWith('BORING_')) {
      values[entry.key] = entry.value;
    }
  }
  return values;
}

void addRustToolchain(
  FingerprintBuilder builder, {
  required String workingDirectory,
  bool nativeDependencies = false,
}) {
  for (final (name, args) in [
    ('cargo', ['--version']),
    ('rustc', ['-Vv']),
    if (nativeDependencies) ('cmake', ['--version']),
  ]) {
    final result = runCommand(name, args, workingDirectory: workingDirectory);
    builder.addValue('${name}_version', (result.stdout as String).trim());
  }
}
