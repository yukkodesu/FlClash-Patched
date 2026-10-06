import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../setup.dart' as setup;

void main() {
  test(
    'portable package preserves executable and creates isolated config',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'meow_setup_portable_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final zip = File(p.join(temp.path, 'FlClash-Meow.zip'));
      final archive = Archive()
        ..addFile(ArchiveFile.string('FlClashMeow', 'executable'));
      await zip.writeAsBytes(ZipEncoder().encode(archive));

      await setup.injectPortableConfigDirIntoZip(zip.path);
      await setup.injectPortableConfigDirIntoZip(zip.path);

      final packaged = ZipDecoder().decodeBytes(await zip.readAsBytes());
      expect(packaged.find('FlClashMeow')?.readBytes(), 'executable'.codeUnits);
      expect(
        packaged.files.where((file) => file.name == 'config/'),
        hasLength(1),
      );
    },
  );

  test('rejects mobile packages and obsolete architecture variants', () {
    expect(
      () => setup.createPackageTargets('android', null),
      throwsArgumentError,
    );
    expect(() => setup.createPackageTargets('ios', null), throwsArgumentError);
    expect(() => setup.parsePackageArchitecture('x64-v3'), throwsArgumentError);
    expect(() => setup.parsePackageArchitecture('arm'), throwsArgumentError);
  });

  test(
    'requires matching Windows and Linux machines but allows macOS slices',
    () {
      expect(
        setup
            .resolvePackageArchitecture(
              platform: 'windows',
              requested: 'amd64',
              hostArch: 'x64',
            )
            .name,
        'x64',
      );
      expect(
        () => setup.resolvePackageArchitecture(
          platform: 'linux',
          requested: 'x64',
          hostArch: 'arm64',
        ),
        throwsArgumentError,
      );
      expect(
        setup
            .resolvePackageArchitecture(
              platform: 'macos',
              requested: 'x64',
              hostArch: 'arm64',
            )
            .name,
        'x64',
      );
    },
  );

  test('pins macOS native targets to the requested package architecture', () {
    expect(
      setup.createMacosBuildConfig('x64'),
      'ARCHS = x86_64\nEXCLUDED_ARCHS = arm64\n',
    );
    expect(
      setup.createMacosBuildConfig('arm64'),
      'ARCHS = arm64\nEXCLUDED_ARCHS = x86_64\n',
    );
    expect(() => setup.createMacosBuildConfig('arm'), throwsArgumentError);
  });

  test('refuses packaging when either native build hook is disabled', () {
    const pubspec = '''
hooks:
  user_defines:
    setup:
      build_assets: false
    rust_api:
      build_assets: false
''';
    expect(setup.packagesNotBuildingAssets(pubspec), ['rust_api', 'setup']);
    expect(setup.packagesNotBuildingAssets('name: x\n'), isEmpty);
  });

  test('packages supported Linux formats and rejects broken RPM output', () {
    expect(
      setup.createPackageTargets('linux', null),
      'deb,pacman,appimage,zip',
    );
    expect(setup.createPackageTargets('linux', 'deb'), 'deb');
    expect(
      () => setup.createPackageTargets('linux', 'deb,rpm'),
      throwsArgumentError,
    );
    expect(setup.createPackageTargets('macos', null), 'dmg');
  });
}
