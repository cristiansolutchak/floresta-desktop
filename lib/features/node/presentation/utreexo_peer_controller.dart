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
    this.forkPeersDropped = const [],
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

  /// Peers on another chain disconnected so florestad could finish header
  /// selection (SYNC-10).
  final List<String> forkPeersDropped;

  UtreexoPeerSearch copyWith({
    DateTime? lastAttempt,
    int? tried,
    List<String>? added,
    List<String>? dropped,
    List<DateTime>? restarts,
    List<String>? forkPeersDropped,
  }) => UtreexoPeerSearch(
    lastAttempt: lastAttempt ?? this.lastAttempt,
    tried: tried ?? this.tried,
    added: added ?? this.added,
    dropped: dropped ?? this.dropped,
    restarts: restarts ?? this.restarts,
    forkPeersDropped: forkPeersDropped ?? this.forkPeersDropped,
  );

  @override
  List<Object?> get props => [
    lastAttempt,
    tried,
    added,
    dropped,
    restarts,
    forkPeersDropped,
  ];
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
      // Only peers the app verified count: silent Utreexo peers (seen on
      // mainnet: /bridge:0.1.3/) also advertise the bit and would otherwise
      // satisfy the target while serving no proofs.
      utreexoPeers: ready
          .where((p) => p.supportsUtreexo && state.added.contains(p.address))
          .length,
      now: DateTime.now(),
      lastAttempt: state.lastAttempt,
    );
    final inSelection = _inSelection(status);
    final forkDrop = _forkPeers(status, ready, inSelection);
    _maybeDrop(status, ready);
    _maybeDropForkPeers(status, forkDrop);
    _maybeRestart(status, inSelection, blockingPeers: forkDrop.length);
    if (!seek || _inFlight) return;
    unawaited(_seek(status, network, inSelection: inSelection));
  }

  /// The process the baseline belongs to, and its validated height when
  /// the app first saw it (the fallback when its output is not available).
  int? _baselinePid;
  int? _validatedAtStart;

  bool _inSelection(NodeStatus status) {
    final chain = status.chain;
    if (chain == null) return false;
    final pid = switch (status.process) {
      ProcessRunning(:final pid) || ProcessAdopted(:final pid) => pid,
      _ => null,
    };
    if (pid != _baselinePid) {
      _baselinePid = pid;
      _validatedAtStart = pid == null ? null : chain.validatedHeight;
    }
    // Only a process this app started has its output in the buffer.
    final lines = status.process is ProcessRunning
        ? [for (final l in ref.read(nodeLogsProvider)) l.text]
        : const <String>[];
    return inChainSelection(
      logged: selectionPhaseFromLogs(lines),
      validatedHeight: chain.validatedHeight,
      validatedAtStart: _validatedAtStart,
      headerHeight: chain.headerHeight,
      peerTip: ref.read(nodeReadinessProvider).peerTip,
    );
  }

  bool _restarting = false;
  final _stuck = StuckSelectionTracker();

  void _maybeRestart(
    NodeStatus status,
    bool inSelection, {
    required int blockingPeers,
  }) {
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
      inSelection: inSelection,
      headerHeight: chain.headerHeight,
      peerTip: readiness.peerTip,
      now: now,
      blockingPeers: blockingPeers,
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

  DateTime? _lastForkDrop;

  /// Peers holding chain selection up (on another chain, or a utreexod that
  /// is behind and ignores `getheaders`).
  List<String> _forkPeers(
    NodeStatus status,
    List<Peer> ready,
    bool inSelection,
  ) {
    final chain = status.chain;
    if (chain == null || status.isExternallyManaged) return const [];
    final readiness = ref.read(nodeReadinessProvider);
    return forkPeersToDrop(
      peers: [
        for (final p in ready) (address: p.address, height: p.initialHeight),
      ],
      consensusTip: readiness.peerTip,
      headerHeight: chain.headerHeight,
      inSelection: inSelection,
      snapshotHeight: readiness.snapshotHeight,
    );
  }

  void _maybeDropForkPeers(NodeStatus status, List<String> drop) {
    final now = DateTime.now();
    if (_lastForkDrop case final last?
        when now.difference(last).inSeconds < 60) {
      return;
    }
    if (drop.isEmpty) return;
    _lastForkDrop = now;
    final rpc = ref.read(nodeRpcRepositoryProvider);
    final ours = state.added.toSet();
    unawaited(() async {
      for (final a in drop) {
        // One the app added would be reconnected at once otherwise.
        await dropPeer(rpc, a, addedByApp: ours.contains(a));
      }
      if (ref.mounted) {
        state = state.copyWith(
          forkPeersDropped: {...state.forkPeersDropped, ...drop}.toList(),
        );
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

  Future<void> _seek(
    NodeStatus status,
    BitcoinNetwork network, {
    required bool inSelection,
  }) async {
    _inFlight = true;
    final started = DateTime.now();
    state = state.copyWith(lastAttempt: started);
    try {
      final attempts = await ref
          .read(utreexoPeerFinderProvider)
          .run(
            network,
            validatedHeight: status.chain?.validatedHeight ?? 0,
            inSelection: inSelection,
            consensusTip: ref.read(nodeReadinessProvider).peerTip,
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
