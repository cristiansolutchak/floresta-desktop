import 'package:equatable/equatable.dart';

import '../../settings/domain/bitcoin_network.dart';

/// Swift Sync (florestad master since `6ecdcd0e`, 2026-02-08; not in
/// v0.9.1): when `<data dir>/<network>.hints` exists and the node has not
/// validated any block yet, florestad downloads blocks from ordinary peers
/// in parallel, without Utreexo proofs, up to the hints' stop height, then
/// finishes with the regular proof sync (`floresta-wire`
/// `p2p_wire/node/swift_sync_ctx.rs` at `3a47993`).
///
/// There is no CLI flag: the file's presence turns it on. Bad hints or an
/// invalid chain abort it, and the node then validates from the first block
/// with proofs, so wrong hints cost time, not safety.

/// The hints file's name in the network's data folder
/// (`swift_sync_ctx.rs` `parse_hints_file`: `format!("{network}.hints")`).
String hintsFileName(BitcoinNetwork network) => '${network.cliValue}.hints';

/// Where the hints are parked while Swift Sync is off, so turning it back
/// on needs no new download (floresta-desktop `src/node.rs`).
String parkedHintsFileName(BitcoinNetwork network) =>
    '${hintsFileName(network)}.disabled';

/// The origin the app downloads hints from by default; the file is at
/// `<origin>/<network>` (floresta-desktop `src/config.rs`, 2026-10-16).
const defaultHintsOrigin = 'https://utxohints.store/hints';

/// `<origin>/<network>`, or null for a network the server has no hints for.
Uri? hintsUrl(String origin, BitcoinNetwork network) {
  if (!network.supportsSwiftSync) return null;
  final base = origin.endsWith('/')
      ? origin.substring(0, origin.length - 1)
      : origin;
  return Uri.parse('$base/${network.cliValue}');
}

/// Why a hints origin is not acceptable, or null when it is.
///
/// HTTPS only, except plain HTTP to this machine (a local mirror or a
/// test server). No query or fragment, since the network name is appended.
String? hintsOriginProblem(String origin) {
  final uri = Uri.tryParse(origin.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return 'Enter a full address, such as $defaultHintsOrigin.';
  }
  if (uri.hasQuery || uri.hasFragment) {
    return 'The address cannot have a query (?) or fragment (#): the app '
        'adds the network name at the end.';
  }
  if (uri.userInfo.isNotEmpty) {
    return 'The address cannot contain a user name or password.';
  }
  final loopback = const {
    'localhost',
    '127.0.0.1',
    '[::1]',
    '::1',
  }.contains(uri.host);
  return switch (uri.scheme) {
    'https' => null,
    'http' when loopback => null,
    'http' => 'Use https. Plain http is accepted only for this computer.',
    _ => 'The address must start with https://.',
  };
}

/// The hints file's header: the magic `UTXO`, a version byte, then the stop
/// height as a little-endian u32 (`hintsfile` 0.2.1, the crate florestad
/// reads it with). Observed 2026-11-13: signet `55 54 58 4f 00 00 e2 04 00`
/// (320 000), mainnet 970 000.
abstract final class HintsHeader {
  static const length = 9;
  static const _magic = [0x55, 0x54, 0x58, 0x4f]; // "UTXO"

  /// The stop height, or null when [bytes] do not start like a hints file.
  static int? stopHeight(List<int> bytes) {
    if (bytes.length < length) return null;
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return null;
    }
    return bytes[5] | bytes[6] << 8 | bytes[7] << 16 | bytes[8] << 24;
  }

  /// True when [bytes] (the first bytes received) could still be a hints
  /// file, so a download that is not one stops early.
  static bool plausiblePrefix(List<int> bytes) {
    for (var i = 0; i < bytes.length && i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }
}

enum SwiftSyncPhase {
  /// No Swift Sync line seen since our node started.
  unknown,
  running,
  finished,

  /// The node decided not to run it ([SwiftSyncProgress.reason] says why).
  skipped,

  /// It started and gave up; the node validates from scratch with proofs.
  aborted,
}

/// Swift Sync as florestad's log tells it. No RPC exposes it: during Swift
/// Sync `getblockchaininfo` reports 0 validated blocks. So it is known only
/// for a node this app started and whose output it reads; for an adopted
/// or external node it stays [SwiftSyncPhase.unknown].
class SwiftSyncProgress extends Equatable {
  const SwiftSyncProgress({
    this.phase = SwiftSyncPhase.unknown,
    this.processed = 0,
    this.stopHeight,
    this.workers,
    this.reason,
  });

  final SwiftSyncPhase phase;

  /// Blocks processed so far. Workers run in parallel, so heights arrive
  /// out of order; the count is what moves steadily.
  final int processed;
  final int? stopHeight;
  final int? workers;

  /// The node's own words for a skip or an abort.
  final String? reason;

  double? get fraction => switch (stopHeight) {
    final s? when s > 0 => (processed / s).clamp(0.0, 1.0),
    _ => null,
  };

  bool get isRunning => phase == SwiftSyncPhase.running;

  SwiftSyncProgress _copy({
    SwiftSyncPhase? phase,
    int? processed,
    String? reason,
  }) => SwiftSyncProgress(
    phase: phase ?? this.phase,
    processed: processed ?? this.processed,
    stopHeight: stopHeight,
    workers: workers,
    reason: reason ?? this.reason,
  );

  /// Pure: the progress after one more log line. Log text is not an API:
  /// re-check these strings on every upstream upgrade.
  SwiftSyncProgress next(String line) {
    if (isBlockLine(line)) {
      return phase == SwiftSyncPhase.running
          ? _copy(processed: processed + 1)
          : this;
    }
    if (!line.contains('SwiftSync') && !line.contains('Swift Sync')) {
      return this;
    }
    if (_performing.firstMatch(line) case final m?) {
      return SwiftSyncProgress(
        phase: SwiftSyncPhase.running,
        stopHeight: int.parse(m[1]!),
        workers: int.parse(m[2]!),
      );
    }
    if (line.contains('SwiftSync is finished')) {
      return _copy(phase: SwiftSyncPhase.finished);
    }
    if (_skipping.firstMatch(line) case final m?) {
      return _copy(phase: SwiftSyncPhase.skipped, reason: m[1]!.trim());
    }
    if (_aborting.firstMatch(line) case final m?) {
      return _copy(phase: SwiftSyncPhase.aborted, reason: m[1]!.trim());
    }
    if (line.contains('SwiftSync failed')) {
      return _copy(
        phase: SwiftSyncPhase.aborted,
        reason: 'The hints file did not match the chain.',
      );
    }
    if (_unreadable.firstMatch(line) case final m?) {
      return _copy(
        phase: SwiftSyncPhase.skipped,
        reason: 'Could not read the hints file: ${m[1]!.trim()}',
      );
    }
    return this;
  }

  /// One line per processed block (about 650 a second on signet); the app
  /// counts them instead of keeping them all in the log view.
  static bool isBlockLine(String line) => line.contains('SwiftSync block: ');

  // swift_sync_ctx.rs at 3a47993.
  static final _performing = RegExp(
    r'Performing SwiftSync up to height (\d+) with up to (\d+) validation',
  );
  static final _skipping = RegExp(r'Skipping SwiftSync: (.*)$');
  static final _aborting = RegExp(r'Aborting SwiftSync: (.*)$');
  static final _unreadable = RegExp(
    r'Could not (?:open|read) SwiftSync hints (.*)$',
  );

  @override
  List<Object?> get props => [phase, processed, stopHeight, workers, reason];
}
