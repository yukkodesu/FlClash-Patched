import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/core/info.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/config/network.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

class _ToggleCase {
  final String name;
  final Widget widget;
  final bool Function(ProviderContainer container) read;
  final bool initial;

  const _ToggleCase(this.name, this.widget, this.read, {this.initial = false});
}

final _toggleCases = <_ToggleCase>[
  _ToggleCase(
    'RecvMsgX',
    const RecvMsgXItem(),
    (c) => c.read(patchClashConfigProvider).tun.recvMsgX,
    initial: true,
  ),
  _ToggleCase(
    'SendMsgX',
    const SendMsgXItem(),
    (c) => c.read(patchClashConfigProvider).tun.sendMsgX,
  ),
  _ToggleCase(
    'VPN',
    const VPNItem(),
    (c) => c.read(vpnSettingProvider).enable,
    initial: true,
  ),
  _ToggleCase(
    'TUN',
    const TUNItem(),
    (c) => c.read(patchClashConfigProvider).tun.enable,
  ),
  _ToggleCase(
    'allow bypass',
    const AllowBypassItem(),
    (c) => c.read(vpnSettingProvider).allowBypass,
    initial: true,
  ),
  _ToggleCase(
    'vpn system proxy',
    const VpnSystemProxyItem(),
    (c) => c.read(vpnSettingProvider).systemProxy,
    initial: true,
  ),
  _ToggleCase(
    'system proxy',
    const SystemProxyItem(),
    (c) => c.read(networkSettingProvider).systemProxy,
    initial: true,
  ),
  _ToggleCase('ipv6', const Ipv6Item(), (c) => c.read(vpnSettingProvider).ipv6),
  _ToggleCase(
    'auto set system dns',
    const AutoSetSystemDnsItem(),
    (c) => c.read(networkSettingProvider).autoSetSystemDns,
    initial: true,
  ),
  _ToggleCase(
    'dns hijacking',
    const DNSHijackingItem(),
    (c) => c.read(vpnSettingProvider).dnsHijacking,
    initial: true,
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [profilesProvider.overrideWith(TestProfiles.new)],
    );
    globalState.container = container;
    container.read(viewSizeProvider.notifier).value = const Size(1200, 1000);
  });

  tearDown(() => container.dispose());

  Future<void> pumpItem(WidgetTester tester, Widget item) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          child: Scaffold(body: ListView(children: [item])),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('toggles write to their own setting', () {
    for (final testCase in _toggleCases) {
      testWidgets('${testCase.name} flips both ways', (tester) async {
        await pumpItem(tester, testCase.widget);

        expect(testCase.read(container), testCase.initial);

        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        expect(testCase.read(container), !testCase.initial);

        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        expect(testCase.read(container), testCase.initial);
      });
    }
  });

  testWidgets(
    'TUN shows unresolved recovery while preserving the disabled setting',
    (tester) async {
      container
          .read(runtimeStatusProvider.notifier)
          .value = CoreRuntimeState.fromJson({
        'initialized': true,
        'configured': false,
        'running': false,
        'tunActive': false,
        'generation': 1,
        'recovery': {
          'state': 'needsPrivilege',
          'details': ['Previous DNS lease requires privileged recovery.'],
        },
      });

      await pumpItem(tester, const TUNItem());

      expect(
        find.textContaining('Previous DNS lease requires privileged recovery.'),
        findsOneWidget,
      );
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(container.read(patchClashConfigProvider).tun.enable, isFalse);
    },
  );

  group('option pickers', () {
    testWidgets(
      'MTU below the core minimum is rejected before updating settings',
      (tester) async {
        await pumpItem(tester, const TunMtuItem());
        await tester.tap(find.byType(ListTile).first);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), '1200');
        await tester.tap(find.text('Submit'));
        await tester.pumpAndSettle();
        expect(container.read(patchClashConfigProvider).tun.mtu, 1500);
        expect(
          find.text('MTU must be an integer between 1280 and 65535'),
          findsOneWidget,
        );
        await tester.enterText(find.byType(TextFormField), '1280');
        await tester.tap(find.text('Submit'));
        await tester.pumpAndSettle();
        expect(container.read(patchClashConfigProvider).tun.mtu, 1280);
      },
    );

    testWidgets('the stack picker writes the chosen tun stack', (tester) async {
      await pumpItem(tester, const TunStackItem());
      final initial = container.read(patchClashConfigProvider).tun.stack;
      final target = TunStack.values.firstWhere((item) => item != initial);

      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(target.name).last);
      await tester.pumpAndSettle();

      expect(container.read(patchClashConfigProvider).tun.stack, target);
    });

    testWidgets('the congestion controller picker writes the chosen value', (
      tester,
    ) async {
      await pumpItem(tester, const TunCongestionControllerItem());
      final initial = container
          .read(patchClashConfigProvider)
          .tun
          .congestionController;
      final target = TunCongestionController.values.firstWhere(
        (item) => item != initial,
      );

      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(target.name).last);
      await tester.pumpAndSettle();

      expect(
        container.read(patchClashConfigProvider).tun.congestionController,
        target,
      );
    });

    testWidgets(
      'the congestion controller picker is hidden off the mips stack',
      (tester) async {
        container
            .read(patchClashConfigProvider.notifier)
            .update((state) => state.copyWith.tun(stack: TunStack.gvisor));

        await pumpItem(tester, const TunCongestionControllerItem());

        expect(find.byType(ListTile), findsNothing);
      },
    );

    testWidgets('the route mode picker writes the chosen mode', (tester) async {
      await pumpItem(tester, const RouteModeItem());
      final initial = container.read(networkSettingProvider).routeMode;
      final target = RouteMode.values.firstWhere((item) => item != initial);

      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(_routeModeLabel(target)).last);
      await tester.pumpAndSettle();

      expect(container.read(networkSettingProvider).routeMode, target);
    });

    testWidgets('the interface name mode picker writes the chosen mode', (
      tester,
    ) async {
      await pumpItem(tester, const InterfaceNameModeItem());
      final initial = container
          .read(patchClashConfigProvider)
          .interfaceNameMode;
      final target = InterfaceNameMode.values.firstWhere(
        (item) => item != initial,
      );

      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(_interfaceNameModeLabel(target)).last);
      await tester.pumpAndSettle();

      expect(
        container.read(patchClashConfigProvider).interfaceNameMode,
        target,
      );
    });
  });

  group('interface name visibility', () {
    testWidgets('is hidden unless the mode is custom', (tester) async {
      container
          .read(patchClashConfigProvider.notifier)
          .update(
            (state) =>
                state.copyWith(interfaceNameMode: InterfaceNameMode.follow),
          );

      await pumpItem(tester, const InterfaceNameItem());

      expect(find.byType(ListTile), findsNothing);
    });

    testWidgets('is shown when the mode is custom', (tester) async {
      container
          .read(patchClashConfigProvider.notifier)
          .update(
            (state) =>
                state.copyWith(interfaceNameMode: InterfaceNameMode.custom),
          );

      await pumpItem(tester, const InterfaceNameItem());

      expect(find.byType(ListTile), findsOneWidget);
    });
  });

  test('desktop network options omit unsupported mihomo controls', () {
    final items = networkOptionsItems(isDesktop: true, isMacOS: false);
    expect(items.whereType<TunRouteModeItem>(), hasLength(1));
    expect(items.whereType<TunStackItem>(), isEmpty);
    expect(items.whereType<TunCongestionControllerItem>(), isEmpty);
    expect(items.whereType<StrictRouteItem>(), isEmpty);
    expect(items.whereType<InterfaceNameItem>(), isEmpty);
  });
}

String _routeModeLabel(RouteMode mode) {
  return switch (mode) {
    RouteMode.config => 'Use config',
    RouteMode.bypassPrivate => 'Bypass private addresses',
  };
}

String _interfaceNameModeLabel(InterfaceNameMode mode) {
  return switch (mode) {
    InterfaceNameMode.clear => 'Clear',
    InterfaceNameMode.follow => 'Follow config',
    InterfaceNameMode.custom => 'Custom',
  };
}
