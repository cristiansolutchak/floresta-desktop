import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart' hide State;

import '../../../app/theme/app_theme.dart';
import '../../../core/errors/failure.dart';
import '../../../shared/format.dart';
import '../../../shared/widgets/common.dart';
import '../../node/domain/node_readiness.dart';
import '../../node/domain/node_status.dart';
import '../../node/presentation/node_controller.dart';
import '../../settings/domain/bitcoin_network.dart';
import '../../settings/presentation/settings_controller.dart';
import '../domain/address_activity.dart';
import '../domain/wallet_account.dart';
import '../domain/wallet_labels.dart';
import '../domain/wallet_state.dart';
import '../domain/watched_list.dart';
import 'amount_format.dart';
import 'wallet_controller.dart';
import 'wallet_rescan_controller.dart';
import 'wallet_sync_controller.dart';

/// Scheduled, started or abandoned rescans.
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

class WalletPage extends ConsumerStatefulWidget {
  const WalletPage({super.key});

  @override
  ConsumerState<WalletPage> createState() => _WalletPageState();
}

class _WalletPageState extends ConsumerState<WalletPage> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final apiUp = ref.watch(
      nodeControllerProvider.select((s) => s.api == ApiReachability.reachable),
    );
    final listed = ref.watch(walletDescriptorsProvider);
    final overview = ref.watch(walletSyncProvider);
    final accounts = overview.watched.accounts;
    final account =
        accounts.where((a) => a.id == _selected).firstOrNull ??
        accounts.firstOrNull;
    final snapshot = account == null ? null : overview.snapshotOf(account);

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
          title: 'Watch-only: can see, cannot spend',
          message:
              'This app holds no keys and cannot send, sign or spend. To '
              'send bitcoin, use a wallet such as Sparrow or a hardware '
              'wallet connected to this node.',
        ),
        const SizedBox(height: 16),
        const _RescanNotice(),
        if (accounts.length > 1) ...[
          _AccountPicker(
            accounts: accounts,
            selected: account!,
            labels: ref.watch(walletLabelsProvider),
            onChanged: (a) => setState(() => _selected = a.id),
          ),
          const SizedBox(height: 16),
        ],
        if (account != null) ...[
          _BalanceCards(snapshot: snapshot, apiUp: apiUp),
          const SizedBox(height: 16),
        ],
        _SourcesPanel(listed: listed, apiUp: apiUp, overview: overview),
        if (account != null) ...[
          const SizedBox(height: 16),
          _AddressesPanel(account: account, snapshot: snapshot),
          const SizedBox(height: 16),
          _ActivityPanel(snapshot: snapshot),
        ],
        const SizedBox(height: 16),
        const _ExternalWalletsPanel(),
      ],
    );
  }

  Future<void> _showImport(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _ImportDescriptorDialog(
        suggestedName:
            'Wallet ${ref.read(walletSyncProvider).watched.accounts.length + 1}',
      ),
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
    // Scheduled, not sent now. florestad refuses rescans while
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

/// A wallet's name and type, with Rename and Remove.
class _AccountHeader extends ConsumerWidget {
  const _AccountHeader({required this.account, required this.index});
  final WalletAccount account;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labels = ref.watch(walletLabelsProvider);
    final type = _scriptLabel(account.external.scriptType);
    final name = WalletName.display(
      account,
      index: index,
      labels: labels,
      scriptLabel: type,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(
            Icons.account_balance_wallet_outlined,
            size: 18,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: name,
                style: context.text.titleSmall,
                children: [
                  if (labels[account.id]?.name != null)
                    TextSpan(text: '  $type', style: context.text.bodySmall),
                ],
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'Rename $name',
            iconSize: 18,
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _rename(context, ref, labels[account.id]?.name),
          ),
          IconButton(
            tooltip: 'Remove $name',
            iconSize: 18,
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _remove(context, ref, name),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    String? current,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _RenameDialog(id: account.id, current: current),
    );
    if (saved == true && context.mounted) showMessage(context, 'Name saved.');
  }

  Future<void> _remove(BuildContext context, WidgetRef ref, String name) async {
    final ok = await confirm(
      context,
      title: 'Remove $name from this app?',
      message:
          'This app stops showing and syncing it. Floresta itself keeps '
          'watching its addresses: it has no way to forget a descriptor until '
          'its wallet data is reset. Nothing about your coins changes, and '
          'you can show it again from "Removed from this app".',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    await ref.read(walletLabelsProvider.notifier).remove(account.id);
    if (context.mounted) showMessage(context, 'Removed $name from this app.');
  }
}

class _RenameDialog extends ConsumerStatefulWidget {
  const _RenameDialog({required this.id, required this.current});
  final String id;
  final String? current;

  @override
  ConsumerState<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends ConsumerState<_RenameDialog> {
  late final _name = TextEditingController(text: widget.current ?? '');
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final result = await ref
        .read(walletLabelsProvider.notifier)
        .rename(widget.id, _name.text);
    if (!mounted) return;
    result.fold((f) {
      if (f is SecretMaterialRejectedFailure) _name.clear();
      setState(() => _error = f.message);
    }, (_) => Navigator.of(context).pop(true));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename wallet'),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _name,
          autofocus: true,
          maxLength: WalletName.maxLength,
          // Counter only: cutting a pasted key short would let a piece of it
          // past the checks. WalletName refuses names that are too long.
          maxLengthEnforcement: MaxLengthEnforcement.none,
          decoration: InputDecoration(
            labelText: 'Name',
            helperText: 'Only on this computer.',
            errorText: _error,
          ),
          onSubmitted: (_) => _save(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// Wallets removed from this app, still watched by the node.
class _RemovedAccounts extends ConsumerWidget {
  const _RemovedAccounts({required this.accounts});
  final List<WalletAccount> accounts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labels = ref.watch(walletLabelsProvider);
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(
          'Removed from this app (${accounts.length})',
          style: context.text.bodyMedium,
        ),
        subtitle: Text(
          'Floresta still watches these; they are not synced or shown above.',
          style: context.text.bodySmall,
        ),
        children: [
          for (final (i, a) in accounts.indexed)
            Row(
              children: [
                Expanded(
                  child: Text(
                    WalletName.display(
                      a,
                      index: i,
                      labels: labels,
                      scriptLabel: _scriptLabel(a.external.scriptType),
                    ),
                    style: context.text.bodyMedium,
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      ref.read(walletLabelsProvider.notifier).restore(a.id),
                  child: const Text('Show again'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ImportDescriptorDialog extends ConsumerStatefulWidget {
  const _ImportDescriptorDialog({required this.suggestedName});

  /// Pre-filled so adding stays one step; the user can type over it.
  final String suggestedName;

  @override
  ConsumerState<_ImportDescriptorDialog> createState() =>
      _ImportDescriptorDialogState();
}

class _ImportDescriptorDialogState
    extends ConsumerState<_ImportDescriptorDialog> {
  final _controller = TextEditingController();
  late final _name = TextEditingController(text: widget.suggestedName);
  Failure? _failure;
  String? _nameError;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // The name first: a key pasted there must not reach the node either.
    final name = WalletName.parse(_name.text);
    if (name case Left(:final value)) {
      if (value is SecretMaterialRejectedFailure) _name.clear();
      setState(() => _nameError = value.message);
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
      _nameError = null;
    });
    final result = await ref
        .read(walletDescriptorsProvider.notifier)
        .importDescriptor(_controller.text, name: _name.text);
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
              controller: _name,
              maxLength: WalletName.maxLength,
              // Counter only: cutting a pasted key short would let a piece of it
              // past the checks. WalletName refuses names that are too long.
              maxLengthEnforcement: MaxLengthEnforcement.none,
              decoration: InputDecoration(
                labelText: 'Name',
                helperText: 'Only on this computer, e.g. "Savings".',
                errorText: _nameError,
              ),
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
            ),
            const SizedBox(height: 8),
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

class _AccountPicker extends StatelessWidget {
  const _AccountPicker({
    required this.accounts,
    required this.selected,
    required this.labels,
    required this.onChanged,
  });

  final List<WalletAccount> accounts;
  final WalletAccount selected;
  final Map<String, WalletLabel> labels;
  final ValueChanged<WalletAccount> onChanged;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: DropdownButton<String>(
        value: selected.id,
        items: [
          for (final (i, a) in accounts.indexed)
            DropdownMenuItem(
              value: a.id,
              child: Text(
                WalletName.display(
                  a,
                  index: i,
                  labels: labels,
                  scriptLabel: _scriptLabel(a.external.scriptType),
                ),
              ),
            ),
        ],
        onChanged: (id) => onChanged(accounts.firstWhere((a) => a.id == id)),
      ),
    );
  }
}

String _scriptLabel(ScriptType t) => switch (t) {
  ScriptType.wpkh => 'Native SegWit',
  ScriptType.shWpkh => 'Nested SegWit',
  ScriptType.pkh => 'Legacy',
  ScriptType.tr => 'Taproot',
};

/// How fresh the shown data is, in words (never a silent stale number).
String _syncText(WalletSyncState s) => switch (s) {
  SyncNotStarted() => 'Waiting to sync',
  SyncInProgress() => 'Syncing with your node…',
  SyncUpToDate(:final validatedHeight) =>
    'Up to date with your node at block ${formatInt(validatedHeight)}',
  SyncStale(:final failure) =>
    'Showing the last synced data: ${failure.title.toLowerCase()}',
  SyncBlocked(:final failure) => 'Not synced: ${failure.message}',
};

class _BalanceCards extends StatelessWidget {
  const _BalanceCards({required this.snapshot, required this.apiUp});

  final WalletSnapshot? snapshot;
  final bool apiUp;

  @override
  Widget build(BuildContext context) {
    final b = snapshot?.balance;
    final sync = snapshot?.sync;
    Widget card(String title, String? value, String caption, IconData icon) =>
        Expanded(
          child: Panel(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: context.text.bodySmall),
                      const SizedBox(height: 4),
                      Text(
                        value ?? '—',
                        style: context.text.titleLarge?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(caption, style: context.text.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            card(
              'Confirmed balance',
              b == null ? null : formatBtc(b.confirmed),
              b == null
                  ? (apiUp
                        ? 'Waiting for the first sync'
                        : 'Start the node to sync')
                  : [
                      'Spendable ${formatBtc(b.spendable)}',
                      if (b.immature > 0) 'immature ${formatBtc(b.immature)}',
                    ].join(' · '),
              Icons.verified_outlined,
            ),
            const SizedBox(width: 16),
            card(
              'Pending',
              b == null ? null : formatBtc(b.pending, signed: true),
              'Not yet verified by your node',
              Icons.hourglass_bottom,
            ),
          ],
        ),
        if (sync != null) ...[
          const SizedBox(height: 8),
          Text(_syncText(sync), style: context.text.bodySmall),
        ],
      ],
    );
  }
}

class _SourcesPanel extends ConsumerWidget {
  const _SourcesPanel({
    required this.listed,
    required this.apiUp,
    required this.overview,
  });

  final AsyncValue<Either<Failure, WatchedList>> listed;
  final bool apiUp;
  final WalletOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watched = overview.watched;
    final value = listed.value?.toNullable();
    final count = watched.accounts.length;
    return Panel(
      title: 'Tracking sources',
      trailing: apiUp
          ? IconButton(
              tooltip: 'Reload',
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: () {
                ref.read(walletDescriptorsProvider.notifier).reload();
                ref.read(walletSyncProvider.notifier).refresh();
              },
            )
          : null,
      child: switch (listed) {
        _ when !apiUp && count == 0 => const EmptyState(
          icon: Icons.power_settings_new,
          title: 'Node not running',
          message:
              'Start the node from Node to see and manage watched wallets.',
        ),
        AsyncData(value: Left(value: final failure)) when apiUp =>
          Notice.failure(failure),
        AsyncError(:final error) => Notice(
          tone: Tone.danger,
          title: 'Could not load wallets',
          message: '$error',
        ),
        _ when value != null && value.checking => const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('Checking which wallets the node watches…'),
            ],
          ),
        ),
        _ when value != null && value.knownEmpty && overview.removed.isEmpty =>
          const EmptyState(
            icon: Icons.account_balance_wallet_outlined,
            title: 'No wallets yet',
            message:
                'Add a descriptor exported from your wallet to start tracking '
                'its balance and transactions.',
          ),
        _ when value == null && apiUp => const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
        _ => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '$count wallet${count == 1 ? '' : 's'} · '
              '${count * 2} descriptors · '
              '${count * 200} addresses watched (100 receive and 100 change '
              'per wallet)',
              style: context.text.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final (i, a) in watched.accounts.indexed) ...[
              _AccountHeader(account: a, index: i),
              _DescriptorRow(a.external.value),
              _DescriptorRow(a.internal.value),
              const SizedBox(height: 8),
            ],
            if (overview.removed.isNotEmpty)
              _RemovedAccounts(accounts: overview.removed),
            if (watched.receiveOnly.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Notice(
                tone: Tone.warning,
                title: 'Change addresses are not watched',
                message:
                    'The node watches only the receive branch of these '
                    'descriptors, so payments to change addresses are '
                    'invisible and a balance would be wrong. Add the '
                    'descriptor again here to watch both branches.',
              ),
              for (final d in watched.receiveOnly) _DescriptorRow(d),
            ],
            if (watched.unsupported.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Notice(
                tone: Tone.info,
                title: 'Watched by the node, not shown here',
                message:
                    'This app shows balances for single-key wpkh, sh(wpkh), '
                    'pkh and tr wallets. Floresta has no way to remove a '
                    'descriptor, so these stay watched.',
              ),
              for (final d in watched.unsupported) _DescriptorRow(d),
            ],
          ],
        ),
      },
    );
  }
}

class _AddressesPanel extends ConsumerStatefulWidget {
  const _AddressesPanel({required this.account, required this.snapshot});

  final WalletAccount account;
  final WalletSnapshot? snapshot;

  @override
  ConsumerState<_AddressesPanel> createState() => _AddressesPanelState();
}

class _AddressesPanelState extends ConsumerState<_AddressesPanel> {
  Keychain _keychain = Keychain.external;
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final encode = ref.watch(addressEncoderProvider);
    final network = widget.account.network;
    final all = [
      for (final a in widget.snapshot?.addresses ?? const <AddressActivity>[])
        if (a.keychain == _keychain) a,
    ];
    // Used addresses, then the next unused one (the one to hand out).
    final firstUnused = all.where((a) => !a.used).firstOrNull;
    final shown = _all
        ? all
        : [
            for (final a in all)
              if (a.used || a == firstUnused) a,
          ];
    return Panel(
      title: 'Addresses',
      trailing: SegmentedButton<Keychain>(
        segments: const [
          ButtonSegment(
            value: Keychain.external,
            label: Text('Receive addresses'),
          ),
          ButtonSegment(
            value: Keychain.internal,
            label: Text('Change addresses'),
          ),
        ],
        selected: {_keychain},
        showSelectedIcon: false,
        onSelectionChanged: (s) => setState(() {
          _keychain = s.first;
          _all = false;
        }),
      ),
      child: widget.snapshot?.balance == null
          ? const EmptyState(
              icon: Icons.list_alt,
              title: 'Not synced yet',
              message: 'Addresses appear after the first sync with your node.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _AddressHeader(),
                for (final a in shown)
                  _AddressRow(
                    activity: a,
                    address: encode(a.scriptPubKey, network) ?? a.scriptPubKey,
                    next: a == firstUnused,
                  ),
                const SizedBox(height: 8),
                if (all.length > shown.length || _all)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setState(() => _all = !_all),
                      child: Text(
                        _all
                            ? 'Show used addresses only'
                            : 'Show all ${all.length} watched addresses',
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _AddressHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final style = context.text.labelSmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 110, child: Text('LABEL', style: style)),
          Expanded(child: Text('ADDRESS', style: style)),
          SizedBox(
            width: 170,
            child: Text('BALANCE', style: style, textAlign: TextAlign.right),
          ),
          SizedBox(
            width: 150,
            child: Text(
              'LAST ACTIVITY',
              style: style,
              textAlign: TextAlign.right,
            ),
          ),
          const SizedBox(width: 40),
        ],
      ),
    );
  }
}

