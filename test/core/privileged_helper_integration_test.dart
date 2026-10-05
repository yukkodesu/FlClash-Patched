import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/core/desktop/core_manifest.dart';
import 'package:fl_clash/core/desktop/helper_client.dart';
import 'package:fl_clash/core/desktop/launcher.dart';
import 'package:fl_clash/core/desktop/lifecycle.dart';
import 'package:fl_clash/core/desktop/process_probe.dart';
import 'package:fl_clash/core/desktop/rpc_client.dart';
import 'package:fl_clash/core/desktop/transport.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_api/rust_api.dart';

class _HelperBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

Future<Map<String, dynamic>> _action(String action) async {
  final result = await Process.run(
    Platform.environment['FLCLASH_MEOW_ACCEPTANCE_PYTHON']!,
    ['tool/privileged_helper_acceptance.py', '--action', action],
  );
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  return jsonDecode(result.stdout as String) as Map<String, dynamic>;
}

Future<void> _record(String phase, DesktopCoreSession? session) async {
  final snapshot = await _action('snapshot');
  final cores = snapshot['cores'] as List;
  expect(
    cores.map((core) => (core as Map)['ProcessId']),
    session == null ? isEmpty : unorderedEquals([session.pid]),
    reason: jsonEncode(snapshot),
  );
  if (session != null) {
    expect(session.owner, CoreProcessOwner.helper);
    final core = cores.single as Map;
    final service = snapshot['service'] as Map;
    if (Platform.isWindows) {
      expect(service['State'], 'Running');
      expect(service['StartName'], 'LocalSystem');
      expect(core['ParentProcessId'], service['ProcessId']);
    } else {
      final uid = await Process.run('id', ['-u']);
      expect(core['realUid'], int.parse((uid.stdout as String).trim()));
      expect(core['effectiveUid'], 0);
      expect(core['cgroup'], contains(service['ControlGroup'] as String));
      expect(service['ControlGroup'], contains('flclash-meow-helper.service'));
    }
  }
  stdout.writeln(
    jsonEncode({'phase': phase, 'session': session?.sessionId, ...snapshot}),
  );
}

Future<void> _waitForExit(int pid) async {
  final elapsed = Stopwatch()..start();
  while (await isProcessAlive(pid)) {
    if (elapsed.elapsed > const Duration(seconds: 12)) {
      fail('Helper-owned Core $pid survived the lifetime transition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> _waitForReady(HelperClient client) async {
  final elapsed = Stopwatch()..start();
  while (await client.readiness(logFailure: false) != HelperReadiness.ready) {
    if (elapsed.elapsed > const Duration(seconds: 20)) {
      fail('The actual Helper service did not become ready');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<void> _rejectExecutableOverride(
  DesktopCoreSession session,
  String address,
) async {
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  if (Platform.isLinux) {
    client.connectionFactory = (uri, proxyHost, proxyPort) =>
        Socket.startConnect(
          InternetAddress(helperSocketPath, type: InternetAddressType.unix),
          0,
        );
  }
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$helperPort/start'),
    );
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'address': address,
        'sessionId': session.sessionId,
        'executable': '/untrusted/core',
      }),
    );
    final response = await request.close();
    expect(response.statusCode, HttpStatus.badRequest);
    await response.drain<void>();
    expect(await isProcessAlive(session.pid), isTrue);
  } finally {
    client.close(force: true);
  }
}

Future<void> _exerciseLocalProxy(CoreController controller) async {
  final home = Directory(await appPath.homeDirPath);
  for (final name in ['Country.mmdb', 'GeoLite2-ASN.mmdb', 'geosite.dat']) {
    await File('${home.path}/$name').writeAsBytes([]);
  }
  final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = origin.listen((request) async {
    request.response.write('helper-owned-proxy');
    await request.response.close();
  });
  final reservation = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = reservation.port;
  await reservation.close();
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3)
    ..findProxy = (_) => 'PROXY 127.0.0.1:$port';
  try {
    await File(await appPath.configFilePath).writeAsString(
      'mixed-port: $port\ndns:\n  enable: false\nrules:\n  - MATCH,DIRECT\n',
    );
    final url = 'http://127.0.0.1:${origin.port}/';
    expect(
      await controller.setupConfig(
        params: SetupParams(selectedMap: const {}, testUrl: url),
      ),
      isEmpty,
    );
    expect(await controller.startListener(), isTrue);
    expect((await controller.getRuntimeState()).tunActive, isFalse);
    final response = await (await client.getUrl(Uri.parse(url))).close();
    expect(await utf8.decoder.bind(response).join(), 'helper-owned-proxy');
  } finally {
    client.close(force: true);
    await requests.cancel();
    await origin.close(force: true);
  }
}

