import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/build_flavor.dart';
import '../../../core/providers.dart';
import '../../../shared/format.dart';
import '../../../shared/widgets/common.dart';
import '../../installation/presentation/installation_view.dart';
import '../../installation/presentation/setup_state_provider.dart';
import '../../node/domain/preflight.dart';
import '../../node/presentation/node_controller.dart';
import '../../settings/domain/bitcoin_network.dart';
import '../../settings/domain/node_settings.dart';
import '../../settings/domain/wallet_birthday.dart';
import '../../settings/presentation/settings_controller.dart';
import '../../settings/presentation/sync_method_labels.dart';
import 'wizard_widgets.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final accent = Theme.of(context).colorScheme.primary;
    Widget point(IconData icon, String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(icon, size: 20, color: accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.text.titleSmall),
                const SizedBox(height: 2),
                Text(body, style: context.text.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );

    return WizardFrame(
      title: 'Welcome to Floresta',
      subtitle:
          'Run your own Bitcoin node in a few clicks. This app installs '
          'Floresta, sets it up and keeps it running, with no terminal.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          point(
            Icons.verified_outlined,
            'Verify, don\'t trust',
            'Your node checks every Bitcoin rule itself instead of trusting '
                'someone else\'s server.',
          ),
          point(
            Icons.storage_outlined,
            'Light on your disk',
            'Utreexo keeps a compact proof of the chain, not hundreds of '
                'gigabytes of blocks.',
          ),
          point(
            Icons.account_balance_wallet_outlined,
            'Private for your wallets',
            'Watch your wallets and connect Sparrow or Electrum to your own '
                'node. Your keys never leave your wallet.',
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 48,
            child: FilledButton(
              autofocus: true,
              onPressed: () => context.go('/onboarding/install'),
              child: const Text('Get started'),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Nothing is downloaded until you choose to install.',
            textAlign: TextAlign.center,
            style: context.text.bodySmall?.copyWith(color: colors.muted),
          ),
        ],
      ),
    );
  }
}

class InstallStepPage extends StatelessWidget {
  const InstallStepPage({super.key});

  @override
  Widget build(BuildContext context) {
    return WizardFrame(
      title: 'Get Floresta',
      subtitle:
          'Floresta is the program that runs your node. The app checks '
          'whether this computer already has it.',
      onBack: () => context.go('/welcome'),
      child: InstallationView(
        primaryAction: FilledButton(
          onPressed: () => context.go('/onboarding/setup'),
          child: const Text('Continue'),
        ),
      ),
    );
  }
}

/// The setup wizard: four steps and a review.
/// Edits a draft; nothing is saved until Finish.
class SetupStepPage extends ConsumerStatefulWidget {
  const SetupStepPage({super.key});

  static const steps = ['Network', 'Storage', 'Sync', 'Services'];

  @override
  ConsumerState<SetupStepPage> createState() => _SetupStepPageState();
}

class _SetupStepPageState extends ConsumerState<SetupStepPage> {
  late NodeSettings _draft = _initialDraft();

  /// The saved settings, except that Swift Sync (the default) gives way to
  /// Fast Start when the installed Floresta cannot do it, so the default
  /// choice can always start.
  NodeSettings _initialDraft() {
    final saved = ref.read(settingsControllerProvider);
    final install = ref.read(setupStateProvider).installation;
    final cannot = install != null && !install.swiftSync;
    return cannot && saved.syncMethod == SyncMethod.swiftSync
        ? saved.withSyncMethod(SyncMethod.fastStart)
        : saved;
  }

  int _step = 0;
  bool _startNow = true;
  bool _saving = false;

  /// Index of the review screen, after the last stepper step.
  static final _review = SetupStepPage.steps.length;

  void _edit(NodeSettings next) => setState(() => _draft = next);

  void _back() {
    if (_step == 0) {
      context.go('/onboarding/install');
    } else {
      setState(() => _step--);
    }
  }

