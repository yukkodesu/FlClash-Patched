import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory repo;
  final source = Directory.current;
  final bash = Platform.isWindows
      ? 'C:/Program Files/Git/bin/bash.exe'
      : 'bash';

  ProcessResult git(List<String> arguments) {
    final result = Process.runSync(
      'git',
      arguments,
      workingDirectory: repo.path,
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    return result;
  }

  ProcessResult release(List<String> arguments) => Process.runSync(bash, [
    'tool/release.sh',
    ...arguments,
  ], workingDirectory: repo.path);

  setUp(() {
    repo = Directory.systemTemp.createTempSync('flclash-release-');
    Directory('${repo.path}/tool').createSync();
    for (final name in ['release.sh', 'bump_version.sh']) {
      File('${repo.path}/tool/$name').writeAsStringSync(
        File(
          '${source.path}/tool/$name',
        ).readAsStringSync().replaceAll('\r\n', '\n'),
      );
    }
    File('${repo.path}/pubspec.yaml').writeAsStringSync('version: 0.9.2+1\n');
    File(
      '${repo.path}/build_config.yaml',
    ).writeAsStringSync('release_channel: pre\ncore_dir: core/meow-rs\n');
    git(['init', '--quiet', '--initial-branch=main']);
    git(['config', 'user.email', 'release-test@example.com']);
    git(['config', 'user.name', 'Release test']);
    git(['add', '.']);
    git(['commit', '--quiet', '--message', 'feat: initial fork']);
    git(['clone', '--quiet', '--bare', '.', 'fork.git']);
    git(['remote', 'add', 'my', '${repo.path}/fork.git']);
    File('${repo.path}/.git/info/exclude').writeAsStringSync('fork.git/\n');
  });

  tearDown(() => repo.deleteSync(recursive: true));

  test('first preview dry run preserves files, HEAD and tags', () {
    git(['tag', 'v0.9.2']);
    final head = git(['rev-parse', 'HEAD']).stdout;
    final tags = git(['tag']).stdout;
    final result = release(['pre', '--dry-run']);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('v0.9.2+1'));
    expect(git(['status', '--porcelain']).stdout, isEmpty);
    expect(git(['rev-parse', 'HEAD']).stdout, head);
    expect(git(['tag']).stdout, tags);
    expect(
      File('${repo.path}/pubspec.yaml').readAsStringSync(),
      'version: 0.9.2+1\n',
    );
  });

  test(
    'next revision follows own fork tags and ignores local upstream tags',
    () {
      git([
        'tag',
        '--annotate',
        'v0.9.2+3',
        '--message',
        'Third fork revision',
      ]);
      git(['push', '--quiet', 'my', 'v0.9.2+3']);
      git(['tag', 'v0.9.2+2026100523']);

      final result = release(['pre', '--yes']);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(
        git(['show', 'v0.9.2+4:pubspec.yaml']).stdout,
        'version: 0.9.2+4\n',
      );
      expect(git(['status', '--porcelain']).stdout, isEmpty);
      expect(git(['ls-remote', '--tags', 'my', '*+4']).stdout, isEmpty);
    },
  );

  test(
    'stable uses the same tag format and commits the channel before tagging',
    () {
      final result = release(['stable', '--yes']);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('prerelease: false'));
      expect(
        git(['show', 'v0.9.2+1:pubspec.yaml']).stdout,
        'version: 0.9.2+1\n',
      );
      expect(
        git(['show', 'v0.9.2+1:build_config.yaml']).stdout,
        'release_channel: stable\ncore_dir: core/meow-rs\n',
      );
      expect(git(['status', '--porcelain']).stdout, isEmpty);
    },
  );

  test(
    'an existing local fork tag advances the revision without changing base',
    () {
      git(['tag', 'v0.9.2+1']);
      final result = release(['pre', '--dry-run']);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('v0.9.2+2'));
      expect(git(['tag', '--list', 'v0.9.2+2']).stdout, isEmpty);
    },
  );

  test('push to an unverified remote fails before changing files or tags', () {
    final result = release(['pre', '--yes', '--push']);

    expect(result.exitCode, isNonZero);
    expect(
      result.stderr,
      contains('must push only to yukkodesu/FlClash-Patched'),
    );
    expect(git(['status', '--porcelain']).stdout, isEmpty);
    expect(git(['tag']).stdout, isEmpty);
  });

  test('explicit versions cannot change base or introduce extra metadata', () {
    for (final version in ['0.9.3+1', '0.9.2+1+2', '0.9.2+0']) {
      final result = release(['pre', '--version', version, '--yes']);

      expect(result.exitCode, isNonZero, reason: version);
      expect(git(['status', '--porcelain']).stdout, isEmpty);
      expect(git(['tag']).stdout, isEmpty);
    }
  });

  test('bump command increments only the fork revision', () {
    final result = Process.runSync(bash, [
      'tool/bump_version.sh',
    ], workingDirectory: repo.path);

    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(
      File('${repo.path}/pubspec.yaml').readAsStringSync(),
      'version: 0.9.2+2\n',
    );
  });

  test('legacy date counters require explicit migration', () {
    File(
      '${repo.path}/pubspec.yaml',
    ).writeAsStringSync('version: 0.9.2+2026100523\n');
    git(['add', 'pubspec.yaml']);
    git(['commit', '--quiet', '--message', 'chore: upstream build counter']);

    for (final script in ['release.sh', 'bump_version.sh']) {
      final result = Process.runSync(bash, [
        'tool/$script',
        if (script == 'release.sh') ...['pre', '--dry-run'],
      ], workingDirectory: repo.path);
      expect(result.exitCode, isNonZero);
      expect(result.stderr.toString().toLowerCase(), contains('legacy date'));
      expect(git(['status', '--porcelain']).stdout, isEmpty);
    }
  });
}
