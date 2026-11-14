import 'package:equatable/equatable.dart';

import '../../settings/domain/bitcoin_network.dart';

enum SyncPhase {
  /// `initialblockdownload` is true.
  initialDownload,

  /// IBD is over but validated blocks still trail known headers.
  catchingUp,

  /// Not in IBD and `blocks == headers`.
  synced,
}

/// Domain view of `getblockchaininfo`
/// (`crates/floresta-node/src/json_rpc/blockchain.rs`).
class BlockchainInfo extends Equatable {
  const BlockchainInfo({
    required this.chain,
    required this.network,
    required this.validatedHeight,
    required this.headerHeight,
    required this.bestBlockHash,
    required this.verificationProgress,
    required this.initialBlockDownload,
    required this.tipTime,
    required this.sizeOnDisk,
    required this.warnings,
    this.utreexoLeaves,
    this.utreexoRoots,
  });

  /// Raw `chain` string; kept for diagnostics when [network] is null.
  final String chain;
  final BitcoinNetwork? network;

  /// `blocks`: height of the most-work fully validated chain.
  final int validatedHeight;

  /// `headers`: height of the best known header.
  final int headerHeight;
  final String bestBlockHash;

  /// Upstream computes this from block timestamps, not heights, so it is an
  /// estimate and the UI labels it as one.
  final double verificationProgress;
  final bool initialBlockDownload;
  final DateTime tipTime;

  /// Null when the node version does not report it (v0.9.x).
  final int? sizeOnDisk;
  final List<String> warnings;

  /// Size of the Utreexo accumulator (UTXOs ever added, and the
  /// number of tree roots). v0.9.x `leaf_count`/`root_count`; null on nodes
  /// that report Core's shape. Non-zero leaves mean a chain state is loaded.
  final int? utreexoLeaves;
  final int? utreexoRoots;

  SyncPhase get phase {
    if (initialBlockDownload) return SyncPhase.initialDownload;
    if (validatedHeight < headerHeight) return SyncPhase.catchingUp;
    return SyncPhase.synced;
  }

  @override
  List<Object?> get props => [
    chain,
    validatedHeight,
    headerHeight,
    bestBlockHash,
    verificationProgress,
    initialBlockDownload,
    tipTime,
    sizeOnDisk,
    warnings,
    utreexoLeaves,
    utreexoRoots,
  ];
}
