import 'package:fl_clash/manager/proxy_manager.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/state.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy/proxy.dart' as system_proxy;

import '../helpers/test_app.dart';

class _SystemProxy extends system_proxy.Proxy {
  final calls = <Object>[];
  bool failStart = false;
  @override
  Future<bool> startProxy(
    int port, [
    List<String> bypassDomain = const [],
  ]) async {
    calls.add(port);
    if (failStart) throw StateError('platform failure');
    return true;
  }

  @override
  Future<bool> stopProxy({bool onlyIfNeeded = false}) async {
    calls.add(onlyIfNeeded);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late _SystemProxy systemProxy;

  setUp(() {
    systemProxy = _SystemProxy();
    container = ProviderContainer();
    globalState.container = container;
  });

  tearDown(() => container.dispose());

  Future<void> pumpProxyManager(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          child: ProxyManager(
            proxyAdapter: systemProxy,
            child: const SizedBox(key: Key('child')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void enableSystemProxy({required bool running, int mixedPort = 7890}) {
    container.read(networkSettingProvider.notifier).value = const NetworkProps()
        .copyWith(systemProxy: true);
    container.read(patchClashConfigProvider.notifier).value =
        const PatchClashConfig().copyWith(mixedPort: mixedPort);
    container.read(runTimeProvider.notifier).value = running ? 1 : null;
  }

  testWidgets('initial inactive update never requests unowned cleanup', (
    tester,
  ) async {
    await pumpProxyManager(tester);
    expect(systemProxy.calls, [true]);
    enableSystemProxy(running: true);
    await tester.pumpAndSettle();
    container.read(runTimeProvider.notifier).value = null;
    await tester.pumpAndSettle();
    expect(systemProxy.calls, [true, 7890, true]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('renders its child unchanged', (tester) async {
    await pumpProxyManager(tester);

    expect(find.byKey(const Key('child')), findsOneWidget);
    expect(tester.takeException(), null);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('platform failures never escape the update chain', (
    tester,
  ) async {
    await pumpProxyManager(tester);

    systemProxy.failStart = true;
    enableSystemProxy(running: true);
    await tester.pumpAndSettle();

    expect(tester.takeException(), null);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a failed update does not stall later transitions', (
    tester,
  ) async {
    await pumpProxyManager(tester);

    systemProxy.failStart = true;
    enableSystemProxy(running: true);
    await tester.pump();
    systemProxy.failStart = false;
    enableSystemProxy(running: true, mixedPort: 7891);
    await tester.pump();
    container.read(runTimeProvider.notifier).value = null;
    await tester.pumpAndSettle();

    expect(container.read(proxyStateProvider).isStart, isFalse);
    expect(tester.takeException(), null);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('a running core reports the mixed port as the proxy target', () {
    container.read(runTimeProvider.notifier).value = 1;
    container.read(networkSettingProvider.notifier).value = const NetworkProps()
        .copyWith(systemProxy: true);
    container.read(patchClashConfigProvider.notifier).value =
        const PatchClashConfig().copyWith(mixedPort: 7892);

    final state = container.read(proxyStateProvider);
    expect(state.isStart, isTrue);
    expect(state.systemProxy, isTrue);
    expect(state.port, 7892);
  });

  test('an excluded SSID suspends the system proxy', () {
    final suspended = ProviderContainer(
      overrides: [
        excludeSSIDsProvider.overrideWithValue(const ['Office Wi-Fi']),
      ],
    );
    addTearDown(suspended.dispose);
    suspended.read(runTimeProvider.notifier).value = 1;
    suspended.read(currentSSIDProvider.notifier).value = 'Office Wi-Fi';

    expect(suspended.read(proxyStateProvider).isStart, isFalse);
  });
}
