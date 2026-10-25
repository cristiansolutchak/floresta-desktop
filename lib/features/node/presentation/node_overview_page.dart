import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/errors/failure.dart';
import '../../../core/logging/log_buffer.dart';
import '../../../shared/widgets/common.dart';
import '../../installation/domain/next_action.dart';
import '../../installation/presentation/installation_providers.dart';
import '../../settings/presentation/settings_controller.dart';
import '../domain/node_process_state.dart';
import '../domain/node_readiness.dart';
import '../domain/node_status.dart';
import '../domain/verification_breakdown.dart';
import '../domain/peer.dart';
import '../domain/preflight.dart';
import 'node_controller.dart';
import 'status_labels.dart';

class NodeOverviewPage extends ConsumerWidget {
  const NodeOverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(nodeControllerProvider);
    final readiness = ref.watch(nodeReadinessProvider);
    final settings = ref.watch(settingsControllerProvider);
    final next = ref.watch(nextActionProvider);
    final installed =
        next.value is OpenNodeManagement ||
        next.value is ConfigureNode ||
        next.value is UpdateFloresta;

    return PageBody(
      children: [
        PageHeader(
          title: 'Node',
          subtitle:
              '${settings.network.label} · RPC 127.0.0.1:'
              '${settings.effectiveRpcPort}',
          actions: _actions(context, ref, status, installed),
        ),
        if (!installed && next.hasValue && !status.isExternallyManaged) ...[
          Notice(
            tone: Tone.warning,
            title: 'Floresta is not ready to run',
            message:
                'The florestad executable was not found or could not be '
                'used.',
            action: OutlinedButton(
              onPressed: () => context.go('/installation'),
              child: const Text('Open Installation'),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (status.process case final ProcessCrashed crashed) ...[
          _CrashNotice(crashed),
          const SizedBox(height: 16),
        ],
        if (readiness.stalledFor case final idle?) ...[
          Notice(
            tone: Tone.danger,
            title: 'The node is not making progress',
            message:
                'Heights have not changed for ${formatDuration(idle)}. '
                '${readiness.missingUtreexoPeers
                    ? 'Floresta needs at least $minUtreexoPeers peers that serve Utreexo proofs to verify new blocks, and has ${status.peers?.where((p) => p.isReady && p.supportsUtreexo).length ?? 0} right now. It keeps looking; this depends on how many such peers the network has, not on your setup.'
                    : (status.peers?.where((p) => p.isReady).length ?? 0) == 0
                    ? 'It has no connected peers: check your internet connection or firewall.'
                    : 'It has peers, so they may not be serving the data it needs; the log below may say why.'}',
          ),
          const SizedBox(height: 16),
        ],
        if (status.disk case final disk? when disk.alert != null) ...[
          Notice(
            tone: disk.alert == PreflightSeverity.blocking
                ? Tone.danger
                : Tone.warning,
            title: disk.alert == PreflightSeverity.blocking
                ? 'The disk is almost full'
                : 'Disk space is running low',
            message:
                'Only ${formatBytes(disk.freeBytes!)} free where Floresta keeps '
                'its data. ${disk.alert == PreflightSeverity.blocking ? 'Stop the node and free up space, or it may fail.' : 'Syncing may stop if the disk fills up.'}',
          ),
          const SizedBox(height: 16),
        ],
        for (final w in status.preflightWarnings) ...[
          Notice(
            tone: Tone.warning,
            title: w.title,
            message: [w.message, ?w.recovery].join(' '),
          ),
          const SizedBox(height: 16),
        ],
        if (settings.network.isMainnet) ...[
          const Notice(
            tone: Tone.info,
            title: 'Mainnet',
            message: 'This node follows the real Bitcoin network.',
          ),
          const SizedBox(height: 16),
        ] else ...[
          Notice(
            tone: Tone.warning,
            title: '${settings.network.label}: test network',
            message:
                'Coins on this network have no value. Switch to Mainnet in '
                'Settings to follow the real Bitcoin network.',
          ),
          const SizedBox(height: 16),
        ],
        _StatusStrip(status, readiness),
        const SizedBox(height: 16),
        _SyncPanel(status, readiness),
        const SizedBox(height: 16),
        _PeersPanel(status),
        const SizedBox(height: 16),
        const _LogsPanel(),
      ],
    );
  }

  List<Widget> _actions(
    BuildContext context,
    WidgetRef ref,
    NodeStatus status,
    bool installed,
  ) {
    final controller = ref.read(nodeControllerProvider.notifier);
    Future<void> run(Future<dynamic> Function() action) async {
      final result = await action();
      if (!context.mounted) return;
      result.fold((Failure f) => showFailure(context, f), (_) {});
    }

    return [
      IconButton(
        tooltip: 'Refresh',
        onPressed: controller.refresh,
        icon: const Icon(Icons.refresh, size: 18),
      ),
      if (status.canStop && !status.isExternallyManaged)
        OutlinedButton(
          onPressed: () async {
            final ok = await confirm(
              context,
              title: 'Restart the node?',
              message:
                  'Floresta will shut down cleanly and start again. '
                  'Connected wallets will briefly disconnect.',
              confirmLabel: 'Restart',
            );
            if (ok) await run(controller.restart);
          },
          child: const Text('Restart'),
        ),
      if (status.canStop)
        OutlinedButton(
          onPressed: () async {
            final ok = await confirm(
              context,
              title: 'Stop the node?',
              message: status.isExternallyManaged
                  ? 'This node was started outside this app. It will be '
                        'asked to shut down over RPC and this app will not '
                        'be able to start it the same way.'
                  : 'Floresta will shut down cleanly. Sync progress is '
                        'kept and resumes on the next start.',
              confirmLabel: 'Stop',
            );
            if (ok) await run(controller.stop);
          },
          child: const Text('Stop'),
        ),
      if (status.canStart)
        FilledButton.icon(
          onPressed: installed ? () => run(controller.start) : null,
          icon: const Icon(Icons.play_arrow_rounded, size: 18),
          label: const Text('Start node'),
        ),
    ];
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip(this.status, this.readiness);
  final NodeStatus status;
  final NodeReadiness readiness;

  @override
  Widget build(BuildContext context) {
    Widget cell(String heading, StatusLabel l) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(heading.toUpperCase(), style: context.text.labelSmall),
            const SizedBox(height: 8),
            StatusIndicator(label: l.label, caption: l.caption, tone: l.tone),
          ],
        ),
      ),
    );

    return Panel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          cell('Process', StatusLabels.process(status)),
          cell('Node API', StatusLabels.api(status)),
          cell('Blockchain', StatusLabels.sync(readiness, status)),
          cell('Readiness', StatusLabels.readiness(readiness, status)),
        ],
      ),
    );
  }
}

