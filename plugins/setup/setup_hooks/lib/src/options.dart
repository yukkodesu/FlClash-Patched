import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

class BuildConfig {
  const BuildConfig({
    this.coreDir = 'core/meow-rs',
    this.coreName = 'FlClashMeowCore',
    this.outputDir = 'libclash',
    this.helperDir = 'services/helper',
    this.helperName = 'FlClashMeowHelperService',
  });

  final String coreDir;
  final String coreName;
  final String outputDir;
  final String helperDir;
  final String helperName;

  static BuildConfig load({required String rootDir}) {
    final file = File(p.join(rootDir, 'build_config.yaml'));
    if (!file.existsSync()) return const BuildConfig();
    final yaml = loadYaml(file.readAsStringSync()) as YamlMap?;
    if (yaml == null) return const BuildConfig();
    const defaults = BuildConfig();
    return BuildConfig(
      coreDir: yaml['core_dir'] as String? ?? defaults.coreDir,
      coreName: yaml['core_name'] as String? ?? defaults.coreName,
      outputDir: yaml['output_dir'] as String? ?? defaults.outputDir,
      helperDir: yaml['helper_dir'] as String? ?? defaults.helperDir,
      helperName: yaml['helper_name'] as String? ?? defaults.helperName,
    );
  }

  Map<String, String> toFingerprintMap() => {
    'core_dir': coreDir,
    'core_name': coreName,
    'output_dir': outputDir,
    'helper_dir': helperDir,
    'helper_name': helperName,
  };
}