class _AddressRow extends StatelessWidget {
  const _AddressRow({
    required this.activity,
    required this.address,
    required this.next,
  });

  final AddressActivity activity;
  final String address;
  final bool next;

  @override
  Widget build(BuildContext context) {
    final a = activity;
    final label =
        '${a.keychain == Keychain.external ? 'Receive' : 'Change'} #${a.index}';
    final last = switch (a.lastHeight) {
      null => next ? 'Next to use' : 'Never used',
      0 => 'Unconfirmed',
      final h => 'Block ${formatInt(h)}',
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.colors.border)),
      ),
      child: Row(
        children: [
          SizedBox(width: 110, child: Text(label)),
          Expanded(
            child: SelectableText(address, style: monoStyle(context, size: 12)),
          ),
          SizedBox(
            width: 170,
            child: Text(
              a.used ? formatBtc(a.balanceSats) : '—',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          SizedBox(
            width: 150,
            child: Text(
              last,
              textAlign: TextAlign.right,
              style: context.text.bodySmall,
            ),
          ),
          SizedBox(width: 40, child: CopyButton(text: address)),
        ],
      ),
    );
  }
}

class _ActivityPanel extends StatefulWidget {
  const _ActivityPanel({required this.snapshot});

  final WalletSnapshot? snapshot;

