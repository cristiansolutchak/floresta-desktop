import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/dash_tokens.dart';
import '../../../core/logging/log_buffer.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/dash.dart';
import '../domain/peer.dart';
import 'node_controller.dart';

/// The Logs buttons of the header bar, banner and Sync toolbar.
Future<void> showLogsDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _DashDialog(title: 'Daemon output', child: LogsView()),
);

/// The View Peers buttons of the Overview and Sync screens.
Future<void> showPeersDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => _DashDialog(
    title: 'Peers',
    child: Consumer(
      builder: (context, ref, _) {
        final peers = ref.watch(nodeControllerProvider.select((s) => s.peers));
        return switch (peers) {
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
          final list => SingleChildScrollView(child: PeerTable(list)),
        };
      },
    ),
  ),
);

class _DashDialog extends StatelessWidget {
  const _DashDialog({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.dash;
    return Dialog(
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(2),
        side: BorderSide(color: t.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(title, style: DashText.cardTitle(context)),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Flexible(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class PeerTable extends StatelessWidget {
  const PeerTable(this.peers, {super.key});
  final List<Peer> peers;

  @override
  Widget build(BuildContext context) {
    final head = DashText.small(context);
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
              border: Border(top: BorderSide(color: context.dash.border)),
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
          style: mono
              ? monoStyle(context, size: 12)
              : DashText.body(context, color: context.dash.textPrimary),
        ),
      );
}

/// Daemon output, newest at the bottom. Extended keys are redacted by
/// [LogBuffer] before they get here.
class LogsView extends ConsumerStatefulWidget {
  const LogsView({super.key});

  @override
  ConsumerState<LogsView> createState() => _LogsViewState();
}

class _LogsViewState extends ConsumerState<LogsView> {
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
    if (lines.isEmpty) {
      return const EmptyState(
        icon: Icons.notes,
        title: 'No output yet',
        message:
            'Output from a node started by this app appears here. '
            'Extended public keys are redacted.',
      );
    }
    final t = context.dash;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: CopyButton(
            text: lines.map((l) => l.text).join('\n'),
            tooltip: 'Copy log (extended keys are redacted)',
          ),
        ),
        Flexible(
          child: Container(
            height: 420,
            color: t.subtle,
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
                      LogSource.stderr => t.danger,
                      LogSource.app => t.textMuted,
                      LogSource.stdout => t.textPrimary,
                    },
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
