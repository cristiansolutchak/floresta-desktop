import 'dart:math';

import 'package:equatable/equatable.dart';

import '../../settings/domain/bitcoin_network.dart';

/// Probe error when a node accepted the connection but closed it without a
/// v1 `version`: typical of nodes that only speak the v2 (BIP-324)
/// transport.
const noVersionReply = 'closed before sending version';

/// NODE_UTREEXO service bit (BIP-0183 draft; florestad `service_flags`).
const nodeUtreexoBit = 1 << 12;

/// What a node said about itself in its `version` message, or why it could
/// not be asked.
class PeerProbe extends Equatable {
  const PeerProbe({
    required this.protocolVersion,
    required this.services,
    required this.userAgent,
    required this.height,
  }) : error = null;

  const PeerProbe.failed(this.error)
    : protocolVersion = 0,
      services = 0,
      userAgent = '',
      height = 0;

  final int protocolVersion;
  final int services;
  final String userAgent;
  final int height;
  final String? error;

  bool get answered => error == null;
  bool get servesUtreexo => answered && services & nodeUtreexoBit != 0;

  @override
  List<Object?> get props => [
    protocolVersion,
    services,
    userAgent,
    height,
    error,
  ];
}

/// Whether a probed node is worth handing to florestad as a
/// Utreexo peer: it must serve Utreexo and have blocks this node still has
/// to verify, i.e. a height above both the assume-utreexo snapshot and
/// [validatedHeight] (+ [margin]). A node that is behind the network tip
/// is still useful for the blocks it has: the utreexod peer that unblocked
/// mainnet (2026-10-25) was ~2 600 blocks behind the tip and served 30 000
/// needed proofs. An earlier "within 2016 blocks of the tip" rule wrongly
/// rejected it.
UtreexoCandidateVerdict judgeUtreexoCandidate(
  PeerProbe probe, {
  required BitcoinNetwork network,
  int validatedHeight = 0,
  int margin = 144,
  bool inSelection = false,
  int? consensusTip,
}) {
  if (!probe.answered) return UtreexoCandidateVerdict.unreachable;
  if (!probe.servesUtreexo) return UtreexoCandidateVerdict.notUtreexo;
  // While florestad selects the chain it waits for every peer to answer
  // `getheaders`; a utreexod that is behind ignores those (it only answers
  // once in sync, utreexod v0.5.2 `server.go` `OnGetHeaders`), so adding
  // one then keeps the node there.
  // Added once selection is over, it serves the proofs as before.
  if (inSelection &&
      consensusTip != null &&
      probe.height + margin < consensusTip) {
    return UtreexoCandidateVerdict.behindDuringSelection;
  }
  final needed = [network.assumeUtreexoHeight, validatedHeight].reduce(max);
  if (probe.height <= needed + margin) {
    return UtreexoCandidateVerdict.tooFarBehind;
  }
  return UtreexoCandidateVerdict.usable;
}

enum UtreexoCandidateVerdict {
  usable,
  notUtreexo,
  tooFarBehind,

  /// Usable later: behind the tip while the node selects its chain.
  behindDuringSelection,
  unreachable,
}

/// Where florestad is in its start-up chain selection, read from its own
/// output. Every start runs the selector (`running_ctx.rs` `run`), which logs
/// [selectionStartLine]; when it returns, the node logs one of
/// [selectionEndLines] (backfill, catch-up, sync node; v0.9.1, the same
/// strings on master `3a47993`).
enum SelectionPhase { selecting, done, unknown }

const selectionStartLine = 'Starting IBD, selecting the best chain';
const selectionEndLines = [
  'Starting backfill task...',
  'Catching up with the network...',
  'Starting sync node...',
];

/// The phase from daemon output, oldest line first. [SelectionPhase.unknown]
/// when the start line is not in [lines] (an adopted node's output goes to
/// debug.log only, or the buffer dropped it).
SelectionPhase selectionPhaseFromLogs(List<String> lines) {
  for (var i = lines.length - 1; i >= 0; i--) {
    final l = lines[i];
    if (selectionEndLines.any(l.contains)) return SelectionPhase.done;
    if (l.contains(selectionStartLine)) return SelectionPhase.selecting;
  }
  return SelectionPhase.unknown;
}