  Future<void> _finish() async {
    setState(() => _saving = true);
    final result = await ref
        .read(settingsControllerProvider.notifier)
        .update(_draft.copyWith(onboardingComplete: true));
    if (!mounted) return;
    setState(() => _saving = false);
    if (result.getLeft().toNullable() case final f?) {
      showFailure(context, f);
      return;
    }
    // The app-wide messenger outlives this page, so a failed start can
    // still be reported on the node page.
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(nodeControllerProvider.notifier);
    context.go('/node');
    if (!_startNow) return;
    final started = await controller.start();
    if (started.getLeft().toNullable() case final f?) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text([f.title, f.message, ?f.recovery].join(' — ')),
            behavior: SnackBarBehavior.floating,
            width: 420,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final next = FilledButton(
      onPressed: () => setState(() => _step++),
      child: Text(_step == _review - 1 ? 'Review configuration' : 'Next'),
    );
    final (title, subtitle, body) = switch (_step) {
      0 => (
        'Choose a network',
        'Which Bitcoin network should this node follow?',
        _NetworkStep(draft: _draft, onChanged: _edit),
      ),
      1 => (
        'Storage',
        'Where Floresta keeps the chain state, block filters and the '
            'watch-only wallet.',
        _StorageStep(draft: _draft, onChanged: _edit),
      ),
      2 => (
        'Sync',
        'How the node gets to the tip of the chain.',
        _SyncMethodStep(draft: _draft, onChanged: _edit),
      ),
      3 => (
        'Services',
        'What your node offers to the wallets on this computer.',
        _ServicesStep(draft: _draft, onChanged: _edit),
      ),
      _ => (
        'Review your setup',
        'Check your choices before Floresta starts. You can change all of '
            'them later in Settings.',
        _ReviewStep(
          draft: _draft,
          startNow: _startNow,
          onStartNow: (v) => setState(() => _startNow = v),
          onEdit: (step) => setState(() => _step = step),
        ),
      ),
    };
    // Steps cross-fade inside the same frame; the draft is kept either way.
    return AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      child: WizardFrame(
        key: ValueKey(_step),
        title: title,
        subtitle: subtitle,
        stepper: WizardStepper(steps: SetupStepPage.steps, current: _step),
        onBack: _back,
        primary: _step == _review
            ? FilledButton(
                onPressed: _saving ? null : _finish,
                child: const Text('Finish'),
              )
            : next,
        child: body,
      ),
    );
  }
}

class _NetworkStep extends ConsumerStatefulWidget {
  const _NetworkStep({required this.draft, required this.onChanged});

  final NodeSettings draft;
  final ValueChanged<NodeSettings> onChanged;

  @override
  ConsumerState<_NetworkStep> createState() => _NetworkStepState();
}

class _NetworkStepState extends ConsumerState<_NetworkStep> {
  // Test networks are advanced: open in development builds or when one is
  // already chosen.
  late bool _showTest =
      ref.read(buildFlavorProvider) == BuildFlavor.development ||
      !widget.draft.network.isMainnet;

  @override
  Widget build(BuildContext context) {
    final value = widget.draft.network;
    Widget card(BitcoinNetwork n) => OptionCard(
      title: n.label,
      subtitle: n.description,
      selected: n == value,
      control: OptionControl.radio,
      onChanged: (_) => widget.onChanged(widget.draft.copyWith(network: n)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        card(BitcoinNetwork.bitcoin),
        if (_showTest)
          for (final n in BitcoinNetwork.values)
            if (!n.isMainnet) card(n),
        if (!_showTest)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _showTest = true),
              child: const Text('Test networks (advanced)'),
            ),
          ),
        const SizedBox(height: 4),
        if (value.isMainnet)
          const Notice(
            tone: Tone.warning,
            title: 'Mainnet needs time and bandwidth',
            message:
                'Floresta starts quickly with assumed state and then '
                'validates history in the background, which uses a lot of '
                'CPU and bandwidth.',
          )
        else
          const Notice(
            tone: Tone.info,
            title: 'Test network: coins have no value',
            message:
                'Use it for learning and development. Never send real '
                'bitcoin to a test network address.',
          ),
      ],
    );
  }
}

class _StorageStep extends ConsumerStatefulWidget {
  const _StorageStep({required this.draft, required this.onChanged});

  final NodeSettings draft;
  final ValueChanged<NodeSettings> onChanged;

  @override
  ConsumerState<_StorageStep> createState() => _StorageStepState();
}

class _StorageStepState extends ConsumerState<_StorageStep> {
  Future<PreflightFacts>? _facts;
  String? _factsFor;

  /// Real checks of the chosen folder: free space, write access, and
  /// whether it holds Bitcoin Core data. Re-run when the folder changes.
  Future<PreflightFacts> _check(String dir) {
    if (_factsFor != dir || _facts == null) {
      _factsFor = dir;
      _facts = ref.read(preflightProbeProvider).gather(widget.draft);
    }
    return _facts!;
  }

