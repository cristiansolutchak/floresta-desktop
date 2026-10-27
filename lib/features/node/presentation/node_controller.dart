import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/logging/log_buffer.dart';
import '../../../core/providers.dart';
import '../../../core/rpc/json_rpc_client.dart';
import '../../installation/presentation/installation_providers.dart';
import '../../settings/presentation/settings_controller.dart';
import '../../../core/processes/process_inspector.dart';
import '../data/florestad_process_manager.dart';
import '../data/electrum_probe.dart';
import '../data/managed_node_store.dart';
import '../data/preflight_probe.dart';
import '../data/node_rpc_repository_impl.dart';
import '../domain/node_process_manager.dart';
import '../domain/node_process_state.dart';
import '../domain/node_rpc_repository.dart';
import '../domain/node_readiness.dart';
import '../domain/node_status.dart';
import '../domain/preflight.dart';
import '../domain/sync_progress.dart';
import '../domain/verification_breakdown.dart';

final rpcClientProvider = Provider<JsonRpcClient>((ref) {
  final endpoint = ref.watch(
    settingsControllerProvider.select((s) => s.rpcEndpoint),
  );
  return JsonRpcClient(
    endpoint: endpoint,
    httpClient: ref.watch(httpClientProvider),
  );
});

final nodeRpcRepositoryProvider = Provider<NodeRpcRepository>(
  (ref) => NodeRpcRepositoryImpl(ref.watch(rpcClientProvider)),
);

/// One supervisor for the app's lifetime; it must outlive settings changes
/// so a running child is never orphaned by a rebuild.
final nodeProcessManagerProvider = Provider<NodeProcessManager>((ref) {
  final manager = FlorestadProcessManager(
    requestGracefulStop: () async =>
        (await ref.read(nodeRpcRepositoryProvider).requestStop()).isRight(),
    store: ManagedNodeStore(ref.read(appPathsProvider)),
    inspector: SystemProcessInspector(),
  );
  ref.onDispose(manager.dispose);
  return manager;
});

final preflightProbeProvider = Provider<PreflightProbe>((ref) {
  final env = ref.watch(environmentProvider);
  return PreflightProbe(homeDir: env['HOME'] ?? env['USERPROFILE']);
});

final electrumProbeProvider = Provider<ElectrumProbe>(
  (ref) => const ElectrumProbe(),
);

final nodeControllerProvider = NotifierProvider<NodeController, NodeStatus>(
  NodeController.new,
);

class NodeController extends Notifier<NodeStatus> {
  /// Faster while starting so the UI notices the API coming up promptly.
  static const _pollActive = Duration(seconds: 2);
  static const _pollSteady = Duration(seconds: 5);

  Timer? _timer;
  bool _polling = false;

  /// A refresh was requested while one was in flight; run another after it,
  /// so its (possibly stale) result is not the last word.
  bool _refreshAgain = false;

  /// A busy node can miss a poll (Mandacaru #160 §3). While our own process
  /// is alive and the API was answering, this many consecutive failures are
  /// needed before showing it as unreachable (NODE-12).
  static const failuresBeforeUnreachable = 3;
  int _rpcFailures = 0;

  static const diskEvery = Duration(seconds: 60);
  bool _checkingDisk = false;

  /// Measures the data folder and free space; only while our node runs.
  Future<void> checkDisk() async {
    if (_checkingDisk || !ref.mounted || !state.process.isActive) return;
    _checkingDisk = true;
    try {
      final usage = await ref
          .read(preflightProbeProvider)
          .diskUsage(ref.read(settingsControllerProvider));
      if (ref.mounted) state = state.copyWith(disk: usage);
    } finally {
      _checkingDisk = false;
    }
  }

  /// Electrum is re-checked at most this often while the API answers.
  static const _electrumEvery = Duration(seconds: 30);
  DateTime? _electrumCheckedAt;

  NodeProcessManager get _manager => ref.read(nodeProcessManagerProvider);
  NodeRpcRepository get _rpc => ref.read(nodeRpcRepositoryProvider);

