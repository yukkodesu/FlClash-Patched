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

Future<void> _withRealHost(
  String executable,
  Future<void> Function(CoreController controller) exercise,
) async {
  final home = await Directory.systemTemp.createTemp('flclash-meow-groups-');
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
      address: system.isWindows ? windowsPipeName : unixSocketPath,
    ),
    launcherResolver: _DirectHost(executable),
    verifyPeerPid: system.isWindows,
    shutdownSession: (session, timeout) =>
        rpc.shutdownSession(session, timeout),
  );
  rpc = CoreRpcClient(lifecycle.transport);
  final controller = CoreController.scoped(
    CoreService.forTesting(lifecycle: lifecycle, rpcClient: rpc),
  );
  try {
    await controller.start();
    final data = Directory(await appPath.homeDirPath);
    await data.create(recursive: true);
    for (final name in ['Country.mmdb', 'GeoLite2-ASN.mmdb', 'geosite.dat']) {
      await File('${data.path}/$name').writeAsBytes([]);
    }
    expect(await controller.init(1), isTrue);
    await exercise(controller);
  } finally {
    expect((await controller.close()).outcome, CoreLifecycleOutcome.applied);
    RustLib.dispose();
    AppPath.supportDirectory = support;
    AppPath.temporaryDirectory = temporary;
    AppPath.cacheDirectory = cache;
    await home.delete(recursive: true);
  }
}

Future<List<Group>> _groups(CoreController controller, String testUrl) {
  return controller.getProxiesGroups(
    sortType: ProxiesSortType.none,
    delayMap: const {},
    selectedMap: const {},
    defaultTestUrl: testUrl,
  );
}

