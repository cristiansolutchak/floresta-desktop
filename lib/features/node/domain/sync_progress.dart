import 'dart:math';

import 'package:equatable/equatable.dart';

import 'blockchain_info.dart';
import 'node_readiness.dart';
import 'verification_breakdown.dart';

/// The three steps the Sync screen shows (Figma "Step n/3").
enum SyncStep {
  headers(1, 'Headers', 'Downloading Block Headers'),
  blocks(2, 'Blocks', 'Downloading & Verifying Blocks'),
  live(3, 'Live', 'Following the Network');

  const SyncStep(this.number, this.phase, this.title);
  final int number;

  /// Short name for tags ("Phase: Blocks").
  final String phase;
  final String title;
}

/// Everything the dashboard needs to describe sync, from real node data
/// only. Percentages are labelled by phase; nothing here is invented:
/// - headers: headers / network tip (an estimate from peers);
/// - blocks: blocks this node verified itself after the assume-utreexo
///   snapshot / blocks between the snapshot and the network tip (SYNC-02;
///   florestad's `progress` is not used, and neither is its own header
///   count, which can stop far below the tip);
/// - live: 100 %.
class SyncProgress extends Equatable {
  const SyncProgress({
    required this.step,
    required this.fraction,
    required this.currentHeight,
    required this.targetHeight,
    required this.behind,
    required this.tipIsEstimate,
  });

  final SyncStep step;

  /// 0..1, or null when it cannot be computed yet.
  final double? fraction;

  /// Highest block this node has validated (or accepted from the snapshot).
  final int currentHeight;

  /// Network tip: the height most peers agree on, else the node's headers.
  final int targetHeight;

  /// Blocks between [currentHeight] and [targetHeight].
  final int behind;

  /// [targetHeight] comes from peers' heights at connection time.
  final bool tipIsEstimate;

  /// Pure: derives the progress from a chain snapshot and readiness.
  static SyncProgress of(
    BlockchainInfo chain,
    NodeReadiness readiness,
    VerificationBreakdown? breakdown,
  ) {
    final tip = max(readiness.peerTip ?? 0, chain.headerHeight);
    final current = chain.validatedHeight;
    final SyncStep step;
    double? fraction;
    if (readiness.stage == ReadinessStage.ready) {
      step = SyncStep.live;
      fraction = 1;
    } else if (current == 0 ||
        readiness.stage == ReadinessStage.downloadingHeaders ||
        readiness.stage == ReadinessStage.findingPeers ||
        readiness.stage == ReadinessStage.behindNetwork) {
      step = SyncStep.headers;
      fraction = tip == 0 ? null : chain.headerHeight / tip;
    } else {
      step = SyncStep.blocks;
      if (breakdown != null) {
        final toVerify = tip - breakdown.acceptedUpTo;
        fraction = toVerify <= 0 ? null : breakdown.verifiedByNode / toVerify;
      }
    }
    return SyncProgress(
      step: step,
      fraction: fraction?.clamp(0.0, 1.0),
      currentHeight: current,
      targetHeight: tip,
      behind: max(0, tip - current),
      tipIsEstimate: (readiness.peerTip ?? 0) > chain.headerHeight,
    );
  }

  @override
  List<Object?> get props => [
    step,
    fraction,
    currentHeight,
    targetHeight,
    behind,
    tipIsEstimate,
  ];
}
