import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'error.dart';

final _log = Logger('util');

/// Xcode and Flutter do not always expose the native dependencies on PATH.
final String? _toolSearchPath = _resolveToolSearchPath();

String? _resolveToolSearchPath() {
  final separator = Platform.isWindows ? ';' : ':';
  final entries = (Platform.environment['PATH'] ?? '').split(separator);
  final home = Platform.environment['HOME'];
  final candidates = [
    if (Platform.isWindows)
      ..._visualStudioToolDirectories()
    else ...[
      '/opt/homebrew/bin',
      '/usr/local/bin',
      if (home != null && home.isNotEmpty) p.join(home, '.cargo', 'bin'),
    ],
  ];
  final missing = candidates
      .where((dir) => !entries.contains(dir) && Directory(dir).existsSync())
      .toList();
  if (missing.isEmpty) return null;
  return [...entries, ...missing].join(separator);
}

List<String> _visualStudioToolDirectories() {
  final programFiles = Platform.environment['ProgramFiles(x86)'];
  if (programFiles == null) return const [];
  final vswhere = p.join(
    programFiles,
    'Microsoft Visual Studio',
    'Installer',
    'vswhere.exe',
  );
  if (!File(vswhere).existsSync()) return const [];
  final result = Process.runSync(vswhere, [
    '-latest',
    '-products',
    '*',
    '-requires',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    '-property',
    'installationPath',
  ]);
  final installation = (result.stdout as String).trim();
  if (result.exitCode != 0 || installation.isEmpty) return const [];
  return [
    p.join(
      installation,
      'Common7',
      'IDE',
      'CommonExtensions',
      'Microsoft',
      'CMake',
      'CMake',
      'bin',
    ),
    p.join(
      installation,
      'Common7',
      'IDE',
      'CommonExtensions',
      'Microsoft',
      'CMake',
      'Ninja',
    ),
  ];
}

Map<String, String>? _withToolSearchPath(Map<String, String>? environment) {
  final path = _toolSearchPath;
  if (path == null) return environment;
  return {...?environment, 'PATH': path};
}

ProcessResult runCommand(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
}) {
  _log.finer('Running: $executable ${arguments.join(' ')}');
  if (environment != null && environment.isNotEmpty) {
    _log.finer('  env: $environment');
  }
  final result = Process.runSync(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: _withToolSearchPath(environment),
    includeParentEnvironment: includeParentEnvironment,
    runInShell: Platform.isWindows,
    stdoutEncoding: systemEncoding,
    stderrEncoding: systemEncoding,
  );
  final out = (result.stdout as String).trim();
  final err = (result.stderr as String).trim();
  if (out.isNotEmpty) _log.finest(out);
  if (err.isNotEmpty) _log.finest(err);
  if (result.exitCode != 0) {
    throw CommandFailedException(
      executable: executable,
      arguments: arguments,
      exitCode: result.exitCode,
      stdout: out,
      stderr: err,
    );
  }
  return result;
}

Future<void> runCommandStream(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  _log.info('exec: $executable ${arguments.join(' ')}');
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: _withToolSearchPath(environment),
    includeParentEnvironment: true,
    runInShell: Platform.isWindows,
  );

  final stdout = _collectProcessOutput(
    process.stdout,
    (line) => _log.info(line),
  );
  final stderr = _collectProcessOutput(
    process.stderr,
    (line) => _log.warning(line),
  );

  final exitCode = await process.exitCode;
  final output = await Future.wait([stdout, stderr]);
  if (exitCode != 0) {
    throw CommandFailedException(
      executable: executable,
      arguments: arguments,
      exitCode: exitCode,
      stdout: output[0],
      stderr: output[1],
    );
  }
}

Future<String> _collectProcessOutput(
  Stream<List<int>> stream,
  void Function(String line) logLine,
) async {
  final output = StringBuffer();
  var pendingLine = '';

  await for (final data in stream.transform(systemEncoding.decoder)) {
    output.write(data);

    final text = pendingLine + data;
    final lines = text.split('\n');
    pendingLine = lines.removeLast();

    for (final line in lines) {
      final normalizedLine = line.endsWith('\r')
          ? line.substring(0, line.length - 1)
          : line;
      if (normalizedLine.isNotEmpty) logLine(normalizedLine);
    }
  }

  final tail = pendingLine.endsWith('\r')
      ? pendingLine.substring(0, pendingLine.length - 1)
      : pendingLine;
  if (tail.isNotEmpty) logLine(tail);

  return output.toString().trim();
}

Future<String> calcSha256(String filePath) async {
  final file = File(filePath);
  if (!await file.exists()) {
    throw BuildException('File not found: $filePath');
  }
  final hash = await sha256.bind(file.openRead()).first;
  return hash.toString();
}

const coreManifestName = 'manifest.json';

void writeCoreManifest({required String path, required String coreSha256}) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(coreSha256)) {
    throw BuildException('Invalid Core SHA256: $coreSha256');
  }

  final manifest = File(path);
  final content = '${jsonEncode({'coreSha256': coreSha256})}\n';
  if (manifest.existsSync() && manifest.readAsStringSync() == content) {
    return;
  }
  ensureDir(manifest.parent.path);
  manifest.writeAsStringSync(content, flush: true);
}

void ensureDir(String dirPath) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
}

void copyFile(String source, String destination) {
  final src = File(source);
  if (!src.existsSync()) {
    throw BuildException('Source file not found: $source');
  }
  final dest = File(destination);
  ensureDir(dest.parent.path);
  final partial = File('$destination.$pid.tmp');
  src.copySync(partial.path);
  _renameOver(partial, dest);
  _log.fine('Copied $source -> $destination');
}

void replaceFile(String source, String destination) {
  final dest = File(destination);
  ensureDir(dest.parent.path);
  _renameOver(File(source), dest);
}

void _renameOver(File from, File to) {
  try {
    from.renameSync(to.path);
  } on FileSystemException {
    // Windows refuses to rename over an existing file.
    if (to.existsSync()) to.deleteSync();
    from.renameSync(to.path);
  }
}
