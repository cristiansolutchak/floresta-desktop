import '../../../shared/format.dart';
import '../domain/bitcoin_network.dart';
import '../domain/node_settings.dart';

/// Wording for the sync methods, shared by the setup wizard and Settings so
/// both describe a choice the same way.
abstract final class SyncMethodLabels {
  static String title(SyncMethod m) => switch (m) {
    SyncMethod.swiftSync => 'Swift Sync',
    SyncMethod.fastStart => 'Fast Start (Assume Utreexo)',
    SyncMethod.full => 'Full validation',
  };

  static String description(SyncMethod m, BitcoinNetwork network) =>
      switch (m) {
        SyncMethod.swiftSync =>
          'Downloads a hints file, then processes every block from the '
              'first one in parallel from ordinary peers, without Utreexo '
              'proofs. Utreexo proofs take over for the most recent blocks. '
              'Measured on signet: 320,000 blocks in 16 minutes.',
        SyncMethod.fastStart =>
          'Starts from the chain state built into Floresta at block '
              '${formatInt(network.assumeUtreexoHeight)}, so the node is '
              'usable in minutes. The history before it is taken on trust, '
              'or re-checked later with backfill.',
        SyncMethod.full =>
          'Checks every block from the first one with Utreexo proofs. Few '
              'peers serve them, so this can take days.',
      };

  /// Why [m] cannot be chosen, or null when it can.
  static String? unavailable(
    SyncMethod m,
    BitcoinNetwork network, {
    required bool? binarySupportsSwiftSync,
  }) => switch (m) {
    SyncMethod.swiftSync when !network.supportsSwiftSync =>
      'No hints are published for ${network.label}.',
    SyncMethod.swiftSync when binarySupportsSwiftSync == false =>
      'The installed Floresta was built without Swift Sync (it is not in '
          'v0.9.1).',
    SyncMethod.fastStart when network.assumeUtreexoHeight == 0 =>
      'Floresta has no built-in chain state for ${network.label}.',
    _ => null,
  };

  /// One line for the review screen and Settings.
  static String summary(NodeSettings s) => switch (s.syncMethod) {
    SyncMethod.swiftSync =>
      'Swift Sync from the first block, hints from ${s.hintsOrigin}',
    SyncMethod.fastStart =>
      'Starts from block ${formatInt(s.snapshotHeight)} (Assume Utreexo), '
          '${s.backfill ? 'then re-checks the history before it' : 'history before it stays assumed'}',
    SyncMethod.full => 'Validates every block from the first one',
  };
}
