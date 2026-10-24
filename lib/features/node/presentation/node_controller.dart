import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/logging/log_buffer.dart';
import '../../../core/providers.dart';
import '../../../core/rpc/json_rpc_client.dart';
import '../../installation/presentation/installation_providers.dart';
import '../../settings/presentation/settings_controller.dart';
import '../data/florestad_process_manager.dart';
import '../data/node_rpc_repository_impl.dart';
import '../domain/node_process_manager.dart';
import '../domain/node_process_state.dart';
import '../domain/node_rpc_repository.dart';
import '../domain/node_status.dart';

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
  );
  ref.onDispose(manager.dispose);
  return manager;
});

final nodeControllerProvider = NotifierProvider<NodeController, NodeStatus>(
  NodeController.new,
);

class NodeController extends Notifier<NodeStatus> {
  /// Faster while starting so the UI notices the API coming up promptly.
  static const _pollActive = Duration(seconds: 2);
  static const _pollSteady = Duration(seconds: 5);

  Timer? _timer;
  bool _polling = false;

  NodeProcessManager get _manager => ref.read(nodeProcessManagerProvider);
  NodeRpcRepository get _rpc => ref.read(nodeRpcRepositoryProvider);

  @override
  NodeStatus build() {
    // Rebuild (and drop stale chain data) when the endpoint changes.
    ref.watch(settingsControllerProvider.select((s) => s.rpcEndpoint));
    final manager = ref.watch(nodeProcessManagerProvider);
    final sub = manager.states.listen(_onProcessState);
    ref.onDispose(() {
      sub.cancel();
      _timer?.cancel();
    });
    _schedule(_pollActive);
    Future.microtask(refresh);
    return NodeStatus(process: manager.state);
  }

  void _onProcessState(NodeProcessState s) {
    state = state.copyWith(process: s);
    if (!s.isActive) {
      // The API goes away with the process; re-check rather than assume,
      // since another node may still answer on the port.
      unawaited(refresh());
    }
  }

  void _schedule(Duration every) {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => refresh());
  }

  Future<void> refresh() async {
    if (_polling || !ref.mounted) return;
    _polling = true;
    try {
      final info = await _rpc.getBlockchainInfo();
      if (!ref.mounted) return;
      await info.match(
        (failure) async {
          state = state.copyWith(
            api: ApiReachability.unreachable,
            lastRpcFailure: failure,
            clearChain: true,
            lastUpdated: DateTime.now(),
          );
        },
        (chain) async {
          final (peers, uptime) = await (
            _rpc.getPeers(),
            _rpc.getUptime(),
          ).wait;
          if (!ref.mounted) return;
          state = state.copyWith(
            api: ApiReachability.reachable,
            chain: chain,
            peers: peers.toNullable(),
            uptime: uptime.toNullable(),
            clearFailure: true,
            lastUpdated: DateTime.now(),
          );
        },
      );
      final steady =
          state.api == ApiReachability.reachable || !state.process.isActive;
      _schedule(steady ? _pollSteady : _pollActive);
    } finally {
      _polling = false;
    }
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
    return detection.match((failure) async => Left(failure), (install) {
      _schedule(_pollActive);
      return _manager.start(
        executablePath: install.executablePath,
        settings: ref.read(settingsControllerProvider),
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
