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
import '../domain/node_status.dart';
import '../domain/peer.dart';
import 'node_controller.dart';
import 'status_labels.dart';

class NodeOverviewPage extends ConsumerWidget {
  const NodeOverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(nodeControllerProvider);
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
        if (settings.network.isMainnet) ...[
          const Notice(
            tone: Tone.info,
            title: 'Mainnet',
            message: 'This node follows the real Bitcoin network.',
          ),
          const SizedBox(height: 16),
        ],
        _StatusStrip(status),
        const SizedBox(height: 16),
        _SyncPanel(status),
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
  const _StatusStrip(this.status);
  final NodeStatus status;

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
          cell('Blockchain', StatusLabels.sync(status)),
        ],
      ),
    );
  }
}

class _SyncPanel extends StatelessWidget {
  const _SyncPanel(this.status);
  final NodeStatus status;

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
    final progress = chain.verificationProgress;
    return Panel(
      title: 'Synchronization',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            label: 'Validation progress ${formatPercent(progress)}',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: context.colors.border,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${formatPercent(progress)} validated. Estimated from block '
            'timestamps.',
            style: context.text.bodySmall,
          ),
          const SizedBox(height: 14),
          KeyValueRow('Validated height', formatInt(chain.validatedHeight)),
          KeyValueRow('Best known header', formatInt(chain.headerHeight)),
          KeyValueRow(
            'Initial block download',
            chain.initialBlockDownload ? 'In progress' : 'Complete',
          ),
          KeyValueRow('Latest block time', _formatTime(chain.tipTime)),
          KeyValueRow('Best block hash', chain.bestBlockHash, mono: true),
          KeyValueRow('Chain state on disk', formatBytes(chain.sizeOnDisk)),
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