  @override
  NodeStatus build() {
    // Rebuild (and drop stale chain data) when the endpoint changes.
    ref.watch(settingsControllerProvider.select((s) => s.rpcEndpoint));
    final manager = ref.watch(nodeProcessManagerProvider);
    final sub = manager.states.listen(_onProcessState);
    // CFG-08: watch the data folder while our node runs (it grows with
    // filters and logs; free space can run out mid-sync).
    final diskTimer = Timer.periodic(diskEvery, (_) => unawaited(checkDisk()));
    ref.onDispose(() {
      sub.cancel();
      _timer?.cancel();
      diskTimer.cancel();
    });
    _schedule(_pollActive);
    Future.microtask(() async {
      // A florestad from an earlier session of this app (crash, force-quit)
      // is taken over before polling, so it is not shown as a stranger.
      await manager.reattach();
      await refresh();
    });
    return NodeStatus(process: manager.state);
  }

  void _onProcessState(NodeProcessState s) {
    if (s.isActive) {
      state = state.copyWith(process: s);
      return;
    }
    // Our node is gone, so whatever the API said belongs to it: forget it
    // now instead of showing a stale "reachable" (which would look like a
    // node started elsewhere), then re-check, since another node may
    // still answer on the port.
    _rpcFailures = 0;
    state = state.copyWith(
      process: s,
      api: ApiReachability.unknown,
      clearChain: true,
    );
    _refreshAgain = true;
    unawaited(refresh());
  }

  void _schedule(Duration every) {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => refresh());
  }

  Future<void> refresh() async {
    if (!ref.mounted) return;
    if (_polling) {
      _refreshAgain = true;
      return;
    }
    _refreshAgain = false;
    _polling = true;
    try {
      final info = await _rpc.getBlockchainInfo();
      if (!ref.mounted) return;
      await info.match(
        (failure) async {
          _rpcFailures++;
          final tolerate =
              state.process.isActive &&
              state.api == ApiReachability.reachable &&
              _rpcFailures < failuresBeforeUnreachable;
          state = tolerate
              ? state.copyWith(lastRpcFailure: failure)
              : state.copyWith(
                  api: ApiReachability.unreachable,
                  lastRpcFailure: failure,
                  clearChain: true,
                  lastUpdated: DateTime.now(),
                );
        },
        (chain) async {
          _rpcFailures = 0;
          final (peers, uptime) = await (
            _rpc.getPeers(),
            _rpc.getUptime(),
          ).wait;
          if (!ref.mounted) return;
          final now = DateTime.now();
          final before = state.chain;
          final moved =
              before == null ||
              state.lastProgressAt == null ||
              before.headerHeight != chain.headerHeight ||
              before.validatedHeight != chain.validatedHeight;
          state = state.copyWith(
            api: ApiReachability.reachable,
            chain: chain,
            peers: peers.toNullable(),
            uptime: uptime.toNullable(),
            clearFailure: true,
            lastUpdated: now,
            lastProgressAt: moved ? now : null,
          );
          await _checkElectrum(now);
        },
      );
      final steady =
          state.api == ApiReachability.reachable || !state.process.isActive;
      _schedule(steady ? _pollSteady : _pollActive);
    } finally {
      _polling = false;
      if (_refreshAgain && ref.mounted) unawaited(refresh());
    }
  }

  Future<void> _checkElectrum(DateTime now) async {
    final last = _electrumCheckedAt;
    if (state.electrum == ElectrumCheck.ok &&
        last != null &&
        now.difference(last) < _electrumEvery) {
      return;
    }
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _electrumCheckedAt = now;
    final network = ref.read(settingsControllerProvider).network;
    final result = await ref.read(electrumProbeProvider).check(network);
    if (ref.mounted) state = state.copyWith(electrum: result);
  }

  Future<Either<Failure, Unit>> start() async {
    await refresh();
    if (state.api == ApiReachability.reachable) {
      return const Left(
        ProcessStateFailure(
          'A node is already answering on this port, so a second one would '
          'fail to start. It is shown here but was not started by this app.',
        ),
      );
    }
    final detection = await ref.read(installationDetectionProvider.future);
    return detection.match((failure) async => Left(failure), (install) async {
      final settings = ref.read(settingsControllerProvider);
      final issues = evaluatePreflight(
        await ref.read(preflightProbeProvider).gather(settings),
      );
      if (!ref.mounted) return const Left(ProcessStateFailure('Closed.'));
      state = state.copyWith(
        preflightWarnings: [
          for (final i in issues)
            if (!i.blocks) i,
        ],
      );
      if (issues.where((i) => i.blocks).firstOrNull case final b?) {
        return Left(
          PreflightFailure(
            title: b.title,
            message: b.message,
            recovery: b.recovery,
          ),
        );
      }
      await ref.read(preflightProbeProvider).restrictDataDir(settings);
      if (!ref.mounted) return const Left(ProcessStateFailure('Closed.'));
      _schedule(_pollActive);
      return _manager.start(
        executablePath: install.executablePath,
        settings: settings,
      );
    });
  }

  /// Stops the node: supervised processes with escalation, an external node
  /// with the `stop` RPC only (the app has no handle to signal it).
  Future<Either<Failure, Unit>> stop() async {
    if (state.isExternallyManaged) {
      final result = await _rpc.requestStop();
      unawaited(Future.delayed(const Duration(seconds: 6), refresh));
      return result;
    }
    return _manager.stop();
  }

  Future<Either<Failure, Unit>> restart() async {
    final stopped = await stop();
    if (stopped.isLeft()) return stopped;
    return start();
  }
}

