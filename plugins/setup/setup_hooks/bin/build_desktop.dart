import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:setup_hooks/src/build.dart';
import 'package:setup_hooks/src/logging.dart';
import 'package:setup_hooks/src/target.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart run bin/build_desktop.dart <windows|linux|macos> <x64|arm64>',
    );
    exitCode = 64;
    return;
  }
  final harness = p.normalize(
    p.join(p.dirname(Platform.script.toFilePath()), '..'),
  );
  final root = p.normalize(p.join(harness, '..', '..', '..'));
  initLogging(logFile: hookLogPath(root));
  try {
    final report = await buildPlatform(
      BuildRequest(
        rootDir: root,
        harnessDir: harness,
        target: Target.resolve(platform: args[0], arch: args[1]),
      ),
    );
    stdout.writeln(
      '${report.rebuilt ? 'Built' : 'Cached'} ${report.outputs.join(', ')}',
    );
  } finally {
    closeLogging();
  }
}
