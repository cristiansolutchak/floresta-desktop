import '../../../shared/widgets/common.dart';
import '../domain/node_process_state.dart';
import '../domain/node_readiness.dart';
import '../domain/node_status.dart';
import '../domain/verification_breakdown.dart';

typedef StatusLabel = ({String label, String? caption, Tone tone});

/// Maps node state to wording. Kept apart from widgets so the exact
/// user-facing text for each state is unit-tested.
abstract final class StatusLabels {
  static StatusLabel process(NodeStatus s) => switch (s.process) {
    ProcessIdle() when s.isExternallyManaged => (
      label: 'Started outside this app',
      caption: 'This app can stop it over RPC, but cannot restart it.',
      tone: Tone.info,
    ),
    ProcessIdle() => (label: 'Not running', caption: null, tone: Tone.neutral),
    ProcessStarting() => (label: 'Starting', caption: null, tone: Tone.warning),
    ProcessRunning(:final pid) => (
      label: 'Running',
      caption: 'Process $pid',
      tone: Tone.success,
    ),
    ProcessAdopted(:final pid) => (
      label: 'Running',
      caption:
          'Process $pid, reconnected after the app restarted. Output since '
          'then is in debug.log.',
      tone: Tone.success,
    ),
    ProcessStopping() => (
      label: 'Stopping',
      caption: 'This can take up to 15 seconds.',
      tone: Tone.warning,
    ),
    ProcessStopped() => (label: 'Stopped', caption: null, tone: Tone.neutral),
    ProcessCrashed(:final exitCode) => (
      label: 'Exited unexpectedly',
      caption: exitCode == null ? null : 'Exit code $exitCode',
      tone: Tone.danger,
    ),
    ProcessFailedToStart(:final reason) => (
      label: 'Failed to start',
      caption: reason,
      tone: Tone.danger,
    ),
  };

  /// One or two words for the header bar tag and the Overview banner
  /// ("Syncing", "Synced"). Derived from the same readiness as every other
  /// label (SYNC-08).
  static StatusLabel short(NodeReadiness r, NodeStatus s) {
    if (s.api != ApiReachability.reachable) {
      return switch (s.process) {
        ProcessStarting() || ProcessRunning() || ProcessAdopted() => (
          label: 'Starting',
          caption: null,
          tone: Tone.warning,
        ),
        ProcessStopping() => (
          label: 'Stopping',
          caption: null,
          tone: Tone.warning,
        ),
        ProcessCrashed() || ProcessFailedToStart() => (
          label: 'Error',
          caption: null,
          tone: Tone.danger,
        ),
        ProcessIdle() || ProcessStopped() => (
          label: 'Stopped',
          caption: null,
          tone: Tone.neutral,
        ),
      };
    }
    if (r.wrongNetwork) {
      return (label: 'Wrong network', caption: null, tone: Tone.danger);
    }
    if (r.stalledFor != null) {
      return (label: 'Stalled', caption: null, tone: Tone.danger);
    }
    return switch (r.stage) {
      ReadinessStage.stopped => (
        label: 'Stopped',
        caption: null,
        tone: Tone.neutral,
      ),
      ReadinessStage.starting => (
        label: 'Starting',
        caption: null,
        tone: Tone.warning,
      ),
      ReadinessStage.findingPeers ||
      ReadinessStage.downloadingHeaders ||
      ReadinessStage.validatingBlocks => (
        label: 'Syncing',
        caption: null,
        tone: Tone.warning,
      ),
      ReadinessStage.behindNetwork => (
        label: 'Behind',
        caption: null,
        tone: Tone.danger,
      ),
      ReadinessStage.ready => (
        label: 'Synced',
        caption: null,
        tone: Tone.success,
      ),
    };
  }

  /// The node is doing work right now (syncing, starting, stopping), so its
  /// status icon moves. Stalled, behind, stopped, synced and errors are
  /// still: nothing is progressing, or it is done.
  static bool isActive(StatusLabel short) =>
      const {'Syncing', 'Starting', 'Stopping'}.contains(short.label);

  static StatusLabel api(NodeStatus s) => switch (s.api) {
    ApiReachability.unknown => (
      label: 'Checking',
      caption: null,
      tone: Tone.neutral,
    ),
    ApiReachability.reachable => (
      label: 'Reachable',
      caption: s.uptime == null ? null : 'Up ${formatDuration(s.uptime!)}',
      tone: Tone.success,
    ),
    ApiReachability.unreachable when s.process.isActive => (
      label: 'Waiting for the node',
      caption: 'The API comes up a few seconds after start.',
      tone: Tone.warning,
    ),
    ApiReachability.unreachable => (
      label: 'Not reachable',
      caption: null,
      tone: Tone.neutral,
    ),
  };