void main() {
  final executable = Platform.environment['FLCLASH_MEOW_HOST'];
  _HostBinding();

  test(
    'CoreController restores group selections and releases automatic fixation',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = origin.listen((request) async {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${origin.port}/';
      try {
        await _withRealHost(executable!, (controller) async {
          await File(await appPath.configFilePath).writeAsString('''
proxy-groups:
  - name: route
    type: select
    proxies: [DIRECT, REJECT]
  - name: automatic
    type: url-test
    proxies: [DIRECT, REJECT]
    url: $url
    interval: 3600
rules: ['MATCH,route']
''');
          expect(
            await controller.setupConfig(
              params: SetupParams(
                selectedMap: const {'route': 'REJECT', 'automatic': 'REJECT'},
                testUrl: url,
              ),
            ),
            isEmpty,
          );
          var groups = await _groups(controller, url);
          expect(groups.getGroup('route')!.now, 'REJECT');
          expect(groups.getGroup('automatic')!.now, 'REJECT');
          await expectLater(
            controller.changeProxy(
              const ChangeProxyParams(groupName: 'route', proxyName: 'missing'),
            ),
            throwsA(isA<CoreMethodException>()),
          );
          expect(
            (await _groups(controller, url)).getGroup('route')!.now,
            'REJECT',
          );
          expect(
            await controller.changeProxy(
              const ChangeProxyParams(groupName: 'route', proxyName: 'DIRECT'),
            ),
            isEmpty,
          );
          expect(
            (await _groups(controller, url)).getGroup('route')!.now,
            'DIRECT',
          );
          expect(
            await controller.changeProxy(
              const ChangeProxyParams(groupName: 'automatic', proxyName: ''),
              closeConnections: true,
            ),
            isEmpty,
          );
          groups = await _groups(controller, url);
          expect(groups.getGroup('automatic')!.now, 'DIRECT');
        });
      } finally {
        await requests.cancel();
        await origin.close(force: true);
      }
    },
    skip: executable == null ? 'Requires the real desktop host.' : false,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'CoreController refreshes providers and cancels stale updates across sessions',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var names = ['first', 'second'];
      var fail = false;
      Completer<void>? release;
      final pendingRequest = Completer<void>();
      final lateResponse = Completer<void>();
      final requests = origin.listen((request) async {
        final held = request.uri.path == '/nodes' ? release : null;
        try {
          if (request.uri.path == '/nodes') {
            if (held != null) {
              if (!pendingRequest.isCompleted) pendingRequest.complete();
              await held.future;
            }
            request.response.statusCode = fail
                ? HttpStatus.serviceUnavailable
                : HttpStatus.ok;
            request.response.write(
              'proxies:\n${names.map((name) => '  - name: $name\n    type: http\n    server: 127.0.0.1\n    port: ${origin.port}\n').join()}',
            );
          } else {
            request.response.statusCode = HttpStatus.noContent;
          }
          await request.response.close();
        } on IOException catch (_) {
          if (held == null) {
            rethrow;
          }
        } finally {
          if (held != null && !lateResponse.isCompleted) {
            lateResponse.complete();
          }
        }
      });
      final url = 'http://127.0.0.1:${origin.port}/';
      String configuration(String vehicle) =>
          '''
strict: true
proxy-providers:
  local:
    type: $vehicle
    ${vehicle == 'http' ? 'url: ${url}nodes\n    interval: 3600\n    ' : ''}path: providers/local.yaml
proxy-groups:
  - name: route
    type: select
    use: [local]
rules: ['MATCH,route']
''';
      try {
        await _withRealHost(executable!, (controller) async {
          await File(
            await appPath.configFilePath,
          ).writeAsString(configuration('http'));
          expect(
            await controller.setupConfig(
              params: SetupParams(
                selectedMap: const {'route': 'second'},
                testUrl: url,
              ),
            ),
            isEmpty,
          );
          final provider = await controller.getExternalProvider('local');
          expect(provider!.count, 2);
          expect(provider.vehicleType, 'HTTP');
          expect(provider.updateAt, isNotNull);
          expect(
            (await controller.getExternalProviders()).map((item) => item.name),
            ['local'],
          );
          expect(
            (await _groups(controller, url)).getGroup('route')!.now,
            'second',
          );
          fail = true;
          await expectLater(
            controller.updateExternalProvider(providerName: 'local'),
            throwsA(isA<CoreMethodException>()),
          );
          expect((await controller.getExternalProvider('local'))!.count, 2);
          expect(
            (await _groups(
              controller,
              url,
            )).getGroup('route')!.all.map((proxy) => proxy.name),
            ['first', 'second'],
          );
          fail = false;
          names = ['third'];
          expect(
            await controller.updateExternalProvider(providerName: 'local'),
            isEmpty,
          );
          expect((await controller.getExternalProvider('local'))!.count, 1);
          expect(
            (await _groups(
              controller,
              url,
            )).getGroup('route')!.all.map((proxy) => proxy.name),
            ['third'],
          );
          expect(
            await controller.changeProxy(
              const ChangeProxyParams(groupName: 'route', proxyName: 'third'),
            ),
            isEmpty,
          );
          expect(await controller.startListener(), isTrue);
          release = Completer<void>();
          names = ['late'];
          final pending = controller.updateExternalProvider(
            providerName: 'local',
          );
          final cancelled = expectLater(
            pending,
            throwsA(
              isA<CoreMethodException>().having(
                (error) => error.code,
                'code',
                'request_cancelled',
              ),
            ),
          );
          await pendingRequest.future.timeout(const Duration(seconds: 3));
          expect(await controller.stopListener(), isTrue);
          await cancelled;
          release!.complete();
          await lateResponse.future.timeout(const Duration(seconds: 3));
          expect(
            (await _groups(
              controller,
              url,
            )).getGroup('route')!.all.map((proxy) => proxy.name),
            ['third'],
          );
          expect(
            (await controller.restart()).outcome,
            CoreLifecycleOutcome.applied,
          );
          expect(await controller.init(1), isTrue);
          await File(
            await appPath.configFilePath,
          ).writeAsString(configuration('file'));
          expect(
            await controller.setupConfig(
              params: SetupParams(selectedMap: const {}, testUrl: url),
            ),
            isEmpty,
          );
          expect(
            (await _groups(
              controller,
              url,
            )).getGroup('route')!.all.map((proxy) => proxy.name),
            ['third'],
          );
        });
      } finally {
        if (release != null && !release!.isCompleted) release!.complete();
        await requests.cancel();
        await origin.close(force: true);
      }
    },
    skip: executable == null ? 'Requires the real desktop host.' : false,
    timeout: const Timeout(Duration(seconds: 30)),
  );

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

      late final CoreRpcClient rpcClient;
      final lifecycle = DesktopCoreLifecycle(
        transportFactory: () => IPCCoreTransport(
          address: system.isWindows ? windowsPipeName : unixSocketPath,
        ),
        launcherResolver: _DirectHost(executable),
        verifyPeerPid: system.isWindows,
        shutdownSession: (session, timeout) =>
            rpcClient.shutdownSession(session, timeout),
      );
      rpcClient = CoreRpcClient(lifecycle.transport);
      final controller = CoreController.scoped(
        CoreService.forTesting(lifecycle: lifecycle, rpcClient: rpcClient),
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
      Socket? socks;
      StreamIterator<List<int>>? socksResponses;
      final proxyHost = (await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )).expand((interface) => interface.addresses).first.address;
      final reservation = await ServerSocket.bind(
        InternetAddress(proxyHost),
        0,
      );
      final proxyPort = reservation.port;
      await reservation.close();
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3)
        ..findProxy = (_) => 'PROXY $proxyHost:$proxyPort';
      try {
        await controller.start();
        final info = await controller.getCoreInfo();
        expect(info.name, 'meow-rs');
        expect(info.statisticsScope, 'all');
        final expectedCommit = Platform.environment['MEOW_HOST_COMMIT'];
        if (expectedCommit != null) expect(info.commit, expectedCommit);
        final dataHome = Directory(await appPath.homeDirPath);
        await dataHome.create(recursive: true);
        for (final name in [
          'Country.mmdb',
          'GeoLite2-ASN.mmdb',
          'geosite.dat',
        ]) {
          await File('${dataHome.path}/$name').writeAsBytes([]);
        }
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
allow-lan: true
bind-address: $proxyHost
authentication: [fixture:local-only]
mode: rule
hosts:
  test.example: 127.0.0.42
dns:
  enable: true
  listen: 127.0.0.1:0
proxy-groups:
  - name: local
    type: select
    proxies: [DIRECT, REJECT]
rules:
  - MATCH,local
''';
        final checked = await controller.checkConfig(yaml);
        expect(checked.valid, isTrue, reason: checked.diagnostics.toString());
        expect(
          checked.diagnostics.any(
            (item) =>
                item.severity == 'warning' && item.path == 'authentication',
          ),
          isTrue,
        );
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
        expect(running.listeners.single.address, '$proxyHost:$proxyPort');
        final dnsAddress = running.dnsListen!.split(':');
        final dnsSocket = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        try {
          final answer = Completer<Datagram>();
          final subscription = dnsSocket.listen((event) {
            if (event != RawSocketEvent.read) return;
            final packet = dnsSocket.receive();
            if (packet != null && !answer.isCompleted) answer.complete(packet);
          });
          try {
            dnsSocket.send(
              [
                0xbe,
                0xef,
                1,
                0,
                0,
                1,
                0,
                0,
                0,
                0,
                0,
                0,
                4,
                ...ascii.encode('test'),
                7,
                ...ascii.encode('example'),
                0,
                0,
                1,
                0,
                1,
              ],
              InternetAddress(dnsAddress.first),
              int.parse(dnsAddress.last),
            );
            final response = (await answer.future.timeout(
              const Duration(seconds: 3),
            )).data;
            expect(response.take(2), [0xbe, 0xef]);
            expect(response[3] & 0x0f, 0);
            expect(response.sublist(response.length - 4), [127, 0, 0, 42]);
          } finally {
            await subscription.cancel();
          }
        } finally {
          dnsSocket.close();
        }

        final unauthorized = await (await client.getUrl(
          Uri.parse(url),
        )).close();
        expect(unauthorized.statusCode, HttpStatus.proxyAuthenticationRequired);
        await unauthorized.drain<void>();
        final proxyAuthorization =
            'Basic ${base64.encode(utf8.encode('fixture:local-only'))}';
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set(
          HttpHeaders.proxyAuthorizationHeader,
          proxyAuthorization,
        );
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

        tunnel = await Socket.connect(proxyHost, proxyPort);
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
          onDone: () {
            if (!closed.isCompleted) closed.complete();
          },
          onError: (Object error) {
            if (!closed.isCompleted) closed.completeError(error);
          },
        );
        tunnel.write(
          'CONNECT 127.0.0.1:${echo.port} HTTP/1.1\r\n'
          'Proxy-Authorization: $proxyAuthorization\r\n'
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
        final unauthorizedSocks = await Socket.connect(proxyHost, proxyPort);
        try {
          final method = unauthorizedSocks
              .expand((bytes) => bytes)
              .take(2)
              .toList()
              .timeout(const Duration(seconds: 3));
          unauthorizedSocks.add([5, 1, 0]);
          expect(await method, [5, 255]);
        } finally {
          unauthorizedSocks.destroy();
        }
        socks = await Socket.connect(proxyHost, proxyPort);
        final responses = StreamIterator<List<int>>(socks);
        socksResponses = responses;
        final pending = <int>[];
        Future<List<int>> readSocks(int length) async {
          while (pending.length < length) {
            expect(
              await responses.moveNext().timeout(const Duration(seconds: 3)),
              isTrue,
            );
            pending.addAll(responses.current);
          }
          final bytes = pending.take(length).toList();
          pending.removeRange(0, length);
          return bytes;
        }

        socks.add([5, 1, 2]);
        expect(await readSocks(2), [5, 2]);
        socks.add([
          1,
          7,
          ...ascii.encode('fixture'),
          10,
          ...ascii.encode('local-only'),
        ]);
        expect(await readSocks(2), [1, 0]);
        socks.add([5, 1, 0, 1, 127, 0, 0, 1, echo.port >> 8, echo.port & 255]);
        final socksReply = await readSocks(4);
        expect(socksReply.take(3), [5, 0, 0]);
        expect(socksReply[3], anyOf(1, 4));
        await readSocks(socksReply[3] == 1 ? 6 : 18);
        socks.add(ascii.encode('meow'));
        expect(ascii.decode(await readSocks(4)), 'meow');
        expect(await controller.stopListener(), isTrue);
        final stopped = await controller.getRuntimeState();
        expect(stopped.running, isFalse);
        expect(stopped.configured, isTrue);
        await expectLater(
          Socket.connect(proxyHost, proxyPort),
          throwsA(isA<SocketException>()),
        );
        expect(
          (await controller.restart()).outcome,
          CoreLifecycleOutcome.applied,
        );
        final restarted = await controller.getRuntimeState();
        expect(restarted.initialized, isFalse);
        expect(restarted.configured, isFalse);
        expect(restarted.running, isFalse);
      } finally {
        client.close(force: true);
        tunnel?.destroy();
        socks?.destroy();
        await socksResponses?.cancel();
        expect(
          (await controller.close()).outcome,
          CoreLifecycleOutcome.applied,
        );
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
