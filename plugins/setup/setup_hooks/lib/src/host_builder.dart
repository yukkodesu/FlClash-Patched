import 'dart:io';

import 'package:path/path.dart' as p;

import 'build_cache.dart';
import 'fingerprint.dart';
import 'options.dart';
import 'rust_builder.dart';
import 'target.dart';
import 'util.dart';

class HostBuilder {
  HostBuilder({
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

  Future<BuildExecution> build(Target target) {
    final corePath = p.join(rootDir, config.coreDir);
    String gitValue(List<String> args) =>
        (runCommand('git', args, workingDirectory: corePath).stdout as String)
            .trim();
    String gitPath(String name) => p.normalize(
      p.join(corePath, gitValue(['rev-parse', '--git-path', name])),
    );
    final commit = gitValue(['rev-parse', 'HEAD']);
    final reference = gitValue(['rev-parse', '--symbolic-full-name', 'HEAD']);
    final metadata = [
      gitPath('HEAD'),
      if (reference.startsWith('refs/') &&
          File(gitPath(reference)).existsSync())
        gitPath(reference),
    ];
    final args = [
      'build',
      '--locked',
      '--release',
      '--target',
      target.rustTriple,
      '--target-dir',
      p.join(corePath, 'target'),
      '--package',
      'flclash-meow-host',
      '--bin',
      'flclash-meow-host',
    ];
    final outFile = p.join(
      rootDir,
      config.outputDir,
      target.platformDir,
      '${config.coreName}${target.executableExtension}',
    );
    return cache.run(
      key: '${target.platform}-${target.arch}-meow-host-release',
      primaryOutput: outFile,
      notice: notice,
      fingerprint: () async {
        final builder = FingerprintBuilder(rootDir: rootDir)
          ..addValue('cache_schema', BuildCache.schemaVersion)
          ..addValue('kind', 'meow-host')
          ..addValue('source_commit', commit)
          ..addValue('arguments', args)
          ..addValue('config', config.toFingerprintMap())
          ..addValue('environment', rustEnvironment());
        addRustToolchain(
          builder,
          workingDirectory: corePath,
          nativeDependencies: true,
        );
        final wintun = Platform.environment['MEOW_WINTUN_DLL'];
        if (wintun != null && wintun.isNotEmpty) {
          builder.addFile(
            p.isAbsolute(wintun) ? wintun : p.join(corePath, wintun),
          );
        }
        builder.addFiles([
          ...metadata,
          ...collectFiles(
            corePath,
            excludedDirectories: const {'.git', 'target', '.idea'},
          ),
          ...harnessInputs,
        ]);
        return builder.finishWithInputs();
      },
      build: () async {
        await runCommandStream(
          'cargo',
          args,
          workingDirectory: corePath,
          environment: {'MEOW_HOST_COMMIT': commit},
        );
        copyFile(
          p.join(
            corePath,
            'target',
            target.rustTriple,
            'release',
            'flclash-meow-host${target.executableExtension}',
          ),
          outFile,
        );
        return [outFile];
      },
    );
  }
}
