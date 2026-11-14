import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/dash_tokens.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/dash.dart';
import '../../settings/presentation/settings_controller.dart';
import '../domain/node_rpc_repository.dart';
import '../domain/node_status.dart';
import '../domain/peer.dart';
import '../domain/peer_address.dart';
import 'node_controller.dart';

/// Peers, with Add Peer. florestad's `getpeerinfo` has no ping or last-seen time, so
/// those slots show the connection kind and the peer's software instead.
class PeersPage extends ConsumerStatefulWidget {
  const PeersPage({super.key});

  @override
  ConsumerState<PeersPage> createState() => _PeersPageState();
}

class _PeersPageState extends ConsumerState<PeersPage> {
  var _details = true;

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(nodeControllerProvider);
    final peers = status.peers;
    final up = status.api == ApiReachability.reachable;
    final controller = ref.read(nodeControllerProvider.notifier);

    return DashPage(
      children: [
        DashPageHeader(
          asset: DashIcons.peersNav,
          title: 'Peers',
          subtitle: 'Peers are other nodes. More peers = smoother syncing.',
          help:
              'If active peers drop to 0, block synchronization will usually '
              'stop until new connections are made.',
          actions: [
            DashButton(
              'Refresh',
              style: DashButtonStyle.secondary,
              onPressed: controller.refresh,
            ),
            DashButton(
              'Add Peer',
              style: DashButtonStyle.primary,
              icon: Icons.add,
              tooltip: up ? null : 'Start the node first',
              onPressed: up ? () => _addPeer(context) : null,
            ),
          ],
        ),
        const SizedBox(height: 24),
        switch (peers) {
          null => DashCard(
            child: EmptyState(
              icon: Icons.hub_outlined,
              title: up ? 'Loading peers…' : 'The node is not running',
              message: up
                  ? 'Asking the node for its connections.'
                  : 'Peers appear here once the node is running.',
            ),
          ),
          [] => const DashCard(
            child: EmptyState(
              icon: Icons.hub_outlined,
              title: 'No peers yet',
              message:
                  'Floresta is looking for peers. This usually takes less '
                  'than a minute. You can also add one by address.',
            ),
          ),
          final list => _PeerGrid(list),
        },
        if (peers != null && peers.isNotEmpty) ...[
          const SizedBox(height: 24),
          DashCard(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InkWell(
                  onTap: () => setState(() => _details = !_details),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Show Details (Advanced)',
                            style: DashText.body(
                              context,
                              color: context.dash.textPrimary,
                              weight: FontWeight.w500,
                            ),
                          ),
                        ),
                        Icon(
                          _details ? Icons.expand_less : Icons.expand_more,
                          color: context.dash.textSecondary,
                          semanticLabel: _details
                              ? 'Hide details'
                              : 'Show details',
                        ),
                      ],
                    ),
                  ),
                ),
                if (_details) _PeerTable(peers),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _addPeer(BuildContext context) async {
    final network = ref.read(settingsControllerProvider).network;
    final address = await showDialog<String>(
      context: context,
      builder: (_) => _AddPeerDialog(example: '1.2.3.4:${network.p2pPort}'),
    );
    if (address == null || !context.mounted) return;
    final result = await ref
        .read(nodeRpcRepositoryProvider)
        .addNode(address, command: AddNodeCommand.add);
    if (!context.mounted) return;
    result.fold((f) => showFailure(context, f), (_) {
      showMessage(
        context,
        'Asked the node to connect to $address. It is listed here once '
        'connected.',
      );
      ref.read(nodeControllerProvider.notifier).refresh();
    });
  }
}

/// "Connected" for ready peers; v0.9.1 also reports "Awaiting" (handshake
/// in progress) and "Banned".
(String, DashTone) _state(Peer p) => switch (p.state.toLowerCase()) {
  'ready' => ('Connected', DashTone.success),
  'awaiting' => ('Connecting', DashTone.warning),
  'banned' => ('Banned', DashTone.danger),
  _ => (p.state, DashTone.neutral),
};

String _capitalize(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

class _PeerGrid extends StatelessWidget {
  const _PeerGrid(this.peers);
  final List<Peer> peers;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        const gap = 16.0;
        final columns = ((c.maxWidth + gap) / (260 + gap)).floor().clamp(1, 3);
        final width = (c.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final p in peers) SizedBox(width: width, child: _PeerCard(p)),
          ],
        );
      },
    );
  }
}

