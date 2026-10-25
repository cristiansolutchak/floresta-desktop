import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart' hide State;

import '../../../app/theme/app_theme.dart';
import '../../../core/errors/failure.dart';
import '../../../shared/widgets/common.dart';
import '../../node/domain/node_readiness.dart';
import '../../node/domain/node_status.dart';
import '../../node/presentation/node_controller.dart';
import '../../settings/domain/bitcoin_network.dart';
import '../../settings/presentation/settings_controller.dart';
import 'wallet_controller.dart';
import 'wallet_rescan_controller.dart';

/// Scheduled, started or abandoned rescans (WAL-06).
class _RescanNotice extends ConsumerWidget {
  const _RescanNotice();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(walletRescanProvider);
    final from = r.from == null
        ? 'the start of the block filters'
        : 'block ${r.from}';
    final Widget? notice = r.owed
        ? Notice(
            tone: Tone.info,
            icon: Icons.schedule,
            title: 'Rescan scheduled',
            message:
                'Searches from $from. It starts automatically once the node '
                'has been synced for a minute.',
            action: TextButton(
              onPressed: () => ref.read(walletRescanProvider.notifier).cancel(),
              child: const Text('Cancel'),
            ),
          )
        : r.gaveUp != null
        ? Notice(
            tone: Tone.warning,
            title: 'Rescan not started',
            message: r.gaveUp!,
          )
        : r.startedAt != null
        ? Notice(
            tone: Tone.info,
            title: 'Rescan running in the background',
            message:
                'Started at ${TimeOfDay.fromDateTime(r.startedAt!).format(context)}. '
                'Floresta 0.9.1 does not report its progress; transactions '
                'appear as they are found.',
          )
        : null;
    if (notice == null) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(bottom: 16), child: notice);
  }
}

class WalletPage extends ConsumerWidget {
  const WalletPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final apiUp = ref.watch(
      nodeControllerProvider.select((s) => s.api == ApiReachability.reachable),
    );
    final descriptors = ref.watch(walletDescriptorsProvider);

    // Re-query once the API comes up, e.g. after starting the node here.
    ref.listen(nodeControllerProvider.select((s) => s.api), (prev, next) {
      if (next == ApiReachability.reachable && prev != next) {
        ref.read(walletDescriptorsProvider.notifier).reload();
      }
    });

    return PageBody(
      children: [
        PageHeader(
          title: 'Wallet',
          subtitle: 'Watch-only wallets tracked by your node.',
          actions: [
            if (apiUp) ...[
              OutlinedButton(
                onPressed: () => _rescan(context, ref),
                child: const Text('Rescan…'),
              ),
              FilledButton.icon(
                onPressed: () => _showImport(context, ref),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add descriptor'),
              ),
            ],
          ],
        ),
        const Notice(
          tone: Tone.info,
          icon: Icons.visibility_outlined,
          title: 'Watch-only',
          message:
              'Floresta can see transactions for the wallets you add, '
              'but it holds no keys and cannot send, sign or spend. To send '
              'bitcoin, use a wallet such as Sparrow or a hardware wallet '
              'connected to this node.',
        ),
        const SizedBox(height: 16),
        const _RescanNotice(),
        Panel(
          title: 'Watched descriptors',
          trailing: apiUp
              ? IconButton(
                  tooltip: 'Reload',
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: () =>
                      ref.read(walletDescriptorsProvider.notifier).reload(),
                )
              : null,
          child: switch (descriptors) {
            _ when !apiUp => const EmptyState(
              icon: Icons.power_settings_new,
              title: 'Node not running',
              message:
                  'Start the node from Node to see and manage '
                  'watched wallets.',
            ),
            AsyncData(value: Right(value: final list)) when list.isEmpty =>
              const EmptyState(
                icon: Icons.account_balance_wallet_outlined,
                title: 'No wallets yet',
                message:
                    'Add a descriptor exported from your wallet to start '
                    'tracking its transactions.',
              ),
            AsyncData(value: Right(value: final list)) => Column(
              children: [for (final d in list) _DescriptorRow(d)],
            ),
            AsyncData(value: Left(value: final failure)) => Notice.failure(
              failure,
            ),
            AsyncError(:final error) => Notice(
              tone: Tone.danger,
              title: 'Could not load wallets',
              message: '$error',
            ),
            _ => const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          },
        ),
        const SizedBox(height: 16),
        const _BalancesPanel(),
        const SizedBox(height: 16),
        const _ExternalWalletsPanel(),
      ],
    );
  }

  Future<void> _showImport(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => const _ImportDescriptorDialog(),
    );
    if (ok != true || !context.mounted) return;
    final synced =
        ref.read(nodeReadinessProvider).stage == ReadinessStage.ready;
    if (!synced) {
      // florestad started its own scan, but over filters that are still
      // incomplete while syncing; owe a full rescan for afterwards.
      await ref.read(walletRescanProvider.notifier).request();
    }
    if (!context.mounted) return;
    showMessage(
      context,
      synced
          ? 'Descriptor added. Floresta is scanning for its transactions in '
                'the background.'
          : 'Descriptor added. The node is still syncing, so a full scan '
                'runs automatically once it has synced.',
    );
  }

  Future<void> _rescan(BuildContext context, WidgetRef ref) async {
    final heightController = TextEditingController();
    final start = await showDialog<Option<int?>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rescan the blockchain'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Floresta looks through compact block filters for '
                'transactions involving your watched addresses. It runs in '
                'the background and the node does not report progress.',
              ),
              const SizedBox(height: 14),
              TextField(
                controller: heightController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Start height (optional)',
                  helperText: 'Leave empty to scan from the beginning.',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final text = heightController.text.trim();
              final parsed = int.tryParse(text);
              if (text.isNotEmpty && (parsed == null || parsed < 0)) return;
              Navigator.of(context).pop(Option.of(parsed));
            },
            child: const Text('Start rescan'),
          ),
        ],
      ),
    );
    heightController.dispose();
    if (start == null || !context.mounted) return;
    // WAL-06: scheduled, not sent now. florestad refuses rescans while
    // syncing, and the gate sends it once the node has been synced a while.
    await ref
        .read(walletRescanProvider.notifier)
        .request(from: start.toNullable());
    if (!context.mounted) return;
    final synced =
        ref.read(nodeReadinessProvider).stage == ReadinessStage.ready;
    showMessage(
      context,
      synced
          ? 'Rescan scheduled. It starts within a minute.'
          : 'Rescan scheduled. It starts automatically once the node has '
                'synced.',
    );
  }
}