/// Whether florestad is selecting its chain now. The node's own output
/// decides when the app has it; otherwise: all headers in, nothing
/// validated since the app first saw this process ([validatedAtStart]),
/// and not simply synced.
///
/// The rules that unblock selection used to test "validated == 0" instead.
/// That is only true before the first validated block: after a restart of a
/// node that had validated some, selection could hang and nothing helped
/// (mainnet, 2026-10-28).
bool inChainSelection({
  required SelectionPhase logged,
  required int validatedHeight,
  required int? validatedAtStart,
  required int headerHeight,
  required int? peerTip,
  int tolerance = 6,
}) => switch (logged) {
  SelectionPhase.selecting => true,
  SelectionPhase.done => false,
  SelectionPhase.unknown =>
    validatedAtStart != null &&
        validatedHeight <= validatedAtStart &&
        peerTip != null &&
        headerHeight + tolerance >= peerTip &&
        validatedHeight + tolerance < headerHeight,
};

/// DNS seeds that list Utreexo nodes, as upstream Floresta master uses them
/// (`floresta-chain` `chainparams.rs` `get_chain_dns_seeds` @ 3a47993,
/// 2026-10-22). florestad v0.9.1's own Utreexo seeds (`seed.dlsouza.lol`,
/// `x1009.seed.calvinkim.info`, `x1009.seed.bitcoin.luisschwab.com`) no
/// longer answer (checked 2026-10-25), so v0.9.1 cannot find Utreexo peers
/// by itself. The `x1000` prefix asks the seed for NODE_UTREEXO nodes only.
const utreexoSeedFilter = 'x1000';
const utreexoSeeds = <BitcoinNetwork, List<String>>{
  BitcoinNetwork.bitcoin: ['bitcoin.seed.dlsouza.lol'],
  BitcoinNetwork.signet: ['signet.seed.dlsouza.lol'],
};

/// Fixed candidates, used besides the seeds. Each entry answered a v1
/// handshake with the Utreexo bit and a height past the snapshot on the
/// date given; it is re-checked by handshake before every use, so a stale
/// entry is skipped, never trusted.
class CuratedUtreexoPeer {
  const CuratedUtreexoPeer(this.address, {required this.verified, this.note});
  final String address;
  final String verified;
  final String? note;
}

const curatedUtreexoPeers = <BitcoinNetwork, List<CuratedUtreexoPeer>>{
  BitcoinNetwork.bitcoin: [
    CuratedUtreexoPeer(
      '161.97.178.61:8333',
      verified: '2026-10-25',
      note: 'utreexod 0.5.2, also listed by bitcoin.seed.dlsouza.lol',
    ),
  ],
};

/// Whether the app should look for Utreexo peers for the node now.
/// Only for a node this app runs, on a network with Utreexo peers to find,
/// once it has peers at all (headers flowing), while it has fewer than
/// [wanted] *verified* Utreexo peers ([utreexoPeers] counts only those),
/// and at most once per [every].
bool shouldSeekUtreexoPeers({
  required bool ownNode,
  required BitcoinNetwork network,
  required int connectedPeers,
  required int utreexoPeers,
  required DateTime now,
  DateTime? lastAttempt,
  int wanted = 2,
  Duration every = const Duration(minutes: 2),
}) {
  if (!ownNode) return false;
  if (utreexoSeeds[network] == null && curatedUtreexoPeers[network] == null) {
    return false;
  }
  if (connectedPeers == 0 || utreexoPeers >= wanted) return false;
  return lastAttempt == null || now.difference(lastAttempt) >= every;
}

/// Utreexo peers to disconnect because validation is stuck.
///
/// florestad v0.9.1 asks a random Utreexo peer for each block's proof and
/// validates blocks in order, so one peer that never answers stalls
/// everything. Observed on mainnet (2026-10-25): a `/bridge:0.1.3/` peer
/// ignored 130 of 130 `getuproof` requests while a utreexod peer answered
/// 88 of 88; validation moved past the snapshot only after the bridge left.
///
/// Returns the connected Utreexo peers the app has not verified, but only
/// when validation has not advanced for [after] and at least one verified
/// Utreexo peer is connected to take over. Disconnecting is reversible.
List<String> stalledUtreexoPeersToDrop({
  required List<({String address, bool utreexo})> connected,
  required Set<String> verified,
  required Duration? stalledFor,
  Duration after = const Duration(minutes: 3),
}) {
  if (stalledFor == null || stalledFor < after) return const [];
  final utreexo = [
    for (final p in connected)
      if (p.utreexo) p.address,
  ];
  if (!utreexo.any(verified.contains)) return const [];
  return [
    for (final a in utreexo)
      if (!verified.contains(a)) a,
  ];
}