class _PeerCard extends StatelessWidget {
  const _PeerCard(this.peer);
  final Peer peer;

  @override
  Widget build(BuildContext context) {
    final t = context.dash;
    final (label, tone) = _state(peer);
    final ok = tone == DashTone.success;
    final colors = tone.colors(context);

    Widget cell(String name, String value) => Expanded(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: DashText.small(context)),
            const SizedBox(height: 2),
            Text(value, style: DashText.value(context)),
          ],
        ),
      ),
    );

    return DashCard(
      padding: const EdgeInsets.all(16),
      color: ok ? null : colors.bg,
      borderColor: ok ? null : colors.border,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: tone.strong(context),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: DashText.body(
                    context,
                    color: t.textPrimary,
                    weight: FontWeight.w500,
                  ),
                ),
              ),
              DashTag(peer.transport.toLowerCase()),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            peer.address,
            style: monoStyle(
              context,
              size: 12.5,
            ).copyWith(color: t.textSecondary),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: t.subtle,
              border: Border.all(color: t.border),
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  cell('Kind', _capitalize(peer.kind)),
                  VerticalDivider(width: 1, color: t.border),
                  cell('Direction', peer.inbound ? 'In' : 'Out'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          DashButton(
            'Copy Address',
            asset: DashIcons.copy,
            expand: true,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: peer.address));
              if (context.mounted) showMessage(context, 'Address copied');
            },
          ),
        ],
      ),
    );
  }
}

class _PeerTable extends StatelessWidget {
  const _PeerTable(this.peers);
  final List<Peer> peers;

  @override
  Widget build(BuildContext context) {
    final t = context.dash;
    Widget cell(String text, {Color? color, bool mono = false}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Text(
        text,
        overflow: TextOverflow.ellipsis,
        style: mono
            ? monoStyle(context, size: 12.5).copyWith(color: t.textPrimary)
            : DashText.body(context, color: color ?? t.textPrimary),
      ),
    );
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(2.2),
        1: FlexColumnWidth(0.8),
        2: FlexColumnWidth(1),
        3: FlexColumnWidth(1.2),
        4: FlexColumnWidth(1),
        5: FlexColumnWidth(2),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          decoration: BoxDecoration(
            color: t.subtle,
            border: Border(top: BorderSide(color: t.border)),
          ),
          children: [
            for (final h in [
              'Address',
              'Dir',
              'Kind',
              'Status',
              'Transport',
              'Software',
            ])
              cell(h, color: t.textSecondary),
          ],
        ),
        for (final p in peers)
          TableRow(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: t.border)),
            ),
            children: [
              cell(p.address, mono: true),
              cell(p.inbound ? 'In' : 'Out'),
              cell(_capitalize(p.kind)),
              () {
                final (label, tone) = _state(p);
                return cell(label, color: tone.colors(context).fg);
              }(),
              cell(p.transport.toLowerCase()),
              cell(p.userAgent),
            ],
          ),
      ],
    );
  }
}

class _AddPeerDialog extends StatefulWidget {
  const _AddPeerDialog({required this.example});
  final String example;

  @override
  State<_AddPeerDialog> createState() => _AddPeerDialogState();
}

class _AddPeerDialogState extends State<_AddPeerDialog> {
  final _field = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    validatePeerAddress(_field.text).match(
      (e) => setState(() => _error = e),
      (ok) => Navigator.of(context).pop(ok),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.dash;
    return Dialog(
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  'Add Peer',
                  style: DashText.cardTitle(context).copyWith(fontSize: 16),
                ),
              ),
              Text(
                'Manually connect to a node.',
                style: DashText.body(context),
              ),
              const SizedBox(height: 16),
              Text(
                'Host:Port',
                style: DashText.body(
                  context,
                  color: t.textPrimary,
                  weight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _field,
                autofocus: true,
                onSubmitted: (_) => _submit(),
                style: monoStyle(context, size: 13),
                decoration: InputDecoration(
                  hintText: 'Example: ${widget.example}',
                  errorText: _error,
                  errorMaxLines: 3,
                  isDense: true,
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  DashButton(
                    'Connect',
                    style: DashButtonStyle.primary,
                    onPressed: _submit,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
