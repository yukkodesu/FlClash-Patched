import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

const proxyHost = '127.0.0.1';

typedef ProxyProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      bool runInShell,
    });

typedef ProxyExecutableChecker = Future<bool> Function(String executable);

class ProxyCommand {
  final String executable;
  final List<String> args;
  final bool runInShell;

  ProxyCommand(this.executable, List<String> args, {this.runInShell = false})
    : args = List.unmodifiable(args);
}

class ProxyCommandRunner {
  final ProxyProcessRunner? _processRunner;
  final Duration commandTimeout;
  final _children = <Process>{};

  ProxyCommandRunner(
    this._processRunner, {
    this.commandTimeout = const Duration(seconds: 20),
  });

  Future<ProcessResult> process(
    String executable,
    List<String> arguments, {
    bool runInShell = false,
  }) {
    final runner = _processRunner;
    if (runner != null) {
      return runner(executable, arguments, runInShell: runInShell);
    }
    return _boundedProcess(executable, arguments, runInShell);
  }

  Future<bool> releaseProcesses() async {
    var released = true;
    for (final process in _children.toList()) {
      process.kill(ProcessSignal.sigkill);
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
        _children.remove(process);
      } on TimeoutException {
        released = false;
      }
    }
    return released;
  }

  Future<ProcessResult> _boundedProcess(
    String executable,
    List<String> arguments,
    bool runInShell,
  ) async {
    final child = await Process.start(
      executable,
      arguments,
      runInShell: runInShell,
    );
    _children.add(child);
    var overflow = false;
    Future<String> collect(Stream<List<int>> stream) async {
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        if (bytes.length + chunk.length > 1024 * 1024) {
          overflow = true;
          child.kill(ProcessSignal.sigkill);
        } else {
          bytes.add(chunk);
        }
      }
      return utf8.decode(bytes.takeBytes(), allowMalformed: true);
    }

    final output = Future.wait([collect(child.stdout), collect(child.stderr)]);
    unawaited(output.then<void>((_) {}).catchError((Object _) {}));
    var timedOut = false;
    try {
      int code;
      try {
        code = await child.exitCode.timeout(commandTimeout);
      } on TimeoutException {
        timedOut = true;
        child.kill(ProcessSignal.sigkill);
        code = await child.exitCode.timeout(const Duration(seconds: 2));
      }
      final streams = await output.timeout(const Duration(seconds: 2));
      _children.remove(child);
      return ProcessResult(
        child.pid,
        timedOut || overflow ? -1 : code,
        streams[0],
        streams[1],
      );
    } on TimeoutException {
      throw ProcessException(
        executable,
        arguments,
        'Proxy command termination could not be confirmed',
      );
    } on Object {
      child.kill(ProcessSignal.sigkill);
      rethrow;
    }
  }

  Future<bool> run(Iterable<ProxyCommand> commands) async {
    var executed = false;
    try {
      for (final command in commands) {
        executed = true;
        final result = await process(
          command.executable,
          command.args,
          runInShell: command.runInShell,
        );
        if (result.exitCode != 0) {
          return false;
        }
      }
    } on ProcessException {
      return false;
    }
    return executed;
  }
}