  @override
  Widget build(BuildContext context) {
    final platform = ref.watch(hostPlatformProvider);
    final env = ref.watch(environmentProvider);
    final draft = widget.draft;
    final dir = draft.effectiveDataDir(
      homeDir: env['HOME'] ?? env['USERPROFILE'],
      separator: platform.pathSeparator,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Data directory', style: context.text.titleSmall),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: InputDecorator(
                decoration: const InputDecoration(isDense: true),
                child: SelectableText(
                  dir,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () async {
                final picked = await getDirectoryPath(
                  confirmButtonText: 'Use this folder',
                );
                if (picked != null) {
                  widget.onChanged(draft.copyWith(dataDir: Option.of(picked)));
                }
              },
              child: const Text('Browse…'),
            ),
          ],
        ),
        if (draft.dataDir != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () =>
                  widget.onChanged(draft.copyWith(dataDir: const None())),
              child: const Text('Use the default folder'),
            ),
          ),
        const SizedBox(height: 8),
        FutureBuilder<PreflightFacts>(
          future: _check(dir),
          builder: (context, snap) {
            final facts = snap.data;
            if (facts == null) {
              return Text(
                'Checking the folder…',
                style: context.text.bodySmall,
              );
            }
            final issues = [
              for (final i in evaluatePreflight(facts))
                // Ports are checked again at start; only folder issues here.
                if (!i.title.startsWith('Port')) i,
            ];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (facts.freeBytes case final free?)
                  Text(
                    '${formatBytes(free)} free on this disk.',
                    style: context.text.bodySmall,
                  ),
                for (final i in issues) ...[
                  const SizedBox(height: 8),
                  Notice(
                    tone: i.blocks ? Tone.danger : Tone.warning,
                    title: i.title,
                    message: i.message,
                  ),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        const OptionCard(
          title: 'Pruned mode',
          trailingNote: '(always on)',
          subtitle:
              'Floresta keeps no copy of old blocks. It validates them and '
              'keeps only a compact Utreexo state.',
          selected: true,
          control: OptionControl.checkbox,
        ),
        Text(
          'Removing this app never deletes this folder.',
          style: context.text.bodySmall,
        ),
      ],
    );
  }
}

class _SyncMethodStep extends ConsumerWidget {
  const _SyncMethodStep({required this.draft, required this.onChanged});

  final NodeSettings draft;
  final ValueChanged<NodeSettings> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = draft.network;
    final supports = ref.watch(setupStateProvider).installation?.swiftSync;
    final method = draft.syncMethod;
    final height = network.assumeUtreexoHeight;

    Widget option(SyncMethod m, {String? note}) {
      final why = SyncMethodLabels.unavailable(
        m,
        network,
        binarySupportsSwiftSync: supports,
      );
      return OptionCard(
        title: SyncMethodLabels.title(m),
        trailingNote: why == null ? note : '(unavailable)',
        subtitle: [SyncMethodLabels.description(m, network), ?why].join(' '),
        selected: method == m,
        control: OptionControl.radio,
        onChanged: why == null
            ? (_) => onChanged(draft.withSyncMethod(m))
            : null,
      );
    }

    final swiftOffered = network.supportsSwiftSync;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (swiftOffered) option(SyncMethod.swiftSync, note: '(recommended)'),
        if (height > 0)
          option(
            SyncMethod.fastStart,
            note: swiftOffered ? null : '(recommended)',
          ),
        option(SyncMethod.full),
        if (method == SyncMethod.fastStart)
          OptionCard(
            title: 'Backfill in background',
            trailingNote: '(recommended)',
            subtitle:
                'Afterwards, re-check every block before ${formatInt(height)} '
                'so nothing stays assumed.',
            selected: draft.backfill,
            control: OptionControl.checkbox,
            onChanged: (v) => onChanged(draft.copyWith(backfill: v)),
          ),
        switch (method) {
          SyncMethod.swiftSync => Notice(
            tone: Tone.info,
            title: 'Before the first start',
            message:
                'The app downloads the hints file '
                '(${network.isMainnet ? 'about 125 MB' : 'about 25 MB'}) from '
                '${draft.hintsOrigin} into the data folder. Swift Sync runs '
                'only on a new data folder. If the hints do not match the '
                'chain, Floresta notices, drops them and validates with '
                'Utreexo proofs instead: slower, never less safe.',
          ),
          SyncMethod.full when height > 0 || swiftOffered => const Notice(
            tone: Tone.warning,
            title: 'Starting from the first block is slow',
            message:
                'Floresta needs peers that serve Utreexo proofs for the whole '
                'history. Few exist, so getting to the tip can take days.',
          ),
          SyncMethod.fastStart when !draft.backfill => const Notice(
            tone: Tone.warning,
            title: 'History stays assumed',
            message:
                'Without backfill, blocks before the starting state are never '
                'checked by this node.',
          ),
          _ => const SizedBox.shrink(),
        },
      ],
    );
  }
}

