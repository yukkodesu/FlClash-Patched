import 'dart:io';

import 'package:path/path.dart' as p;

import 'build_cache.dart';
import 'fingerprint.dart';
import 'macos_toolchain.dart';
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
    this.macOSDeploymentTarget,
    this.macOSCompiler,
  });

  final String rootDir;
  final BuildConfig config;
  final BuildCache cache;
  final BuildNotice notice;
  final List<String> harnessInputs;
  final String? macOSDeploymentTarget;
  final Uri? macOSCompiler;

  Future<BuildExecution> build(Target target) {
    final apple = target.platform == 'macos'
        ? MacOSCargoToolchain.resolve(
            rustTriple: target.rustTriple,
            compiler: macOSCompiler,
            deploymentTarget:
                macOSDeploymentTarget ??
                Platform.environment['MACOSX_DEPLOYMENT_TARGET'] ??
                '12.0',
          )
        : null;
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
          ..addValue('environment', {
            ...rustEnvironment(),
            ...?apple?.environment,
          })
          ..addValue('apple_toolchain', apple?.fingerprint);
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
          ...?apple?.inputs,
        ]);
        return builder.finishWithInputs();
      },
      build: () async {
        await runCommandStream(
          'cargo',
          args,
          workingDirectory: corePath,
          environment: {'MEOW_HOST_COMMIT': commit, ...?apple?.environment},
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
