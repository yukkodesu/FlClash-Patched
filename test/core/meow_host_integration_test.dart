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
import 'package:fl_clash/manager/core_manager.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_api/rust_api.dart';

import '../helpers/test_profiles.dart';

class _ProviderLoadedEvents with CoreEventListener {
  final names = <String>[];

  @override
  void onLoaded(String name) => names.add(name);
}

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
    'CoreController validates fresh remote resources before applying their payloads',
    () async {
      var unsafe = false;
      String? pluginOptions;
      final domain = [8, 2, 18, 11, ...utf8.encode('example.com')];
      final site = [
        10,
        5,
        ...utf8.encode('local'),
        18,
        domain.length,
        ...domain,
      ];
      final geosite = [10, site.length, ...site];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = server.listen((request) async {
        if (request.uri.path == '/sites') {
          request.response.add(geosite);
          await request.response.close();
          return;
        }
        final nodes = pluginOptions != null
            ? 'proxies: [{name: edge, type: ss, server: localhost, port: 443, cipher: aes-128-gcm, password: fixture, plugin: v2ray-plugin, plugin-opts: $pluginOptions}]\n'
            : "proxies: [{name: edge, type: http, server: localhost, port: 80${unsafe ? ", tls: 'true'" : ''}}]\n";
        request.response.write(
          request.uri.path == '/rules' ? "payload: ['example.com']\n" : nodes,
        );
        await request.response.close();
      });
      try {
        await _withRealHost(executable!, (controller) async {
          final address = 'http://127.0.0.1:${server.port}';
          final yaml =
              '''
proxy-providers:
  remote: {type: http, url: '$address/nodes', path: nodes.yaml}
proxy-groups: [{name: route, type: select, use: [remote]}]
rule-providers:
  domains: {type: http, url: '$address/rules', path: domains.yaml, behavior: domain}
rules: ['RULE-SET,domains,DIRECT', 'MATCH,route']
''';
          final home = await appPath.homeDirPath;
          expect((await controller.checkConfig(yaml)).valid, isTrue);
          expect(await File('$home/nodes.yaml').exists(), isFalse);
          expect(await File('$home/domains.yaml').exists(), isFalse);
          unsafe = true;
          final rejected = await controller.checkConfig(yaml);
          expect(rejected.valid, isFalse);
          expect(
            rejected.diagnostics.any((item) => item.reason.contains('tls')),
            isTrue,
          );
          expect((await controller.getRuntimeState()).configured, isFalse);
          unsafe = false;
          for (final options in [
            '{tls: typo}',
            '{tls: {enabled: true}}',
            "'tls=typo'",
            "'unknown=true'",
          ]) {
            pluginOptions = options;
            final providerCheck = await controller.checkConfig(yaml);
            expect(providerCheck.valid, isFalse, reason: options);
            expect(
              providerCheck.diagnostics.any(
                (item) => item.reason.contains('plugin-opts.'),
              ),
              isTrue,
            );
            final inline =
                'proxies: [{name: edge, type: ss, server: localhost, port: 443, cipher: aes-128-gcm, password: fixture, plugin: v2ray-plugin, plugin-opts: $options}]\nrules: ["MATCH,DIRECT"]\n';
            final checked = await controller.checkConfig(inline);
            expect(checked.valid, isFalse, reason: options);
            expect(
              checked.diagnostics.any(
                (item) => item.path.startsWith('proxies[0].plugin-opts.'),
              ),
              isTrue,
            );
            await File(await appPath.configFilePath).writeAsString(yaml);
            await expectLater(
              controller.setupConfig(
                params: const SetupParams(selectedMap: {}, testUrl: ''),
              ),
              throwsA(
                isA<CoreMethodException>()
                    .having((error) => error.code, 'code', 'invalid_config')
                    .having(
                      (error) => error.message,
                      'message',
                      contains('plugin-opts.'),
                    ),
              ),
            );
            expect((await controller.getRuntimeState()).configured, isFalse);
            expect(await File('$home/nodes.yaml').exists(), isFalse);
          }
          final certificate = await controller.checkConfig(
            'proxies: [{name: edge, type: ss, server: localhost, port: 443, cipher: aes-128-gcm, password: fixture, plugin: gost-plugin, plugin-opts: {certificate: /outside/cert.pem}}]\nrules: ["MATCH,DIRECT"]\n',
          );
          expect(certificate.valid, isFalse);
          expect(
            certificate.diagnostics.any(
              (item) => item.path == 'proxies[0].plugin-opts.certificate',
            ),
            isTrue,
          );
          pluginOptions = null;
          await File(await appPath.configFilePath).writeAsString(yaml);
          expect(
            await controller.setupConfig(
              params: const SetupParams(selectedMap: {}, testUrl: ''),
            ),
            isEmpty,
          );
          expect(await File('$home/nodes.yaml').exists(), isTrue);
          expect(await File('$home/domains.yaml').exists(), isTrue);
          expect(
            (await _groups(
              controller,
              '$address/',
            )).getGroup('route')!.all.map((proxy) => proxy.name),
            contains('edge'),
          );
          for (final options in [
            '{tls: true, mode: websocket, headers: {Authorization: fixture}}',
            "'tls;mode=ws;header=Authorization:fixture'",
          ]) {
            pluginOptions = options;
            await File('$home/nodes.yaml').delete();
            expect((await controller.checkConfig(yaml)).valid, isTrue);
            expect(await File('$home/nodes.yaml').exists(), isFalse);
            expect(
              await controller.setupConfig(
                params: const SetupParams(selectedMap: {}, testUrl: ''),
              ),
              isEmpty,
            );
            expect(await File('$home/nodes.yaml').exists(), isTrue);
          }
          pluginOptions = null;
          final geoYaml =
              '''
strict: true
geodata: {geosite-path: sites.dat, url: {geosite: '$address/sites'}}
dns: {enable: true, nameserver-policy: {'geosite:local': 'rcode://success'}}
rules: ['GEOSITE,local,DIRECT', 'MATCH,DIRECT']
''';
          expect((await controller.checkConfig(geoYaml)).valid, isTrue);
          expect(await File('$home/sites.dat').exists(), isFalse);
          await File(await appPath.configFilePath).writeAsString(geoYaml);
          expect(
            await controller.setupConfig(
              params: const SetupParams(selectedMap: {}, testUrl: ''),
            ),
            isEmpty,
          );
          expect(await File('$home/sites.dat').readAsBytes(), geosite);
        });
      } finally {
        await requests.cancel();
        await server.close(force: true);
      }
    },
    skip: executable == null,
  );

  testWidgets(
    'real host setup with CoreManager never refreshes an unnamed provider',
    (tester) async {
      final events = _ProviderLoadedEvents();
      coreEventManager.addListener(events);
      addTearDown(() => coreEventManager.removeListener(events));
      await tester.runAsync(
        () => _withRealHost(executable!, (controller) async {
          final container = ProviderContainer(
            overrides: [
              coreHandlerProvider.overrideWithValue(controller),
              profilesProvider.overrideWith(TestProfiles.new),
            ],
          );
          try {
            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: container,
                child: const MaterialApp(home: CoreManager(child: SizedBox())),
              ),
            );
            await File(
              await appPath.configFilePath,
            ).writeAsString('rules: ["MATCH,DIRECT"]\n');
            expect(
              await controller.setupConfig(
                params: const SetupParams(selectedMap: {}, testUrl: ''),
              ),
              isEmpty,
            );
            await pumpEventQueue();
            expect(events.names, isEmpty);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            container.dispose();
          }
        }),
      );
    },
    skip: executable == null,
  );

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
        await expectLater(
          controller.requestGc(),
          throwsA(
            isA<CoreMethodException>().having(
              (error) => error.code,
              'code',
              'unsupported_method',
            ),
          ),
        );
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
        expect(rejected.diagnostics.single.path, 'proxies[0].type');
        expect(rejected.diagnostics.single.reason, contains('tuic'));
        expect(rejected.diagnostics.single.suggestion, isNotEmpty);
        expect((await controller.getRuntimeState()).configured, isFalse);
        for (final options in [
          'username: 123, password: 456',
          "tls: 'true'",
          "skip-cert-verify: 'false'",
          'headers: {Authorization: 123}',
        ]) {
          final check = await controller.checkConfig(
            'proxies: [{name: edge, type: http, server: localhost, port: 443, $options}]\nrules: ["MATCH,DIRECT"]\n',
          );
          expect(check.valid, isFalse);
          expect(
            check.diagnostics.any(
              (item) => item.path.startsWith('proxies[0].'),
            ),
            isTrue,
          );
        }
        final mtu = await controller.checkConfig(
          'tun: {mtu: 1200}\nrules: ["MATCH,DIRECT"]\n',
        );
        expect(mtu.valid, isFalse);
        expect(mtu.diagnostics.single.path, 'tun.mtu');

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