/// A heading inside a wizard step.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Semantics(
      header: true,
      child: Text(
        text.toUpperCase(),
        style: context.text.labelMedium?.copyWith(
          color: context.colors.muted,
          letterSpacing: 0.6,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

/// What the node offers, from what florestad v0.9.1 can actually do
/// (`bin/florestad/src/cli.rs` at the pinned commit). Only what
/// the app can apply is a control; the rest is said in words.
class _ServicesStep extends StatelessWidget {
  const _ServicesStep({required this.draft, required this.onChanged});

  final NodeSettings draft;
  final ValueChanged<NodeSettings> onChanged;

  @override
  Widget build(BuildContext context) {
    final filters = !draft.disableCompactFilters;
    final start = draft.filtersStartHeight;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('For your wallets'),
        OptionCard(
          icon: Icons.cable_outlined,
          title: 'Electrum server',
          trailingNote: draft.electrumAddress,
          subtitle:
              'Lets Sparrow, Electrum and other wallets on this computer use '
              'your node instead of someone else\'s server.',
          selected: true,
          control: OptionControl.toggle,
        ),
        OptionCard(
          icon: Icons.filter_alt_outlined,
          title: 'Wallet history',
          trailingNote: '(compact block filters)',
          subtitle:
              'Finds past transactions of the wallets you watch. Uses extra '
              'disk space.',
          selected: filters,
          control: OptionControl.toggle,
          onChanged: (v) =>
              onChanged(draft.copyWith(disableCompactFilters: !v)),
        ),
        if (filters && draft.network.isMainnet) ...[
          DropdownButtonFormField<int?>(
            initialValue: draft.walletBirthdayYear,
            decoration: const InputDecoration(
              labelText: 'Wallet history starts in',
              helperText: 'The year your wallet first received coins',
            ),
            items: [
              const DropdownMenuItem<int?>(
                child: Text('Recent only (smallest download)'),
              ),
              for (final y in WalletBirthday.selectableYears)
                DropdownMenuItem<int?>(value: y, child: Text('$y')),
            ],
            onChanged: (y) => onChanged(
              draft.copyWith(walletBirthdayYear: Option.fromNullable(y)),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (filters)
          Text(
            start == null
                ? 'Filters are downloaded for the whole chain.'
                : 'Filters are downloaded from block ${formatInt(start)}. '
                      'Transactions before it are not found.',
            style: context.text.bodySmall,
          )
        else
          const Notice(
            tone: Tone.warning,
            title: 'Wallet history will not work',
            message:
                'Without filters, adding wallets and rescans are not '
                'possible.',
          ),
        const SizedBox(height: 20),
        const _SectionTitle('Node control'),
        OptionCard(
          icon: Icons.settings_remote_outlined,
          title: 'Node API (RPC)',
          trailingNote: '127.0.0.1:${draft.effectiveRpcPort}',
          subtitle:
              'How this app reads the node\'s state and starts or stops '
              'it. It has no password, so it only listens on this computer.',
          selected: true,
          control: OptionControl.toggle,
        ),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              'Not offered in this version',
              style: context.text.bodyMedium,
            ),
            children: const [
              _NotOffered(
                'Electrum over TLS',
                'Wallets on this computer do not need it. Planned.',
              ),
              _NotOffered(
                'Tor or a SOCKS5 proxy',
                'Floresta can send its connections through a proxy, but this '
                    'app also finds Utreexo peers by contacting them '
                    'directly, which would still reveal your IP address. '
                    'Planned once those checks can use the proxy too.',
              ),
              _NotOffered(
                'Remote access to the node',
                'The node API has no password, so it is never offered beyond '
                    'this computer.',
              ),
              _NotOffered(
                'ZeroMQ notifications and Prometheus metrics',
                'Not built into the Floresta this app installs.',
              ),
            ],
          ),
        ),
        Text(
          'You can change these later in Settings. Changes apply the next '
          'time the node starts.',
          style: context.text.bodySmall,
        ),
      ],
    );
  }
}

