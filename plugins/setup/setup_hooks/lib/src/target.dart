import 'error.dart';

class Target {
  const Target({required this.platform, required this.arch});

  final String platform;
  final String arch;

  static const macosArm64 = Target(platform: 'macos', arch: 'arm64');
  static const macosX64 = Target(platform: 'macos', arch: 'x64');
  static const linuxArm64 = Target(platform: 'linux', arch: 'arm64');
  static const linuxX64 = Target(platform: 'linux', arch: 'x64');
  static const windowsX64 = Target(platform: 'windows', arch: 'x64');
  static const windowsArm64 = Target(platform: 'windows', arch: 'arm64');

  static const all = [
    macosArm64,
    macosX64,
    linuxArm64,
    linuxX64,
    windowsX64,
    windowsArm64,
  ];

  static List<Target> forPlatform(String platform) =>
      all.where((target) => target.platform == platform).toList();

  static Target resolve({required String platform, required String arch}) {
    final normalized = arch == 'amd64' ? 'x64' : arch;
    for (final target in forPlatform(platform)) {
      if (target.arch == normalized) return target;
    }
    throw BuildException('No desktop Core target for $platform/$arch');
  }

  bool get hasHelper => platform == 'linux' || platform == 'windows';
  String get executableExtension => platform == 'windows' ? '.exe' : '';
  String get platformDir => platform;

  String get rustTriple {
    final rustArch = arch == 'x64' ? 'x86_64' : 'aarch64';
    return switch (platform) {
      'windows' => '$rustArch-pc-windows-msvc',
      'linux' => '$rustArch-unknown-linux-gnu',
      'macos' => '$rustArch-apple-darwin',
      _ => throw BuildException('No Rust target for $this'),
    };
  }

  @override
  String toString() => '$platform/$arch';
}
