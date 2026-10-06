import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

const _allTargets = <String, String>{
  'linux': 'deb,pacman,appimage,zip',
  'macos': 'dmg',
  'windows': 'exe,zip',
};

Future<void> main(List<String> args) async {
  final parser = createSetupArgParser();
  if (args.contains('--help') || args.contains('-h')) {
    _showHelp(parser);
    return;
  }
  final results = parser.parse(args);
  final host = Platform.operatingSystem;
  final platform = results.rest.isEmpty ? host : results.rest.first;
  if (!_allTargets.containsKey(platform) || platform != host) {
    stderr.writeln('Build a desktop package on its matching operating system.');
    _showHelp(parser);
    exitCode = 64;
    return;
  }
  final rootDir = Directory.current.path;
  final skipped = packagesNotBuildingAssets(
    File(p.join(rootDir, 'pubspec.yaml')).readAsStringSync(),
  );
  if (skipped.isNotEmpty) {
    stderr.writeln(
      'Restore build_assets: true for ${skipped.join(', ')} before packaging.',
    );
    exitCode = 1;
    return;
  }
  final PackageArchitecture arch;
  try {
    arch = resolvePackageArchitecture(
      platform: platform,
      requested: results['arch'] as String?,
      hostArch: _detectArch(),
    );
  } on ArgumentError catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
    return;
  }
  exitCode = await _package(
    platform,
    results['env'] as String,
    createPackageTargets(platform, results['targets'] as String?),
    rootDir,
    arch,
    skipDependencies: results['skip-dependencies'] as bool,
    verbose: results['verbose'] as bool,
  );
}

ArgParser createSetupArgParser() => ArgParser()
  ..addOption(
    'env',
    defaultsTo: 'pre',
    allowed: ['dev', 'pre', 'stable'],
    help: 'Application environment',
  )
  ..addOption(
    'targets',
    valueHelp: 'exe,zip,dmg,...',
    help: 'Package targets (default: all for platform)',
  )
  ..addOption(
    'arch',
    allowed: ['arm64', 'x64', 'amd64'],
    help: 'Target desktop architecture',
  )
  ..addFlag(
    'skip-dependencies',
    abbr: 's',
    negatable: false,
    help: 'Skip installing platform build dependencies',
  )
  ..addFlag(
    'verbose',
    abbr: 'v',
    negatable: false,
    help: 'Enable verbose Flutter build output',
  );

List<String> createFlutterBuildArgs({
  required String platform,
  required bool verbose,
}) => [if (verbose) 'verbose', 'dart-define-from-file=env.json'];

Map<String, String> createBuildEnvironment(String env) => {'APP_ENV': env};

String createMacosBuildConfig(String arch) {
  final (target, excluded) = switch (parsePackageArchitecture(arch).name) {
    'x64' => ('x86_64', 'arm64'),
    'arm64' => ('arm64', 'x86_64'),
    _ => throw ArgumentError.value(
      arch,
      'arch',
      'Unsupported macOS architecture',
    ),
  };
  return 'ARCHS = $target\nEXCLUDED_ARCHS = $excluded\n';
}

List<String> packagesNotBuildingAssets(String pubspec) {
  final document = loadYaml(pubspec);
  if (document is! Map) return const [];
  final defines = (document['hooks'] as Map?)?['user_defines'];
  if (defines is! Map) return const [];
  return [
    for (final MapEntry(:key, :value) in defines.entries)
      if (value is Map && value['build_assets'] == false) key.toString(),
  ]..sort();
}

String createPackageTargets(String platform, String? customTargets) {
  if (!_allTargets.containsKey(platform)) {
    throw ArgumentError.value(platform, 'platform', 'Desktop platforms only');
  }
  if (platform == 'linux' &&
      customTargets?.split(',').any((target) => target.trim() == 'rpm') ==
          true) {
    throw ArgumentError.value(
      customTargets,
      'targets',
      'RPM is unavailable: the packager ignores uninstall hooks and Core hash protection',
    );
  }
  return customTargets ?? _allTargets[platform]!;
}

class PackageArchitecture {
  const PackageArchitecture({required this.name});
  final String name;
  String get flutterArch => name;
}

PackageArchitecture parsePackageArchitecture(String arch) {
  final normalized = arch == 'amd64' ? 'x64' : arch;
  if (normalized != 'x64' && normalized != 'arm64') {
    throw ArgumentError.value(arch, 'arch', 'Expected arm64 or x64');
  }
  return PackageArchitecture(name: normalized);
}