class _NotOffered extends StatelessWidget {
  const _NotOffered(this.title, this.reason);
  final String title;
  final String reason;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.remove_circle_outline,
          size: 16,
          color: context.colors.muted,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: context.text.bodyMedium),
              Text(reason, style: context.text.bodySmall),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Every choice, grouped by the step it came from, each group with an Edit
/// button back to that step. The draft lives in [SetupStepPage], so going
/// back and forth loses nothing.
class _ReviewStep extends ConsumerWidget {
  const _ReviewStep({
    required this.draft,
    required this.startNow,
    required this.onStartNow,
    required this.onEdit,
  });

  final NodeSettings draft;
  final bool startNow;
  final ValueChanged<bool> onStartNow;

  /// Opens the step with this index.
  final ValueChanged<int> onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final platform = ref.watch(hostPlatformProvider);
    final env = ref.watch(environmentProvider);
    final installation = ref.watch(setupStateProvider).installation;
    final network = draft.network;
    final fastStart = SyncMethodLabels.summary(draft);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReviewGroup(
          title: 'Network',
          onEdit: () => onEdit(0),
          rows: [
            (
              'Follows',
              '${network.label} · '
                  '${network.isMainnet ? 'real bitcoin' : 'test coins, no value'}',
              false,
            ),
          ],
        ),
        _ReviewGroup(
          title: 'Storage',
          onEdit: () => onEdit(1),
          rows: [
            (
              'Data folder',
              draft.effectiveDataDir(
                homeDir: env['HOME'] ?? env['USERPROFILE'],
                separator: platform.pathSeparator,
              ),
              true,
            ),
            ('Old blocks', 'Not kept (pruned)', false),
          ],
        ),
        _ReviewGroup(
          title: 'Sync',
          onEdit: () => onEdit(2),
          rows: [('Sync', fastStart, false)],
        ),
        _ReviewGroup(
          title: 'Services',
          onEdit: () => onEdit(3),
          rows: [
            ('Electrum server', draft.electrumAddress, false),
            (
              'Wallet history',
              draft.disableCompactFilters
                  ? 'Off'
                  : switch (draft.filtersStartHeight) {
                      final h? => 'On, from block ${formatInt(h)}',
                      null => 'On, whole chain',
                    },
              false,
            ),
            (
              'Node API',
              '127.0.0.1:${draft.effectiveRpcPort}, this computer only',
              false,
            ),
          ],
        ),
        if (installation case final i?)
          _ReviewGroup(
            title: 'Floresta',
            rows: [
              ('Version', i.versionLabel, false),
              ('Found', i.source.label, false),
            ],
          ),
        const SizedBox(height: 4),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Start Floresta now'),
          value: startNow,
          onChanged: (v) => onStartNow(v ?? false),
        ),
      ],
    );
  }
}

class _ReviewGroup extends StatelessWidget {
  const _ReviewGroup({required this.title, required this.rows, this.onEdit});

  final String title;

  /// Label, value, monospace.
  final List<(String, String, bool)> rows;

  /// Null: not editable here.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: BoxDecoration(
        border: Border.all(color: context.colors.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(title, style: context.text.titleSmall),
                ),
              ),
              if (onEdit case final edit?)
                Semantics(
                  label: 'Edit ${title.toLowerCase()}',
                  button: true,
                  excludeSemantics: true,
                  child: TextButton(onPressed: edit, child: const Text('Edit')),
                )
              else
                const SizedBox(height: 40),
            ],
          ),
          for (final (label, value, mono) in rows)
            LayoutBuilder(
              builder: (context, c) {
                // Label above value when narrow, beside it otherwise.
                final narrow = c.maxWidth < 420;
                final valueText = SelectableText(
                  value,
                  style: mono ? monoStyle(context) : context.text.bodyMedium,
                );
                return Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 6),
                  child: narrow
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(label, style: context.text.bodySmall),
                            valueText,
                          ],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 140,
                              child: Text(label, style: context.text.bodySmall),
                            ),
                            Expanded(child: valueText),
                          ],
                        ),
                );
              },
            ),
        ],
      ),
    );
  }
}