/// Florestad v0.9.1 can stay forever in its "checking if our peers
/// agree" step after downloading all headers, without applying the
/// assume-utreexo snapshot: it waits for *every* peer to answer with no new
/// headers and re-asks them every few minutes (`chain_selector_ctx.rs`
/// `empty_headers_message`, `LookingForForks`), so one peer that never
/// gives that answer, or a block found meanwhile, keeps it there. Observed
/// on mainnet 2026-10-25 (twice); a restart on the same data applied the
/// snapshot in 34 s.
///
/// Tracks how long the node has had all headers (within [tolerance] of the
/// peers' tip, past the snapshot) while still selecting its chain. New headers keep
/// arriving while it is stuck, so "time since the last height change" is
/// not the right measure (the first version of this rule used it and never
/// fired).
class StuckSelectionTracker {
  StuckSelectionTracker({
    this.tolerance = 6,
    this.stuckFor = const Duration(minutes: 5),
    this.every = const Duration(minutes: 15),
    this.maxRestarts = 3,
  });

  final int tolerance;
  final Duration stuckFor;
  final Duration every;
  final int maxRestarts;

  DateTime? _headersCompleteSince;
  final restarts = <DateTime>[];

  /// Feeds one status sample; true when the node should be restarted now
  /// (the restart is then recorded).
  ///
  /// [inSelection] comes from [inChainSelection]. [blockingPeers] is how many
  /// peers the app is about to drop for holding selection up
  /// ([forkPeersToDrop]): dropping them is tried first, so the 5-minute
  /// window starts over after each drop and a restart only comes when
  /// selection is still stuck with no one left to drop.
  bool sample({
    required bool ownNode,
    required int snapshotHeight,
    required bool inSelection,
    required int headerHeight,
    required int? peerTip,
    required DateTime now,
    int blockingPeers = 0,
  }) {
    final waiting =
        ownNode &&
        snapshotHeight > 0 &&
        inSelection &&
        headerHeight > snapshotHeight &&
        peerTip != null &&
        headerHeight + tolerance >= peerTip;
    if (!waiting) {
      _headersCompleteSince = null;
      return false;
    }
    if (blockingPeers > 0) {
      _headersCompleteSince = now;
      return false;
    }
    final since = _headersCompleteSince ??= now;
    if (now.difference(since) < stuckFor) return false;
    if (restarts.length >= maxRestarts) return false;
    if (restarts.isNotEmpty && now.difference(restarts.last) < every) {
      return false;
    }
    restarts.add(now);
    _headersCompleteSince = null; // give the restarted node a fresh window
    return true;
  }
}

/// Peers to disconnect because they are on another chain.
///
/// florestad v0.9.1 applies the assume-utreexo snapshot only after *every*
/// peer answers "no new headers" (`chain_selector_ctx.rs`
/// `LookingForForks`). A peer on a different chain keeps sending its own
/// headers, so that never happens. Observed on mainnet 2026-10-25, twice:
/// a Knots peer reporting 978 945 (5 858 *above* every other peer) kept it
/// looping for 12 minutes, across a restart, and disconnecting it let the
/// snapshot apply 9 s later; in the next run a Knots peer reporting 961 639
/// (11 460 *below*) did the same, and disconnecting it took 5 s.
///
/// While the node has all headers ([headerHeight] within [tolerance] of
/// [consensusTip]) and is selecting its chain ([inSelection], see
/// [inChainSelection]), returns the peers whose reported height is more
/// than [awayBy] blocks from the consensus, in either direction. That
/// includes a utreexod that is behind: it ignores `getheaders` until it is
/// in sync, so it holds selection as surely as a fork does. A peer dropped
/// here may reconnect later, once selection is over.
List<String> forkPeersToDrop({
  required List<({String address, int height})> peers,
  required int? consensusTip,
  required int headerHeight,
  required bool inSelection,
  required int snapshotHeight,
  int tolerance = 6,
  int awayBy = 144,
}) {
  if (consensusTip == null || !inSelection || snapshotHeight == 0) {
    return const [];
  }
  if (headerHeight <= snapshotHeight) return const [];
  if (headerHeight + tolerance < consensusTip) return const [];
  return [
    for (final p in peers)
      if ((p.height - consensusTip).abs() > awayBy) p.address,
  ];
}
