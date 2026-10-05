import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/core/desktop/launcher.dart';
import 'package:fl_clash/core/desktop/lifecycle.dart';
import 'package:fl_clash/core/desktop/rpc_client.dart';
import 'package:fl_clash/core/desktop/transport.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_api/rust_api.dart';

class _DirectHost implements DesktopCoreLauncherResolver {
  final DirectCoreLauncher launcher;

  _DirectHost(String executable)
    : launcher = DirectCoreLauncher(corePath: executable);

  @override
  Future<CoreProcessLauncher> resolve() async => launcher;
}

class _HostBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  final executable = Platform.environment['FLCLASH_MEOW_HOST'];
  _HostBinding();

  test(
    'CoreController controls a real host and transfers local proxy traffic',
    () async {
      expect(File(executable!).existsSync(), isTrue);
      final home = await Directory.systemTemp.createTemp('flclash-meow-e2e-');
      final originalSupportDirectory = AppPath.supportDirectory;
      final originalTemporaryDirectory = AppPath.temporaryDirectory;
      final originalCacheDirectory = AppPath.cacheDirectory;
      AppPath.supportDirectory = () async => home;
      AppPath.temporaryDirectory = () async => home;
      AppPath.cacheDirectory = () async => home;
      await RustLib.init();

      final lifecycle = DesktopCoreLifecycle(
        transportFactory: () => IPCCoreTransport(
          address: system.isWindows ? windowsPipeName : unixSocketPath,
        ),
        launcherResolver: _DirectHost(executable),
        verifyPeerPid: system.isWindows,
      );
      final controller = CoreController.scoped(
        CoreService.forTesting(
          lifecycle: lifecycle,
          rpcClient: CoreRpcClient(lifecycle.transport),
        ),
      );
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = origin.listen((request) async {
        request.response.write('meow-through-core');
        await request.response.close();
      });
      final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final peers = <Socket>[];
      final echoRequests = echo.listen((socket) {
        peers.add(socket);
        socket.listen(socket.add, onError: (_) => socket.destroy());
      });
      Socket? tunnel;
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final proxyPort = reservation.port;
      await reservation.close();
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3)
        ..findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
      try {
        await controller.start();
        final info = await controller.getCoreInfo();
        expect(info.name, 'meow-rs');
        expect(info.statisticsScope, 'all');
        expect(await controller.init(1), isTrue);
        final idle = await controller.getRuntimeState();
        expect(idle.initialized, isTrue);
        expect(idle.configured, isFalse);
        expect(idle.running, isFalse);

        final rejected = await controller.checkConfig(
          'proxies:\n  - name: unsupported\n    type: tuic\n',
        );
        expect(rejected.valid, isFalse);
        expect(rejected.diagnostics, isNotEmpty);
        expect((await controller.getRuntimeState()).configured, isFalse);

        final yaml =
            '''
strict: true
mixed-port: $proxyPort
mode: rule
dns:
  enable: false
proxy-groups:
  - name: local
    type: select
    proxies: [DIRECT, REJECT]
rules:
  - MATCH,local
''';
        final checked = await controller.checkConfig(yaml);
        expect(checked.valid, isTrue, reason: checked.diagnostics.toString());
        await File(await appPath.configFilePath).writeAsString(yaml);
        final profile = File(await appPath.getProfilePath('17'));
        await profile.parent.create(recursive: true);
        await profile.writeAsString(yaml);
        expect((await controller.getConfig(17))['rules'], ['MATCH,local']);
        final url = 'http://127.0.0.1:${origin.port}/';
        expect(
          await controller.setupConfig(
            params: SetupParams(selectedMap: {'local': 'DIRECT'}, testUrl: url),
          ),
          isEmpty,
        );
        expect((await controller.getRuntimeState()).running, isFalse);
        final groups = await controller.getProxiesGroups(
          sortType: ProxiesSortType.none,
          delayMap: const {},
          selectedMap: const {'local': 'DIRECT'},
          defaultTestUrl: url,
        );
        expect(groups.map((group) => group.name), contains('local'));
        expect(await controller.startListener(), isTrue);
        final running = await controller.getRuntimeState();
        expect(running.running, isTrue);
        expect(running.tunActive, isFalse);

        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);
        expect(
          await response.transform(utf8.decoder).join(),
          'meow-through-core',
        );
        final totals = await controller.getTotalTraffic(false);
        expect(totals.down, greaterThan(0));
        final delay = await controller.getDelay(url, 'DIRECT');
        expect(delay, isNotNull);
        expect(delay!.value, greaterThanOrEqualTo(0));

        tunnel = await Socket.connect('127.0.0.1', proxyPort);
        final established = Completer<void>();
        final echoed = Completer<void>();
        final closed = Completer<void>();
        var received = '';
        tunnel.listen(
          (bytes) {
            received += utf8.decode(bytes);
            if (received.contains('\r\n\r\n') && !established.isCompleted) {
              established.complete();
            }
            if (received.contains('held-connection') && !echoed.isCompleted) {
              echoed.complete();
            }
          },
          onDone: () => closed.complete(),
          onError: (Object error) {
            if (!closed.isCompleted) closed.completeError(error);
          },
        );
        tunnel.write(
          'CONNECT 127.0.0.1:${echo.port} HTTP/1.1\r\n'
          'Host: 127.0.0.1:${echo.port}\r\n\r\n',
        );
        await established.future.timeout(const Duration(seconds: 5));
        expect(received, startsWith('HTTP/1.1 200'));
        tunnel.write('held-connection');
        await echoed.future.timeout(const Duration(seconds: 5));
        final connections = await controller.getConnections();
        final held = connections.singleWhere(
          (connection) =>
              connection.metadata.destinationPort == echo.port.toString(),
        );
        expect(held.metadata.sourcePort, isNotEmpty);
        await controller.closeConnection(held.id);
        await closed.future.timeout(const Duration(seconds: 5));
        expect(
          (await controller.getConnections()).map(
            (connection) => connection.id,
          ),
          isNot(contains(held.id)),
        );
        expect(await controller.stopListener(), isTrue);
        final stopped = await controller.getRuntimeState();
        expect(stopped.running, isFalse);
        expect(stopped.configured, isTrue);
        await expectLater(
          Socket.connect('127.0.0.1', proxyPort),
          throwsA(isA<SocketException>()),
        );
      } finally {
        client.close(force: true);
        tunnel?.destroy();
        await controller.close();
        for (final peer in peers) {
          peer.destroy();
        }
        await echoRequests.cancel();
        await echo.close();
        await requests.cancel();
        await origin.close(force: true);
        RustLib.dispose();
        AppPath.supportDirectory = originalSupportDirectory;
        AppPath.temporaryDirectory = originalTemporaryDirectory;
        AppPath.cacheDirectory = originalCacheDirectory;
        await home.delete(recursive: true);
      }
    },
    skip: executable == null
        ? 'Requires a real host and native rust_api artifact; run desktop e2e.'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