void main() {
  _HelperBinding();
  final enabled =
      Platform.environment['FLCLASH_MEOW_PRIVILEGED_ACCEPTANCE'] == '1';
  test(
    'actual Helper owns one Core across sessions, IPC loss, service stop and crash',
    () async {
      expect(Platform.environment['RUNNER_ENVIRONMENT'], 'github-hosted');
      expect(Platform.environment['GITHUB_ACTIONS'], 'true');
      expect(Platform.isWindows || Platform.isLinux, isTrue);
      final helperPath = Platform.environment['FLCLASH_MEOW_HELPER']!;
      final manifestPath =
          Platform.environment['FLCLASH_MEOW_HELPER_MANIFEST']!;
      final coreSha256 = await CoreManifest.readCoreSha256(path: manifestPath);
      expect(coreSha256, isNotNull);
      final helper = HelperClient(
        expectedHelperPath: () => helperPath,
        readCoreSha256: () async => coreSha256!,
      );
      await _waitForReady(helper);
      final mismatched = HelperClient(
        expectedHelperPath: () => helperPath,
        readCoreSha256: () async => List.filled(64, '0').join(),
      );
      expect(
        await mismatched.readiness(logFailure: false),
        HelperReadiness.notReady,
      );
      if (Platform.isLinux) {
        expect(
          (await _action('foreign-peer'))['foreignPeer'],
          contains('rejected'),
        );
      }
      final home = await Directory.systemTemp.createTemp(
        'flclash-meow-helper-',
      );
      final support = AppPath.supportDirectory;
      final temporary = AppPath.temporaryDirectory;
      final cache = AppPath.cacheDirectory;
      AppPath.supportDirectory = () async => home;
      AppPath.temporaryDirectory = () async => home;
      AppPath.cacheDirectory = () async => home;
      await RustLib.init();
      late final CoreRpcClient rpc;
      final lifecycle = DesktopCoreLifecycle(
        transportFactory: () => IPCCoreTransport(
          address: Platform.isWindows ? windowsPipeName : unixSocketPath,
        ),
        launcherResolver: HelperLauncherResolver(
          hasHelper: true,
          helperReady: helper.readiness,
          helperLauncher: HelperLauncher(helper),
          directLauncher: DirectCoreLauncher(
            corePath: Platform.environment['FLCLASH_MEOW_ACCEPTANCE_CORE']!,
          ),
        ),
        verifyPeerPid: Platform.isWindows,
        shutdownSession: (session, timeout) =>
            rpc.shutdownSession(session, timeout),
      );
      rpc = CoreRpcClient(lifecycle.transport);
      final controller = CoreController.scoped(
        CoreService.forTesting(lifecycle: lifecycle, rpcClient: rpc),
      );
      try {
        final first = (await controller.start()).session!;
        await _record('helper-connected', first);
        if (Platform.isWindows) {
          final peer = await lifecycle.transport.waitUntilConnected(
            const Duration(seconds: 3),
          );
          expect(peer.pid, first.pid);
          stdout.writeln(
            jsonEncode({'phase': 'named-pipe-peer', 'pid': peer.pid}),
          );
        }
        expect((await controller.getCoreInfo()).name, 'meow-rs');
        expect(await controller.init(1), isTrue);
        await _exerciseLocalProxy(controller);
        await _rejectExecutableOverride(first, lifecycle.transport.address);
        final wrongSession = first.sessionId == List.filled(32, 'f').join()
            ? List.filled(32, '0').join()
            : List.filled(32, 'f').join();
        await expectLater(
          helper.stop(wrongSession),
          throwsA(
            isA<HelperException>().having(
              (error) => error.code,
              'code',
              'sessionMismatch',
            ),
          ),
        );
        expect(await isProcessAlive(first.pid), isTrue);
        expect((await controller.getRuntimeState()).initialized, isTrue);

        final next = (await controller.restart()).session!;
        await _waitForExit(first.pid);
        expect(next.sessionId, isNot(first.sessionId));
        await _record('after-restart', next);
        await controller.stop();
        await _waitForExit(next.pid);
        await _record('after-stop', null);

        await _action('corrupt-core');
        try {
          await expectLater(
            helper.start(
              address: lifecycle.transport.address,
              sessionId: wrongSession,
            ),
            throwsA(
              isA<HelperException>().having(
                (error) => error.code,
                'code',
                'coreVerificationFailed',
              ),
            ),
          );
          await _record('after-core-hash-rejection', null);
        } finally {
          expect((await _action('restore-core'))['coreSha256'], coreSha256);
        }

        final ipcSession = (await controller.start()).session!;
        final ipcFailure = lifecycle.crashEvents.first;
        await stopIpcServer();
        expect(
          (await ipcFailure.timeout(const Duration(seconds: 15))).pid,
          ipcSession.pid,
        );
        await _waitForExit(ipcSession.pid);
        await controller.stop();
        await _record('after-client-ipc-loss', null);

        final stopped = (await controller.start()).session!;
        final stopFailure = lifecycle.crashEvents.first;
        await _action('stop');
        expect(
          (await stopFailure.timeout(const Duration(seconds: 15))).pid,
          stopped.pid,
        );
        await _waitForExit(stopped.pid);
        await controller.stop();
        await _record('after-service-stop', null);

        await _action('start');
        await _waitForReady(helper);
        final crashed = (await controller.start()).session!;
        expect(await controller.init(1), isTrue);
        await _exerciseLocalProxy(controller);
        await _record('before-helper-crash', crashed);
        final crashFailure = lifecycle.crashEvents.first;
        await _action('crash');
        expect(
          (await crashFailure.timeout(const Duration(seconds: 15))).pid,
          crashed.pid,
        );
        await _waitForExit(crashed.pid);
        await controller.stop();
        await _record('after-helper-crash', null);
        await _waitForReady(helper);
        final recovered = (await controller.start()).session!;
        await _record('after-helper-recovery', recovered);
        await controller.close();
        await _waitForExit(recovered.pid);
        await _record('after-terminal-close', null);
      } finally {
        await controller.close();
        await rpc.close();
        RustLib.dispose();
        AppPath.supportDirectory = support;
        AppPath.temporaryDirectory = temporary;
        AppPath.cacheDirectory = cache;
        await home.delete(recursive: true);
      }
    },
    skip: !enabled
        ? 'Actual service lifetime acceptance runs only on opted-in disposable native CI.'
        : false,
    timeout: const Timeout(Duration(minutes: 7)),
  );
}
