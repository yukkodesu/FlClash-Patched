part of '../action.dart';

@Riverpod(keepAlive: true)
class CoreAction extends _$CoreAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  int _requestedRestartRevision = 0;
  Future<bool>? _restartOperation;

  @override
  void build() {}

  Future<void> initCore() async {
    final isInit = await _core.isInit;

    final version = ref.read(versionProvider);
    if (!isInit) {
      final res = await _core.init(version);
      if (!res) throw StateError('Core initialization failed.');
      ref.read(coreIdentityProvider.notifier).value = await _core.getCoreInfo();
      final runtime = await _core.getRuntimeState();
      ref.read(runtimeStatusProvider.notifier).value = runtime;
      if (runtime.recovery.requiresAttention) {
        dialogs.showNotifier(
          '${currentAppLocalizations.meowRecoveryRequired}\n${runtime.recovery.details.join('\n')}',
          level: MessageLevel.warning,
          allowCopy: true,
        );
      }
    } else {
      await ref.read(proxiesActionProvider.notifier).updateGroups();
    }
  }

  Future<void> startCore() async {
    ref.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
    try {
      final result = await startLifecycle();
      await _applyLifecycleResult(result);
    } catch (error) {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
      dialogs.showNotifier(
        error.toString(),
        level: MessageLevel.error,
        allowCopy: true,
      );
    }
  }

  @protected
  Future<CoreLifecycleResult> startLifecycle() {
    return _core.start();
  }

  @protected
  Future<CoreLifecycleResult> restartLifecycle() {
    return _core.restart();
  }

  Future<bool> _applyLifecycleResult(CoreLifecycleResult result) async {
    if (result.outcome == CoreLifecycleOutcome.superseded) return false;
    await initCore();
    ref.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    return true;
  }

  Future<void> closeConnection(String id) async {
    await _core.closeConnection(id);
  }

  Future<void> closeConnections() async {
    await _core.closeConnections();
  }

  Future<void> requestGc() async {
    await _core.requestGc();
  }

  Future<void> crash() async {
    await _core.crash();
  }

  Future<bool> restartCore() {
    _requestedRestartRevision++;
    final activeOperation = _restartOperation;
    if (activeOperation != null) {
      return activeOperation;
    }

    final operation = _runRestartWorker();
    _restartOperation = operation;
    return operation;
  }

  Future<bool> _runRestartWorker() async {
    try {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
      final result = await restartLifecycle();
      if (!await _applyLifecycleResult(result)) {
        return false;
      }

      var appliedRevision = 0;
      var applied = true;
      while (appliedRevision < _requestedRestartRevision) {
        final revision = _requestedRestartRevision;
        if (ref.read(requestedRunningProvider) || ref.read(isStartProvider)) {
          applied = await ref
              .read(setupActionProvider.notifier)
              .setRunning(true, initialize: true);
        } else {
          applied = await ref
              .read(setupActionProvider.notifier)
              .applyProfile(force: true);
        }
        appliedRevision = revision;
      }
      return applied;
    } catch (_) {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
      rethrow;
    } finally {
      _restartOperation = null;
    }
  }
}