  static StatusLabel readiness(NodeReadiness r, NodeStatus s) {
    if (r.wrongNetwork) {
      return (
        label: 'Wrong network',
        caption:
            'The node answering here follows '
            '${s.chain?.network?.label ?? s.chain?.chain}, not the network '
            'selected in Settings.',
        tone: Tone.danger,
      );
    }
    final chain = s.chain;
    final base = switch (r.stage) {
      ReadinessStage.stopped => (
        label: 'Stopped',
        caption: null,
        tone: Tone.neutral,
      ),
      ReadinessStage.starting => (
        label: 'Starting',
        caption: 'Waiting for the node API.',
        tone: Tone.warning,
      ),
      ReadinessStage.findingPeers => (
        label: 'Finding peers',
        caption: 'Connecting to other Bitcoin nodes.',
        tone: Tone.warning,
      ),
      ReadinessStage.downloadingHeaders => (
        label: 'Downloading block headers',
        caption: headersCaption(r, s),
        tone: Tone.warning,
      ),
      ReadinessStage.behindNetwork => (
        label: 'Behind the network',
        caption: chain == null || r.peerTip == null
            ? null
            : 'Headers stop at ${formatInt(chain.headerHeight)} while peers '
                  'report ${formatInt(r.peerTip!)}.',
        tone: Tone.danger,
      ),
      ReadinessStage.validatingBlocks when r.missingUtreexoPeers => (
        label: 'Waiting for Utreexo peers',
        caption: verifiedCaption(s, r),
        tone: Tone.warning,
      ),
      ReadinessStage.validatingBlocks => (
        label: 'Verifying blocks',
        caption: verifiedCaption(s, r),
        tone: Tone.warning,
      ),
      ReadinessStage.ready => switch (r.electrum) {
        ElectrumCheck.ok => (
          label: 'Ready',
          caption: 'Synced; wallets can connect.',
          tone: Tone.success,
        ),
        ElectrumCheck.wrongNetwork => (
          label: 'Synced, Electrum mismatch',
          caption: 'The Electrum server reports another network.',
          tone: Tone.danger,
        ),
        ElectrumCheck.unreachable => (
          label: 'Synced, Electrum not answering',
          caption: 'Wallets cannot connect yet.',
          tone: Tone.warning,
        ),
        ElectrumCheck.unknown => (
          label: 'Synced',
          caption: 'Checking the Electrum server…',
          tone: Tone.success,
        ),
      },
    };
    final stalled = r.stalledFor;
    if (stalled == null) return base;
    return (
      label: '${base.label} (no progress)',
      caption: 'Nothing has changed for ${formatDuration(stalled)}.',
      tone: Tone.danger,
    );
  }

  /// The blockchain cell. Derived from the same [NodeReadiness] as every
  /// other sync label, so the screens cannot disagree (SYNC-08; Mandacaru
  /// #103 had its notification and screen drift apart).
  static StatusLabel sync(NodeReadiness r, NodeStatus s) {
    final chain = s.chain;
    if (chain == null) {
      return (
        label: 'Unknown',
        caption: 'Needs the node API',
        tone: Tone.neutral,
      );
    }
    return switch (r.stage) {
      ReadinessStage.ready => (
        label: 'Synced',
        caption: 'Height ${formatInt(chain.validatedHeight)}',
        tone: Tone.success,
      ),
      ReadinessStage.behindNetwork => (
        label: 'Behind the network',
        caption: r.peerTip == null
            ? null
            : '${formatInt(chain.headerHeight)} of about '
                  '${formatInt(r.peerTip!)} (from peers)',
        tone: Tone.danger,
      ),
      ReadinessStage.validatingBlocks => (
        label: 'Verifying blocks',
        caption: verifiedCaption(s, r),
        tone: Tone.warning,
      ),
      ReadinessStage.stopped ||
      ReadinessStage.starting ||
      ReadinessStage.findingPeers ||
      ReadinessStage.downloadingHeaders => (
        label: 'Downloading headers',
        caption: headersCaption(r, s),
        tone: Tone.warning,
      ),
    };
  }

  /// "N headers (about X% of the network, estimated from peers)". The
  /// percentage is shown only with a peer-reported tip and always labelled
  /// as an estimate (SYNC-06).
  static String? headersCaption(NodeReadiness r, NodeStatus s) {
    final chain = s.chain;
    if (chain == null) return null;
    final headers = '${formatInt(chain.headerHeight)} headers';
    final tip = r.peerTip;
    if (tip == null || tip <= 0 || chain.headerHeight == 0) return headers;
    final share = (chain.headerHeight / tip).clamp(0.0, 1.0);
    return '$headers (about ${(share * 100).floor()}% of the network, '
        'estimated from peers)';
  }

  /// "X of Y blocks since the snapshot verified by this node": never counts
  /// the assumed snapshot as verified (SYNC-02).
  static String? verifiedCaption(NodeStatus s, [NodeReadiness? r]) {
    final chain = s.chain;
    final network = chain?.network;
    if (chain == null || network == null) return null;
    final b = VerificationBreakdown.of(
      chain,
      network,
      snapshotHeight: r?.snapshotHeight,
    );
    final scope = b.snapshotApplied ? 'blocks after the snapshot' : 'blocks';
    return '${formatInt(b.verifiedByNode)} of ${formatInt(b.toVerify)} '
        '$scope verified by this node';
  }
}

String formatPercent(double fraction) =>
    '${(fraction * 100).toStringAsFixed(fraction >= 0.999 ? 1 : 2)}%';

String formatInt(int n) {
  final s = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

String formatDuration(Duration d) {
  if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m';
  return '${d.inSeconds}s';
}
