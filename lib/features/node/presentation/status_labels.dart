import '../../../shared/widgets/common.dart';
import '../domain/blockchain_info.dart';
import '../domain/node_process_state.dart';
import '../domain/node_status.dart';

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
    ProcessStopping() => (
      label: 'Stopping',
      caption: 'This can take up to 15 seconds.',
      tone: Tone.warning,
    ),
    ProcessStopped() => (label: 'Stopped', caption: null, tone: Tone.neutral),
    ProcessCrashed(:final exitCode) => (
      label: 'Exited unexpectedly',
      caption: 'Exit code $exitCode',
      tone: Tone.danger,
    ),
    ProcessFailedToStart(:final reason) => (
      label: 'Failed to start',
      caption: reason,
      tone: Tone.danger,
    ),
  };

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

  static StatusLabel sync(NodeStatus s) {
    final chain = s.chain;
    if (chain == null) {
      return (
        label: 'Unknown',
        caption: 'Needs the node API',
        tone: Tone.neutral,
      );
    }
    return switch (chain.phase) {
      SyncPhase.initialDownload => (
        label: 'Initial sync',
        caption: '${formatPercent(chain.verificationProgress)} (estimate)',
        tone: Tone.warning,
      ),
      SyncPhase.catchingUp => (
        label: 'Catching up',
        caption: '${chain.blocksBehind} blocks behind',
        tone: Tone.warning,
      ),
      SyncPhase.synced => (
        label: 'Synced',
        caption: 'Height ${formatInt(chain.validatedHeight)}',
        tone: Tone.success,
      ),
    };
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