class _SyncPanel extends StatelessWidget {
  const _SyncPanel(this.status, this.readiness);
  final NodeStatus status;
  final NodeReadiness readiness;

  @override
  Widget build(BuildContext context) {
    final chain = status.chain;
    if (chain == null) {
      return const Panel(
        title: 'Synchronization',
        child: EmptyState(
          icon: Icons.sync_disabled,
          title: 'No chain data yet',
          message:
              'Sync details appear here once the node API is '
              'reachable.',
        ),
      );
    }
    final network = chain.network;
    final b = network == null
        ? null
        : VerificationBreakdown.of(
            chain,
            network,
            snapshotHeight: readiness.snapshotHeight,
          );
    final fraction = b?.fraction;
    return Panel(
      title: 'Synchronization',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Only blocks this node checked itself count as verified; the
          // assumed snapshot is shown separately (SYNC-02).
          if (b != null && fraction != null && b.verifiedByNode > 0) ...[
            Semantics(
              label:
                  'Verified by this node: ${formatPercent(fraction)} of '
                  '${b.snapshotApplied ? 'blocks after the snapshot' : 'blocks'}',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 6,
                  backgroundColor: context.colors.border,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${formatPercent(fraction)} of the '
              '${b.snapshotApplied ? 'blocks after the snapshot' : 'blocks'} '
              'verified by this node.',
              style: context.text.bodySmall,
            ),
            const SizedBox(height: 14),
          ],
          KeyValueRow('Block headers known', formatInt(chain.headerHeight)),
          if (status.disk case final disk?)
            KeyValueRow(
              'Data folder',
              [
                if (disk.usedBytes case final u?) '${formatBytes(u)} used',
                if (disk.freeBytes case final f?) '${formatBytes(f)} free',
              ].join(' · '),
            ),
          KeyValueRow(
            'Verified by this node',
            b == null
                ? 'Block ${formatInt(chain.validatedHeight)} (network unknown)'
                : b.verifiedByNode == 0
                ? 'None yet'
                : 'Blocks ${formatInt(b.acceptedUpTo + 1)} to '
                      '${formatInt(chain.validatedHeight)} '
                      '(${formatInt(b.verifiedByNode)})',
          ),
          if (b != null && b.snapshotApplied)
            KeyValueRow(
              'Accepted from snapshot',
              'Blocks 0 to ${formatInt(b.acceptedUpTo)}: the Utreexo state '
                  'built into Floresta, not yet re-checked here. Floresta '
                  're-checks it in the background; version 0.9.1 does not '
                  'report that progress.',
            )
          else if (b != null && b.snapshotHeight > 0 && b.verifiedByNode == 0)
            KeyValueRow(
              'Snapshot',
              'Will be used at block ${formatInt(b.snapshotHeight)} once the '
                  'headers reach it.',
            ),
          if (b != null && b.scriptsSkippedUpTo > 0)
            KeyValueRow(
              'Signature checks',
              'Skipped up to block ${formatInt(b.scriptsSkippedUpTo)} '
                  '(assume-valid, as in Bitcoin Core)',
            ),
          KeyValueRow(
            'Initial block download',
            chain.initialBlockDownload ? 'In progress' : 'Complete',
          ),
          KeyValueRow('Latest block time', _formatTime(chain.tipTime)),
          KeyValueRow('Best block hash', chain.bestBlockHash, mono: true),
          if (chain.sizeOnDisk case final size?)
            KeyValueRow('Chain state on disk', formatBytes(size)),
          if (chain.network == null) KeyValueRow('Reported chain', chain.chain),
          for (final w in chain.warnings) ...[
            const SizedBox(height: 8),
            Notice(tone: Tone.warning, title: 'Node warning', message: w),
          ],
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}';
  }
}