/// Readiness derived from the latest status; recomputed on every poll.
final nodeReadinessProvider = Provider<NodeReadiness>((ref) {
  final status = ref.watch(nodeControllerProvider);
  final settings = ref.watch(settingsControllerProvider);
  final network = settings.network;
  final logs = ref.watch(nodeLogsProvider);
  return assessReadiness(
    status,
    expected: network,
    now: DateTime.now(),
    snapshotHeight: settings.snapshotHeight,
    noUtreexoPeersLogged: logsShowNoUtreexoPeers(
      logs.reversed.take(100).map((l) => l.text),
    ),
  );
});

/// What the node verified itself versus accepted from the snapshot
/// (SYNC-02); null until the node reports its chain.
final verificationBreakdownProvider = Provider<VerificationBreakdown?>((ref) {
  final chain = ref.watch(nodeControllerProvider.select((s) => s.chain));
  final network = chain?.network;
  if (chain == null || network == null) return null;
  return VerificationBreakdown.of(
    chain,
    network,
    snapshotHeight: ref.watch(nodeReadinessProvider).snapshotHeight,
  );
});

/// The dashboard's sync step and numbers; null until the node reports its
/// chain.
final syncProgressProvider = Provider<SyncProgress?>((ref) {
  final chain = ref.watch(nodeControllerProvider.select((s) => s.chain));
  if (chain == null) return null;
  return SyncProgress.of(
    chain,
    ref.watch(nodeReadinessProvider),
    ref.watch(verificationBreakdownProvider),
  );
});

/// Snapshot of daemon output, throttled so a chatty node cannot cause a
/// rebuild per line.
final nodeLogsProvider = NotifierProvider<NodeLogsController, List<LogLine>>(
  NodeLogsController.new,
);

class NodeLogsController extends Notifier<List<LogLine>> {
  @override
  List<LogLine> build() {
    final manager = ref.watch(nodeProcessManagerProvider);
    var dirty = false;
    final sub = manager.logLines.listen((_) => dirty = true);
    final timer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (dirty) {
        dirty = false;
        state = manager.logs;
      }
    });
    ref.onDispose(() {
      sub.cancel();
      timer.cancel();
    });
    return manager.logs;
  }
}