class _DescriptorRow extends StatefulWidget {
  const _DescriptorRow(this.descriptor);
  final String descriptor;

  @override
  State<_DescriptorRow> createState() => _DescriptorRowState();
}

class _DescriptorRowState extends State<_DescriptorRow> {
  bool _revealed = false;

  /// Descriptors reveal a wallet's full history, so they are masked unless
  /// the user explicitly reveals one.
  String get _masked {
    final d = widget.descriptor;
    final open = d.indexOf('(');
    final prefix = open > 0 ? d.substring(0, open + 1) : '';
    return '$prefix••••••••${d.length > 8 ? d.substring(d.length - 8) : ''}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.colors.border)),
      ),
      child: Row(
        children: [
          const Icon(Icons.key_outlined, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              _revealed ? widget.descriptor : _masked,
              style: monoStyle(context, size: 12),
            ),
          ),
          IconButton(
            tooltip: _revealed ? 'Hide' : 'Reveal',
            iconSize: 16,
            icon: Icon(_revealed ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _revealed = !_revealed),
          ),
          CopyButton(text: widget.descriptor),
        ],
      ),
    );
  }
}

class _ImportDescriptorDialog extends ConsumerStatefulWidget {
  const _ImportDescriptorDialog();

  @override
  ConsumerState<_ImportDescriptorDialog> createState() =>
      _ImportDescriptorDialogState();
}

class _ImportDescriptorDialogState
    extends ConsumerState<_ImportDescriptorDialog> {
  final _controller = TextEditingController();
  Failure? _failure;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    final result = await ref
        .read(walletDescriptorsProvider.notifier)
        .importDescriptor(_controller.text);
    if (!mounted) return;
    result.fold((f) {
      // Never keep pasted secrets in memory or on screen.
      if (f is SecretMaterialRejectedFailure) _controller.clear();
      setState(() {
        _busy = false;
        _failure = f;
      });
    }, (_) => Navigator.of(context).pop(true));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a watch-only descriptor'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Paste a public output descriptor exported from your wallet, '
              'for example wpkh([fingerprint/84h/0h/0h]xpub…/<0;1>/*). '
              'Floresta tracks the first 100 addresses of each keychain.',
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 3,
              maxLines: 5,
              autocorrect: false,
              enableSuggestions: false,
              style: monoStyle(context, size: 12),
              decoration: const InputDecoration(labelText: 'Descriptor'),
            ),
            if (_failure case final f?) ...[
              const SizedBox(height: 12),
              Notice.failure(f),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class _BalancesPanel extends StatelessWidget {
  const _BalancesPanel();

  @override
  Widget build(BuildContext context) {
    return const Panel(
      title: 'Balance and history',
      child: EmptyState(
        icon: Icons.query_stats,
        title: 'Not available in this app yet',
        message:
            'Floresta serves balances and transaction history over the '
            'Electrum protocol, not its RPC interface. Until this app '
            'supports that, view them in a wallet connected to your node.',
      ),
    );
  }
}

/// Electrum's network flags; testnet4 is omitted because support for it in
/// Electrum has not been verified.
String? _electrumNetworkFlag(BitcoinNetwork network) => switch (network) {
  BitcoinNetwork.bitcoin => '',
  BitcoinNetwork.signet => '--signet ',
  BitcoinNetwork.regtest => '--regtest ',
  BitcoinNetwork.testnet4 => null,
};

class _ExternalWalletsPanel extends ConsumerWidget {
  const _ExternalWalletsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = ref.watch(
      settingsControllerProvider.select((s) => s.network),
    );
    final address = '127.0.0.1:${network.electrumPort}';
    return Panel(
      title: 'Connect a wallet',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Floresta runs an Electrum server for wallets on this computer. '
            'It only knows about wallets whose descriptors you added above.',
            style: context.text.bodySmall,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: KeyValueRow(
                  'Electrum server (TCP)',
                  address,
                  mono: true,
                ),
              ),
              CopyButton(text: address),
            ],
          ),
          const KeyValueRow(
            'Sparrow',
            'Settings → Server → Private Electrum, then enter the address '
                'above with SSL off.',
          ),
          if (_electrumNetworkFlag(network) case final flag?)
            KeyValueRow(
              'Electrum',
              'electrum $flag--oneserver --server $address:t',
              mono: true,
            ),
        ],
      ),
    );
  }
}