PackageArchitecture resolvePackageArchitecture({
  required String platform,
  required String? requested,
  required String hostArch,
}) {
  if (!_allTargets.containsKey(platform)) {
    throw ArgumentError('Desktop platforms only');
  }
  final parsed = parsePackageArchitecture(requested ?? hostArch);
  if (platform != 'macos' &&
      parsed.name != parsePackageArchitecture(hostArch).name) {
    throw ArgumentError(
      'Build $platform/${parsed.name} on a matching architecture machine.',
    );
  }
  return parsed;
}

void _showHelp(ArgParser parser) {
  stderr.writeln('Usage: dart setup.dart [windows|linux|macos] [options]');
  _allTargets.forEach(
    (platform, targets) => stderr.writeln('  $platform: $targets'),
  );
  stderr.writeln(parser.usage);
}

Future<int> _package(
  String platform,
  String env,
  String targets,
  String rootDir,
  PackageArchitecture arch, {
  required bool skipDependencies,
  required bool verbose,
}) async {
  await File(
    p.join(rootDir, 'env.json'),
  ).writeAsString(jsonEncode(createBuildEnvironment(env)));
  if (!skipDependencies) {
    final result = await _ensureDependencies(platform);
    if (result != 0) return result;
  }
  final activateResult = await Process.run('dart', [
    'pub',
    'global',
    'activate',
    '-s',
    'git',
    'https://github.com/chenx-dust/flutter_distributor.git',
    '--git-ref',
    'FlClash',
    '--git-path',
    'packages/flutter_distributor',
  ], runInShell: Platform.isWindows);
  if (activateResult.exitCode != 0) {
    stderr.write(activateResult.stderr);
    return activateResult.exitCode;
  }
  final buildEnvironment = <String, String>{};
  if (platform == 'macos') {
    final config = File(
      p.join(rootDir, '.dart_tool', 'macos-${arch.name}.xcconfig'),
    );
    await config.parent.create(recursive: true);
    await config.writeAsString(createMacosBuildConfig(arch.name));
    buildEnvironment['XCODE_XCCONFIG_FILE'] = config.path;
  }
  final process = await Process.start(
    'flutter_distributor',
    [
      'package',
      '--skip-clean',
      '--platform',
      platform,
      '--targets',
      targets,
      '--flutter-build-args=${createFlutterBuildArgs(platform: platform, verbose: verbose).join(',')}',
      '--description',
      arch.name,
    ],
    includeParentEnvironment: true,
    environment: buildEnvironment,
    runInShell: Platform.isWindows,
  );
  process.stdout.listen((data) => stdout.write(systemEncoding.decode(data)));
  process.stderr.listen((data) => stderr.write(systemEncoding.decode(data)));
  final result = await process.exitCode;
  if (result == 0 && (platform == 'windows' || platform == 'linux')) {
    await _injectPortableConfigDir(rootDir);
  }
  return result;
}

Future<void> _injectPortableConfigDir(String rootDir) async {
  final distDir = Directory(p.join(rootDir, 'dist'));
  if (!await distDir.exists()) return;
  await for (final entity in distDir.list(recursive: true)) {
    if (entity is! File || !entity.path.toLowerCase().endsWith('.zip')) {
      continue;
    }
    try {
      await injectPortableConfigDirIntoZip(entity.path);
      stdout.writeln('Injected config/ into ${entity.path}');
    } catch (e) {
      stderr.writeln('Failed to inject config/ into ${entity.path}: $e');
    }
  }
}

Future<void> injectPortableConfigDirIntoZip(String zipPath) async {
  final bytes = await File(zipPath).readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  if (archive.find('config/') != null) {
    return;
  }
  archive.addFile(ArchiveFile.directory('config/'));
  final encoded = ZipEncoder().encode(archive);
  final tmp = File('$zipPath.tmp');
  await tmp.writeAsBytes(encoded, flush: true);
  await tmp.rename(zipPath);
}

String _detectArch() {
  if (Platform.isWindows) {
    final pa = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? 'AMD64';
    return pa.toUpperCase() == 'ARM64' ? 'arm64' : 'x64';
  }
  final result = Process.runSync('uname', ['-m']);
  final machine = (result.stdout as String).trim();
  if (machine == 'aarch64') return 'arm64';
  if (machine == 'x86_64') return 'x64';
  return machine;
}

Future<bool> _hasCommand(String cmd) async {
  final which = Platform.isWindows ? 'where' : 'command';
  final args = Platform.isWindows ? [cmd] : ['-v', cmd];
  final result = await Process.run(which, args);
  return result.exitCode == 0;
}

Future<int> _ensureDependencies(String platform) async {
  switch (platform) {
    case 'macos':
      return _ensureMacosDependencies();
    case 'linux':
      return _ensureLinuxDependencies();
    default:
      return 0;
  }
}

