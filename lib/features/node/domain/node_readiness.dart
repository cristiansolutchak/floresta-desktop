import 'package:equatable/equatable.dart';

import '../../settings/domain/bitcoin_network.dart';
import 'node_status.dart';

/// Result of asking florestad's Electrum server who it is.
enum ElectrumCheck {
  /// Not checked yet (or the API is down).
  unknown,

  /// Answered with the expected network's genesis block.
  ok,

  /// Did not answer.
  unreachable,

  /// Answered for a different network.
  wrongNetwork,
}

/// Where a node is on its way to being usable, derived only from real
/// signals: the process, the RPC API, peers, the header and validated
/// heights from `getblockchaininfo`, and the Electrum server's genesis hash.
///
/// Observed on signet with v0.9.1 (2026-10-24, docs/audit/node-readiness.md):
/// peers within ~15 s; headers start ~80 s later; `height` counts headers
/// while `validated` stays 0 until the assumed Utreexo state is applied.
enum ReadinessStage {
  stopped,
  starting,
  findingPeers,
  downloadingHeaders,
  validatingBlocks,
  ready,
}

class NodeReadiness extends Equatable {
  const NodeReadiness(
    this.stage, {
    this.stalledFor,
    this.wrongNetwork = false,
    this.electrum = ElectrumCheck.unknown,
    this.missingUtreexoPeers = false,
  });

  final ReadinessStage stage;

  /// florestad has fewer than [minUtreexoPeers] peers serving Utreexo
  /// proofs, which it needs to verify blocks after the snapshot. Observed:
  /// signet 0 peers, mainnet 0–1 peers; validation stayed at the snapshot
  /// height for 12+ (signet) and ~22 (mainnet) minutes.
  final bool missingUtreexoPeers;

  /// Set when nothing has progressed for longer than the stall threshold
  /// while the node is not ready.
  final Duration? stalledFor;

  /// The node answering on the RPC port follows another network than the
  /// one selected in Settings.
  final bool wrongNetwork;
  final ElectrumCheck electrum;

  /// Ready and serving wallets: synced and Electrum confirmed on the right
  /// network.
  bool get usable =>
      stage == ReadinessStage.ready &&
      !wrongNetwork &&
      electrum == ElectrumCheck.ok;

  @override
  List<Object?> get props => [
    stage,
    stalledFor,
    wrongNetwork,
    electrum,
    missingUtreexoPeers,
  ];
}

/// No progress for this long while syncing means something is wrong
/// (no useful peers, network trouble). Headers took ~80 s to start on
/// signet, so this leaves ample margin.
const readinessStallAfter = Duration(minutes: 10);

/// florestad v0.9.1 wants at least this many peers advertising NODE_UTREEXO
/// to download proofs from (`sync_ctx.rs` `check_connections`: "we have
/// enough utreexo peers to download proofs from (at least 2)").
const minUtreexoPeers = 2;

/// v0.9.1 logs "Not enough utreexo peers (we have N)" (sync_ctx.rs:166) while
/// it has fewer than [minUtreexoPeers]. Log text is not an API: re-check it
/// on every upstream upgrade.
bool logsShowNoUtreexoPeers(Iterable<String> recentLines) =>
    recentLines.any((l) => l.contains('Not enough utreexo peers (we have '));

/// Pure: maps a status snapshot to a readiness stage.
NodeReadiness assessReadiness(
  NodeStatus s, {
  required BitcoinNetwork expected,
  required DateTime now,
  Duration stallAfter = readinessStallAfter,
  bool noUtreexoPeersLogged = false,
}) {
  final chain = s.chain;
  final wrongNetwork =
      chain != null && chain.network != null && chain.network != expected;
  if (s.api != ApiReachability.reachable || chain == null) {
    return NodeReadiness(
      s.process.isActive ? ReadinessStage.starting : ReadinessStage.stopped,
    );
  }
  final readyPeers = s.peers?.where((p) => p.isReady).length ?? 0;
  final ReadinessStage stage;
  if (!chain.initialBlockDownload &&
      chain.validatedHeight >= chain.headerHeight) {
    stage = ReadinessStage.ready;
  } else if (chain.validatedHeight > 0) {
    stage = ReadinessStage.validatingBlocks;
  } else if (readyPeers == 0 && chain.headerHeight == 0) {
    stage = ReadinessStage.findingPeers;
  } else {
    stage = ReadinessStage.downloadingHeaders;
  }
  final since = s.lastProgressAt;
  final idle = since == null ? null : now.difference(since);
  return NodeReadiness(
    stage,
    stalledFor:
        stage != ReadinessStage.ready && idle != null && idle > stallAfter
        ? idle
        : null,
    wrongNetwork: wrongNetwork,
    electrum: s.electrum,
    missingUtreexoPeers:
        stage == ReadinessStage.validatingBlocks &&
        (noUtreexoPeersLogged ||
            (readyPeers > 0 &&
                s.peers!.where((p) => p.isReady && p.supportsUtreexo).length <
                    minUtreexoPeers)),
  );
}
