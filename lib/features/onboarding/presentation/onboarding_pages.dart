import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/build_flavor.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/common.dart';
import '../../installation/presentation/installation_view.dart';
import '../../node/domain/preflight.dart';
import '../../node/presentation/node_controller.dart';
import '../../node/presentation/status_labels.dart';
import '../../settings/domain/bitcoin_network.dart';
import '../../settings/domain/node_settings.dart';
import '../../settings/domain/wallet_birthday.dart';
import '../../settings/presentation/settings_controller.dart';
import 'wizard_widgets.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    Widget point(IconData icon, String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.text.titleMedium),
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
          'Run your own fully validating Bitcoin node, without the '
          'terminal.',
      primary: FilledButton(
        autofocus: true,
        onPressed: () => context.go('/onboarding/install'),
        child: const Text('Get started'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          point(
            Icons.verified_outlined,
            'Verify, don\'t trust',
            'Floresta checks every rule of Bitcoin itself, using a compact '
                'representation of the chain state (Utreexo) so it needs far '
                'less disk space than a traditional node.',
          ),
          point(
            Icons.visibility_outlined,
            'Watch your wallets privately',
            'Track wallets by their public descriptors. Your keys stay in '
                'your wallet; this app never asks for them.',
          ),
          point(
            Icons.cable_outlined,
            'Connect the wallets you already use',
            'Sparrow, Electrum and other wallets can use your node instead of '
                'someone else\'s server.',
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
      title: 'Find Floresta',
      subtitle:
          'This app runs the official florestad program. Let\'s check '
          'whether it is installed.',
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

/// The configuration wizard (Figma "Setup Wizard"): four steps and a review.
/// Edits a draft; nothing is saved until Finish.
class SetupStepPage extends ConsumerStatefulWidget {
  const SetupStepPage({super.key});

  static const steps = ['Network', 'Storage', 'Fast Start', 'Services'];

  @override
  ConsumerState<SetupStepPage> createState() => _SetupStepPageState();
}

class _SetupStepPageState extends ConsumerState<SetupStepPage> {
  late NodeSettings _draft = ref.read(settingsControllerProvider);
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
        'Fast start',
        'How the node gets to the tip of the chain.',
        _FastStartStep(draft: _draft, onChanged: _edit),
      ),
      3 => (
        'Services',
        'What your node offers to the wallets on this computer.',
        _ServicesStep(draft: _draft, onChanged: _edit),
      ),
      _ => (
        'Ready to start',
        'Check your choices. You can change all of them later in Settings.',
        _ReviewStep(
          draft: _draft,
          startNow: _startNow,
          onStartNow: (v) => setState(() => _startNow = v),
        ),
      ),
    };
    return WizardFrame(
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
  // Owner decision 3: test networks are advanced, open in development
  // builds or when one is already chosen.
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

class _FastStartStep extends StatelessWidget {
  const _FastStartStep({required this.draft, required this.onChanged});

  final NodeSettings draft;
  final ValueChanged<NodeSettings> onChanged;

  @override
  Widget build(BuildContext context) {
    final height = draft.network.assumeUtreexoHeight;
    if (height == 0) {
      return Notice(
        tone: Tone.info,
        title: 'Validates from the first block',
        message:
            'Floresta has no built-in starting state for '
            '${draft.network.label}, so it checks the whole chain. On this '
            'network that is quick.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OptionCard(
          title: 'Assume Utreexo',
          trailingNote: '(recommended)',
          subtitle:
              'Start from the chain state built into Floresta at block '
              '${formatInt(height)}, so the node is usable in minutes '
              'instead of days.',
          selected: draft.assumeUtreexo,
          control: OptionControl.checkbox,
          onChanged: (v) => onChanged(draft.copyWith(assumeUtreexo: v)),
        ),
        OptionCard(
          title: 'Backfill in background',
          trailingNote: '(recommended)',
          subtitle:
              'Afterwards, re-check every block before ${formatInt(height)} '
              'so nothing stays assumed.',
          selected: draft.assumeUtreexo && draft.backfill,
          control: OptionControl.checkbox,
          onChanged: draft.assumeUtreexo
              ? (v) => onChanged(draft.copyWith(backfill: v))
              : null,
        ),
        if (!draft.assumeUtreexo)
          const Notice(
            tone: Tone.warning,
            title: 'Starting from the first block is slow',
            message:
                'Floresta needs peers that serve Utreexo proofs for the whole '
                'history. Few exist, so getting to the tip can take days.',
          )
        else if (!draft.backfill)
          const Notice(
            tone: Tone.warning,
            title: 'History stays assumed',
            message:
                'Without backfill, blocks before the starting state are never '
                'checked by this node.',
          ),
      ],
    );
  }
}

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
        OptionCard(
          icon: Icons.cable_outlined,
          title: 'Electrum server',
          trailingNote: '127.0.0.1:${draft.network.electrumPort}',
          subtitle:
              'Lets Sparrow, Electrum and other wallets on this computer use '
              'your node. Floresta always runs it, only on this computer.',
          selected: true,
          control: OptionControl.toggle,
        ),
        OptionCard(
          icon: Icons.filter_alt_outlined,
          title: 'Watch-only wallet index',
          trailingNote: '(compact block filters)',
          subtitle:
              'Needed to find past transactions of the wallets you watch. '
              'Uses extra disk space.',
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
        const SizedBox(height: 12),
        Text(
          'Remote access to the node is not offered: its API has no password, '
          'so it only listens on this computer.',
          style: context.text.bodySmall,
        ),
      ],
    );
  }
}

class _ReviewStep extends ConsumerWidget {
  const _ReviewStep({
    required this.draft,
    required this.startNow,
    required this.onStartNow,
  });

  final NodeSettings draft;
  final bool startNow;
  final ValueChanged<bool> onStartNow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final platform = ref.watch(hostPlatformProvider);
    final env = ref.watch(environmentProvider);
    final mode = draft.snapshotHeight == 0
        ? 'Pruned, full validation'
        : 'Pruned, Assume Utreexo'
              '${draft.backfill ? ' with backfill' : ', no backfill'}';
    final rows = <(String, String)>[
      ('Network', draft.network.label),
      ('Mode', mode),
      ('Electrum', '127.0.0.1:${draft.network.electrumPort}'),
      (
        'Watch-only wallet index',
        draft.disableCompactFilters
            ? 'Off'
            : switch (draft.filtersStartHeight) {
                final h? => 'On, from block ${formatInt(h)}',
                null => 'On, whole chain',
              },
      ),
      (
        'Storage',
        draft.effectiveDataDir(
          homeDir: env['HOME'] ?? env['USERPROFILE'],
          separator: platform.pathSeparator,
        ),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (k, v) in rows) KeyValueRow(k, v),
        const SizedBox(height: 12),
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
