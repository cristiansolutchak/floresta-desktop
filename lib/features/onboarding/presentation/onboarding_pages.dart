import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../shared/widgets/common.dart';
import '../../installation/presentation/installation_view.dart';
import '../../settings/domain/node_settings.dart';
import '../../settings/presentation/node_settings_widgets.dart';
import '../../settings/presentation/settings_controller.dart';

/// Centered, step-labelled frame for the first-run flow.
class _OnboardingFrame extends StatelessWidget {
  const _OnboardingFrame({
    required this.step,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final int? step;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Scrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (step != null)
                    Text('STEP $step OF 2', style: context.text.labelSmall),
                  const SizedBox(height: 6),
                  Semantics(
                    header: true,
                    child: Text(title, style: context.text.headlineSmall),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: context.text.bodyMedium?.copyWith(
                      color: context.colors.muted,
                    ),
                  ),
                  const SizedBox(height: 28),
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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

    return _OnboardingFrame(
      step: null,
      title: 'Welcome to Floresta',
      subtitle:
          'Run your own fully validating Bitcoin node, without the '
          'terminal.',
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
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              autofocus: true,
              onPressed: () => context.go('/onboarding/install'),
              child: const Text('Get started'),
            ),
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
    return _OnboardingFrame(
      step: 1,
      title: 'Find Floresta',
      subtitle:
          'This app runs the official florestad program. Let\'s check '
          'whether it is installed.',
      child: InstallationView(
        primaryAction: FilledButton(
          onPressed: () => context.go('/onboarding/setup'),
          child: const Text('Continue'),
        ),
      ),
    );
  }
}

class SetupStepPage extends ConsumerStatefulWidget {
  const SetupStepPage({super.key});

  @override
  ConsumerState<SetupStepPage> createState() => _SetupStepPageState();
}

class _SetupStepPageState extends ConsumerState<SetupStepPage> {
  late NodeSettings _draft = ref.read(settingsControllerProvider);
  bool _saving = false;

  Future<void> _finish() async {
    setState(() => _saving = true);
    final result = await ref
        .read(settingsControllerProvider.notifier)
        .update(_draft.copyWith(onboardingComplete: true));
    if (!mounted) return;
    setState(() => _saving = false);
    result.fold((f) => showFailure(context, f), (_) => context.go('/node'));
  }

  @override
  Widget build(BuildContext context) {
    return _OnboardingFrame(
      step: 2,
      title: 'Set up your node',
      subtitle: 'You can change all of this later in Settings.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NetworkSelector(
            value: _draft.network,
            onChanged: (n) =>
                setState(() => _draft = _draft.copyWith(network: n)),
          ),
          const SizedBox(height: 16),
          DataDirSelector(
            settings: _draft,
            onChanged: (dir) => setState(
              () => _draft = _draft.copyWith(dataDir: Option.fromNullable(dir)),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              TextButton(
                onPressed: () => context.go('/onboarding/install'),
                child: const Text('Back'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _saving ? null : _finish,
                child: const Text('Finish setup'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
