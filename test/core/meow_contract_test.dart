import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:test/test.dart';

class HostContract extends CoreHandlerInterface {
  final Map<String, Object?> responses;

  HostContract(this.responses);

  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) async => responses[method.name] as T?;

  @override
  Future<CoreLifecycleResult> start() => throw UnimplementedError();

  @override
  Future<CoreLifecycleResult> restart() => throw UnimplementedError();

  @override
  Future<CoreLifecycleResult> stop() => throw UnimplementedError();

  @override
  Future<CoreLifecycleResult> close() => throw UnimplementedError();
}

const hostInfo = <String, Object?>{
  'name': 'meow-rs',
  'version': '0.22.0',
  'hostVersion': '0.1.0',
  'commit': '3c27aca92d64c7194c6b590e529da46465fbb7eb',
  'protocolVersion': 1,
  'capabilities': ['connections', 'traffic', 'config-check'],
  'statisticsScope': 'all',
  'connectionsScope': 'tcp',
  'tunModes': [],
};

void main() {
  test(
    'controller exposes native recovery warnings without claiming TUN active',
    () async {
      final controller = CoreController.scoped(
        HostContract({
          'getRuntimeState': {
            'initialized': true,
            'configured': false,
            'running': false,
            'tunActive': false,
            'generation': 1,
            'recovery': {
              'state': 'needsPrivilege',
              'details': ['Previous DNS lease requires privileged recovery.'],
            },
          },
        }),
      );
      final runtime = await controller.getRuntimeState();
      expect(runtime.initialized, isTrue);
      expect(runtime.tunActive, isFalse);
      expect(runtime.recovery.requiresAttention, isTrue);
      expect(runtime.recovery.details, [
        'Previous DNS lease requires privileged recovery.',
      ]);
    },
  );

  test(
    'controller exposes actual host capabilities and traffic scope',
    () async {
      final controller = CoreController.scoped(
        HostContract({'getCoreInfo': hostInfo}),
      );
      final info = await controller.getCoreInfo();
      expect(info.version, '0.22.0');
      expect(info.hostVersion, '0.1.0');
      expect(info.capabilities, contains('connections'));
      expect(info.capabilities, isNot(contains('node-traffic')));
      expect(info.statisticsScope, 'all');
      expect(info.connectionsScope, 'tcp');
    },
  );

  test('controller rejects an incompatible host control protocol', () async {
    final controller = CoreController.scoped(
      HostContract({
        'getCoreInfo': {...hostInfo, 'protocolVersion': 2},
      }),
    );
    await expectLater(
      controller.getCoreInfo(),
      throwsA(
        isA<CoreMethodException>().having(
          (error) => error.code,
          'code',
          'incompatible_protocol',
        ),
      ),
    );
  });

  test(
    'configuration rejection retains actionable object diagnostics',
    () async {
      final controller = CoreController.scoped(
        HostContract({
          'checkConfig': {
            'valid': false,
            'diagnostics': [
              {
                'severity': 'error',
                'path': 'proxies[0].type',
                'reason': 'tuic is unsupported',
                'suggestion': 'Use a supported proxy protocol.',
              },
            ],
          },
        }),
      );
      final result = await controller.checkConfig(
        'proxies:\n  - name: unsupported\n    type: tuic\n',
      );
      expect(result.valid, false);
      expect(result.diagnostics.single.path, 'proxies[0].type');
      expect(result.diagnostics.single.reason, 'tuic is unsupported');
      expect(result.diagnostics.single.suggestion, isNotEmpty);
    },
  );
}
