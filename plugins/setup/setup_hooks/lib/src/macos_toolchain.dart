import 'dart:io';

import 'package:path/path.dart' as p;

import 'util.dart';

final class MacOSCargoToolchain {
  MacOSCargoToolchain._(this.environment, this.fingerprint, this.inputs);

  final Map<String, String> environment;
  final Map<String, String> fingerprint;
  final List<String> inputs;

  factory MacOSCargoToolchain.resolve({
    required String rustTriple,
    required String deploymentTarget,
    Uri? compiler,
  }) {
    final compilerPath = compiler == null ? null : p.fromUri(compiler);
    final toolchains = compilerPath?.indexOf(
      '${p.separator}Toolchains${p.separator}',
    );
    final developer = toolchains != null && toolchains > 0
        ? compilerPath!.substring(0, toolchains)
        : null;
    final selection = <String, String>{'DEVELOPER_DIR': ?developer};
    String xcrun(List<String> args) =>
        (runCommand('xcrun', [
                  '--sdk',
                  'macosx',
                  ...args,
                ], environment: selection).stdout
                as String)
            .trim();
    final sdk = xcrun(['--show-sdk-path']);
    if (!Directory(sdk).existsSync()) {
      throw FileSystemException('Selected macOS SDK does not exist', sdk);
    }
    final clang = xcrun(['--find', 'clang']);
    final clangPlusPlus = xcrun(['--find', 'clang++']);
    final ar = xcrun(['--find', 'ar']);
    final triple = rustTriple.replaceAll('-', '_');
    final environment = {
      ...selection,
      'SDKROOT': sdk,
      'MACOSX_DEPLOYMENT_TARGET': deploymentTarget,
      'CC_$triple': clang,
      'CXX_$triple': clangPlusPlus,
      'AR_$triple': ar,
      'CARGO_TARGET_${triple.toUpperCase()}_LINKER': clang,
      'CMAKE_OSX_SYSROOT': sdk,
      'CMAKE_OSX_DEPLOYMENT_TARGET': deploymentTarget,
      'BINDGEN_EXTRA_CLANG_ARGS_$triple':
          '-isysroot "$sdk" -mmacosx-version-min=$deploymentTarget',
    };
    return MacOSCargoToolchain._(
      environment,
      {
        'sdk_version': xcrun(['--show-sdk-version']),
        'compiler_version': (runCommand(clang, ['--version']).stdout as String)
            .trim(),
      },
      [
        for (final file in ['SDKSettings.json', 'SDKSettings.plist'])
          if (File(p.join(sdk, file)).existsSync()) p.join(sdk, file),
      ],
    );
  }
}
