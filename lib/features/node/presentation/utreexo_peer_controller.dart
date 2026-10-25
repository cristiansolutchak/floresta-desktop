import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/domain/bitcoin_network.dart';
import '../../settings/presentation/settings_controller.dart';
import '../data/utreexo_peer_finder.dart';
import '../domain/node_process_state.dart';
import '../domain/node_status.dart';
import '../domain/peer.dart';
import '../domain/utreexo_peer.dart';
import 'node_controller.dart';

/// What the app has done to find Utreexo peers (SYNC-05).
class UtreexoPeerSearch extends Equatable {
  const UtreexoPeerSearch({
    this.lastAttempt,
    this.tried = 0,
    this.added = const [],
    this.dropped = const [],
    this.restarts = const [],
  });

  final DateTime? lastAttempt;
  final int tried;

  /// Verified over v1 and added for good.
  final List<String> added;

  /// Unverified Utreexo peers disconnected while validation was stuck.
  final List<String> dropped;

  /// When the app restarted the node because it never left header
  /// selection (SYNC-09).
  final List<DateTime> restarts;

  UtreexoPeerSearch copyWith({
    DateTime? lastAttempt,
    int? tried,
    List<String>? added,
    List<String>? dropped,
    List<DateTime>? restarts,
  }) => UtreexoPeerSearch(
    lastAttempt: lastAttempt ?? this.lastAttempt,
    tried: tried ?? this.tried,
    added: added ?? this.added,
    dropped: dropped ?? this.dropped,
    restarts: restarts ?? this.restarts,
  );

  @override
  List<Object?> get props => [lastAttempt, tried, added, dropped, restarts];
}

final utreexoPeerFinderProvider = Provider<UtreexoPeerFinder>(
  (ref) => UtreexoPeerFinder(rpc: ref.watch(nodeRpcRepositoryProvider)),
);

class UtreexoPeerController extends Notifier<UtreexoPeerSearch> {
  bool _inFlight = false;
  DateTime? _lastDrop;

  @override
  UtreexoPeerSearch build() {
    ref.listen(nodeControllerProvider, (_, status) => _maybeSeek(status));
    return const UtreexoPeerSearch();
  }

  void _maybeSeek(NodeStatus status) {
    final peers = status.peers ?? const [];
    final ready = peers.where((p) => p.isReady).toList();
    final network = ref.read(settingsControllerProvider).network;
    final seek = shouldSeekUtreexoPeers(
      ownNode:
          status.process is ProcessRunning &&
          status.api == ApiReachability.reachable &&
          !status.isExternallyManaged,
      network: network,
      connectedPeers: ready.length,
      utreexoPeers: ready.where((p) => p.supportsUtreexo).length,
      now: DateTime.now(),
      lastAttempt: state.lastAttempt,
    );
    _maybeDrop(status, ready);
    _maybeRestart(status);
    if (!seek || _inFlight) return;
    unawaited(_seek(status, network));
  }

  bool _restarting = false;
  final _stuck = StuckSelectionTracker();

  void _maybeRestart(NodeStatus status) {
    final chain = status.chain;
    if (chain == null || _restarting) return;
    final now = DateTime.now();
    final readiness = ref.read(nodeReadinessProvider);
    final restart = _stuck.sample(
      ownNode:
          status.process is ProcessRunning &&
          status.api == ApiReachability.reachable &&
          !status.isExternallyManaged,
      snapshotHeight: readiness.snapshotHeight,
      validatedHeight: chain.validatedHeight,
      headerHeight: chain.headerHeight,
      peerTip: readiness.peerTip,
      now: now,
    );
    if (!restart) return;
    _restarting = true;
    state = state.copyWith(restarts: List.of(_stuck.restarts));
    unawaited(() async {
      try {
        await ref.read(nodeControllerProvider.notifier).restart();
      } finally {
        _restarting = false;
      }
    }());
  }

  void _maybeDrop(NodeStatus status, List<Peer> ready) {
    final chain = status.chain;
    final since = status.lastProgressAt;
    final now = DateTime.now();
    if (status.isExternallyManaged ||
        chain == null ||
        !chain.initialBlockDownload ||
        chain.validatedHeight == 0 ||
        since == null) {
      return;
    }
    if (_lastDrop case final last? when now.difference(last).inMinutes < 3) {
      return;
    }
    final drop = stalledUtreexoPeersToDrop(
      connected: [
        for (final p in ready) (address: p.address, utreexo: p.supportsUtreexo),
      ],
      verified: state.added.toSet(),
      stalledFor: now.difference(since),
    );
    if (drop.isEmpty) return;
    _lastDrop = now;
    final rpc = ref.read(nodeRpcRepositoryProvider);
    unawaited(() async {
      for (final a in drop) {
        await rpc.disconnectNode(a);
      }
      if (ref.mounted) {
        state = state.copyWith(dropped: {...state.dropped, ...drop}.toList());
      }
    }());
  }

  Future<void> _seek(NodeStatus status, BitcoinNetwork network) async {
    _inFlight = true;
    final started = DateTime.now();
    state = state.copyWith(lastAttempt: started);
    try {
      final attempts = await ref
          .read(utreexoPeerFinderProvider)
          .run(
            network,
            networkTip: ref.read(nodeReadinessProvider).peerTip,
            alreadyConnected: {
              for (final p in status.peers ?? const []) p.address,
            },
          );
      if (!ref.mounted) return;
      state = state.copyWith(
        tried: state.tried + attempts.length,
        added: {
          ...state.added,
          for (final a in attempts)
            if (a.action == 'add') a.address,
        }.toList(),
      );
    } finally {
      _inFlight = false;
    }
  }
}

final utreexoPeerSearchProvider =
    NotifierProvider<UtreexoPeerController, UtreexoPeerSearch>(
      UtreexoPeerController.new,
    );