  @override
  State<_ActivityPanel> createState() => _ActivityPanelState();
}

class _ActivityPanelState extends State<_ActivityPanel> {
  static const _recent = 10;
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final snap = widget.snapshot;
    final txs = snap?.transactions ?? const <WalletTransactionView>[];
    final tip = switch (snap?.sync) {
      SyncUpToDate(:final validatedHeight) => validatedHeight,
      _ => null,
    };
    final shown = _all ? txs : txs.take(_recent).toList();
    return Panel(
      title: 'Activity',
      child: snap?.balance == null
          ? const EmptyState(
              icon: Icons.history,
              title: 'Not synced yet',
              message: 'Transactions appear after the first sync.',
            )
          : txs.isEmpty
          ? const EmptyState(
              icon: Icons.history,
              title: 'No transactions yet',
              message:
                  'Payments to this wallet appear here once your node sees '
                  'them.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final t in shown) _ActivityRow(tx: t, tip: tip),
                if (txs.length > _recent)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setState(() => _all = !_all),
                      child: Text(
                        _all ? 'Show recent only' : 'Show all ${txs.length}',
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.tx, required this.tip});

  final WalletTransactionView tx;
  final int? tip;

  @override
  Widget build(BuildContext context) {
    final received = tx.netSats >= 0;
    final (status, tone) = switch (tx.confirmation) {
      Confirmed(:final height) => (
        tip == null
            ? 'Confirmed in block ${formatInt(height)}'
            : '${formatInt(tip! - height + 1)} confirmations · block '
                  '${formatInt(height)}',
        Tone.success,
      ),
      PendingValidation(:final height) => (
        'In block ${formatInt(height)}, not yet verified by your node',
        Tone.warning,
      ),
      Unconfirmed() => ('Unconfirmed', Tone.warning),
      Unverified(:final reason) => ('Not verified: $reason', Tone.danger),
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.colors.border)),
      ),
      child: Row(
        children: [
          Icon(
            received ? Icons.south_west : Icons.north_east,
            size: 18,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  received ? 'Received' : 'Sent',
                  style: context.text.titleSmall,
                ),
                const SizedBox(height: 2),
                StatusIndicator(label: status, tone: tone),
              ],
            ),
          ),
          SelectableText(shortId(tx.txid), style: monoStyle(context, size: 12)),
          CopyButton(text: tx.txid, tooltip: 'Copy transaction id'),
          const SizedBox(width: 12),
          SizedBox(
            width: 190,
            child: Text(
              formatBtc(tx.netSats, signed: true),
              textAlign: TextAlign.right,
              style: context.text.titleSmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
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
    final address = ref.watch(
      settingsControllerProvider.select((s) => s.electrumAddress),
    );
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
