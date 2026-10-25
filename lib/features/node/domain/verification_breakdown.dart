import 'dart:math';

import 'package:equatable/equatable.dart';

import '../../settings/domain/bitcoin_network.dart';
import 'blockchain_info.dart';

/// What this node has verified itself versus what it accepted from the
/// Utreexo snapshot built into florestad (assume-utreexo).
///
/// `getblockchaininfo.progress` cannot be used for this: it counts the
/// snapshot as done (seen on signet: 90.55% while the node had verified
/// nothing past the snapshot). Every figure here comes from heights.
class VerificationBreakdown extends Equatable {
  const VerificationBreakdown({
    required this.headers,
    required this.validated,
    required this.snapshotHeight,
    required this.assumeValidHeight,
  });

  factory VerificationBreakdown.of(
    BlockchainInfo chain,
    BitcoinNetwork network,
  ) => VerificationBreakdown(
    headers: chain.headerHeight,
    validated: chain.validatedHeight,
    snapshotHeight: network.assumeUtreexoHeight,
    assumeValidHeight: network.assumeValidHeight,
  );

  final int headers;
  final int validated;
  final int snapshotHeight;
  final int assumeValidHeight;

  /// The node has jumped to the snapshot: `validated` reached its height.
  /// (A node validating from genesis would pass it only by verifying.)
  bool get snapshotApplied => snapshotHeight > 0 && validated >= snapshotHeight;

  /// Highest block accepted on trust from the snapshot (0 = none).
  int get acceptedUpTo => snapshotApplied ? snapshotHeight : 0;

  /// Blocks verified by this node itself.
  int get verifiedByNode => max(0, validated - acceptedUpTo);

  /// Blocks this node has to verify itself to reach the best header.
  int get toVerify => max(0, headers - acceptedUpTo);

  /// Share of [toVerify] done; null when there is nothing to verify.
  double? get fraction => toVerify == 0 ? null : verifiedByNode / toVerify;

  /// Highest self-verified block whose scripts were not checked
  /// (assume-valid); 0 when every self-verified block had script checks.
  int get scriptsSkippedUpTo =>
      verifiedByNode > 0 && assumeValidHeight > acceptedUpTo
      ? min(assumeValidHeight, validated)
      : 0;

  @override
  List<Object?> get props => [
    headers,
    validated,
    snapshotHeight,
    assumeValidHeight,
  ];
}