class _PeersPanel extends StatelessWidget {
  const _PeersPanel(this.status);
  final NodeStatus status;

  @override
  Widget build(BuildContext context) {
    final peers = status.peers;
    final ready = peers?.where((p) => p.isReady).length ?? 0;
    return Panel(
      title: 'Peers',
      trailing: peers == null
          ? null
          : Text(
              '$ready ready · ${peers.length} total',
              style: context.text.bodySmall,
            ),
      child: switch (peers) {
        null => const EmptyState(
          icon: Icons.hub_outlined,
          title: 'No peer data',
          message:
              'Peer connections appear here once the node API is '
              'reachable.',
        ),
        [] => const EmptyState(
          icon: Icons.hub_outlined,
          title: 'No peers yet',
          message:
              'Floresta is looking for peers. This usually takes less '
              'than a minute.',
        ),
        final list => _PeerTable(list),
      },
    );
  }
}

class _PeerTable extends StatelessWidget {
  const _PeerTable(this.peers);
  final List<Peer> peers;

  @override
  Widget build(BuildContext context) {
    TextStyle? head = context.text.labelSmall;
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(2.2),
        1: FlexColumnWidth(1),
        2: FlexColumnWidth(1),
        3: FlexColumnWidth(1),
        4: FlexColumnWidth(2),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          children: [
            for (final h in ['ADDRESS', 'STATE', 'KIND', 'TRANSPORT', 'AGENT'])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(h, style: head),
              ),
          ],
        ),
        for (final p in peers)
          TableRow(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: context.colors.border)),
            ),
            children: [
              _cell(
                context,
                '${p.address}${p.inbound ? ' (in)' : ''}',
                mono: true,
              ),
              _cell(context, p.state),
              _cell(context, p.kind),
              _cell(context, p.transport),
              _cell(context, p.userAgent),
            ],
          ),
      ],
    );
  }

  Widget _cell(BuildContext context, String text, {bool mono = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Text(
          text,
          overflow: TextOverflow.ellipsis,
          style: mono ? monoStyle(context, size: 12) : context.text.bodyMedium,
        ),
      );
}

class _CrashNotice extends StatelessWidget {
  const _CrashNotice(this.crashed);
  final ProcessCrashed crashed;

  @override
  Widget build(BuildContext context) {
    final message = crashed.looksLikePortConflict
        ? 'The RPC or Electrum port is already in use. Another Floresta or '
              'Bitcoin Core instance may be running. Stop it, or change the '
              'RPC port in Settings.'
        : crashed.exitCode == null
        ? 'Floresta stopped on its own while this app was reconnected to it. '
              'Its debug.log in the data folder explains why.'
        : 'Floresta stopped with exit code ${crashed.exitCode}. The last log '
              'lines below usually explain why.';
    return Notice(
      tone: Tone.danger,
      icon: Icons.error_outline,
      title: 'The node exited unexpectedly',
      message: message,
    );
  }
}

class _LogsPanel extends ConsumerStatefulWidget {
  const _LogsPanel();

  @override
  ConsumerState<_LogsPanel> createState() => _LogsPanelState();
}

class _LogsPanelState extends ConsumerState<_LogsPanel> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lines = ref.watch(nodeLogsProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
    return Panel(
      title: 'Daemon output',
      trailing: lines.isEmpty
          ? null
          : CopyButton(
              text: lines.map((l) => l.text).join('\n'),
              tooltip: 'Copy log (extended keys are redacted)',
            ),
      child: lines.isEmpty
          ? const EmptyState(
              icon: Icons.notes,
              title: 'No output yet',
              message:
                  'Output from a node started by this app appears here. '
                  'Extended public keys are redacted.',
            )
          : Container(
              height: 240,
              decoration: BoxDecoration(
                color: context.colors.sidebar,
                borderRadius: BorderRadius.circular(6),
              ),
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(10),
                itemCount: lines.length,
                itemBuilder: (context, i) {
                  final l = lines[i];
                  return Text(
                    l.text,
                    style: monoStyle(context, size: 11.5).copyWith(
                      color: switch (l.source) {
                        LogSource.stderr => context.colors.danger,
                        LogSource.app => context.colors.muted,
                        LogSource.stdout => null,
                      },
                    ),
                  );
                },
              ),
            ),
    );
  }
}