Future<int> _ensureMacosDependencies() async {
  if (await _hasCommand('appdmg')) {
    stdout.writeln('appdmg already installed, skipping.');
    return 0;
  }
  stdout.writeln('Installing appdmg (DMG creator)...');
  final result = await Process.run('npm', ['install', '-g', 'appdmg']);
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
  }
  return result.exitCode;
}

Future<int> _ensureLinuxDependencies() async {
  const pkgGroups = <List<String>>[
    ['ninja-build', 'libgtk-3-dev'],
    ['libayatana-appindicator3-dev'],
    ['libsecret-1-dev'],
    ['locate'],
    ['libarchive-tools', 'patchelf'],
    ['libfuse2'],
  ];

  final missingGroups = <List<String>>[];
  for (final group in pkgGroups) {
    final missingPkgs = <String>[];
    for (final pkg in group) {
      if (!await _isDebianPackageInstalled(pkg)) {
        missingPkgs.add(pkg);
      }
    }
    if (missingPkgs.isNotEmpty) {
      missingGroups.add(missingPkgs);
    }
  }

  if (missingGroups.isEmpty) {
    stdout.writeln('All Linux build dependencies already installed, skipping.');
  } else {
    stdout.writeln('Updating apt package lists...');
    final updateExit = await _runLinuxDependencyCommand([
      'apt-get',
      'update',
      '-y',
    ]);
    if (updateExit != 0) {
      stderr.writeln(
        'apt-get update exited with $updateExit; continuing and verifying '
        'dependency installation directly.',
      );
    }

    for (final missingPkgs in missingGroups) {
      stdout.writeln(
        'Installing Linux build dependencies: ${missingPkgs.join(', ')}...',
      );
      final installExit = await _installLinuxPackages(missingPkgs);
      if (installExit != 0) return installExit;
    }
  }

  const appimagetool = '/usr/local/bin/appimagetool';
  if (File(appimagetool).existsSync()) {
    stdout.writeln('appimagetool already installed, skipping.');
    return 0;
  }
  stdout.writeln('Downloading appimagetool...');
  final downloadName =
      'appimagetool-${appImageToolArch(_detectArch())}.AppImage';
  final dlResult = await Process.run('wget', [
    '-O',
    appimagetool,
    'https://github.com/AppImage/appimagetool/releases/download/continuous/$downloadName',
  ]);
  if (dlResult.exitCode != 0) {
    stderr.write(dlResult.stderr);
    return dlResult.exitCode;
  }
  await Process.run('chmod', ['+x', appimagetool]);
  return 0;
}

String appImageToolArch(String arch) {
  return arch == 'arm64' ? 'aarch64' : 'x86_64';
}

/// Ubuntu 24.04 ships libfuse2 under its time64 name, which `dpkg -s libfuse2` cannot see.
const _debianPackageAliases = <String, List<String>>{
  'libfuse2': ['libfuse2t64'],
};

Future<bool> _isDebianPackageInstalled(String pkg) async {
  for (final name in [pkg, ...?_debianPackageAliases[pkg]]) {
    final result = await Process.run('dpkg', ['-s', name]);
    if (result.exitCode == 0 &&
        (result.stdout as String).contains('Status: install ok installed')) {
      return true;
    }
  }
  return false;
}

Future<bool> _areDebianPackagesInstalled(List<String> pkgs) async {
  for (final pkg in pkgs) {
    if (!await _isDebianPackageInstalled(pkg)) {
      return false;
    }
  }
  return true;
}

Future<int> _installLinuxPackages(List<String> pkgs) async {
  final exitCode = await _runLinuxDependencyCommand([
    'apt-get',
    'install',
    '-y',
    ...pkgs,
  ]);
  if (exitCode == 0) return 0;

  if (await _areDebianPackagesInstalled(pkgs)) {
    stderr.writeln(
      'apt-get install exited with $exitCode, but all requested packages are '
      'installed; continuing.',
    );
    return 0;
  }

  return exitCode;
}

Future<int> _runLinuxDependencyCommand(List<String> command) async {
  final sudoCommand = [
    'env',
    'DEBIAN_FRONTEND=noninteractive',
    'NEEDRESTART_MODE=a',
    ...command,
  ];
  stdout.writeln('exec: sudo ${sudoCommand.join(' ')}');
  final result = await Process.start('sudo', sudoCommand);
  result.stdout.listen((data) {
    stdout.write(utf8.decode(data));
  });
  result.stderr.listen((data) {
    stderr.write(utf8.decode(data));
  });
  final exitCode = await result.exitCode;
  if (exitCode != 0) {
    stderr.writeln('Linux dependency command failed with exit code $exitCode.');
  }
  return exitCode;
}
