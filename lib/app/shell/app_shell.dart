import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/build_flavor.dart';
import '../../features/node/domain/node_status.dart';
import '../../features/node/presentation/node_controller.dart';
import '../../features/node/presentation/status_labels.dart';
import '../../features/settings/presentation/settings_controller.dart';
import '../../shared/widgets/common.dart';
import '../theme/app_theme.dart';

class _Destination {
  const _Destination(this.path, this.label, this.icon, this.key);
  final String path;
  final String label;
  final IconData icon;
  final LogicalKeyboardKey key;
}

const _destinations = [
  _Destination('/node', 'Node', Icons.dns_outlined, LogicalKeyboardKey.digit1),
  _Destination(
    '/wallet',
    'Wallet',
    Icons.account_balance_wallet_outlined,
    LogicalKeyboardKey.digit2,
  ),
  _Destination(
    '/installation',
    'Installation',
    Icons.download_for_offline_outlined,
    LogicalKeyboardKey.digit3,
  ),
  _Destination('/settings', 'Settings', Icons.tune, LogicalKeyboardKey.digit4),
];

/// Sidebar layout for the main app. Cmd/Ctrl+1…4 switch sections.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMac = Theme.of(context).platform == TargetPlatform.macOS;
    return CallbackShortcuts(
      bindings: {
        for (final d in _destinations)
          SingleActivator(d.key, meta: isMac, control: !isMac): () =>
              context.go(d.path),
      },
      child: Scaffold(
        body: Row(
          children: [
            _Sidebar(location: location),
            VerticalDivider(width: 1, color: context.colors.border),
            Expanded(child: FocusTraversalGroup(child: child)),
          ],
        ),
      ),
    );
  }
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.location});
  final String location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(nodeControllerProvider);
    final network = ref.watch(
      settingsControllerProvider.select((s) => s.network),
    );
    final summary = status.api == ApiReachability.reachable
        ? StatusLabels.readiness(ref.watch(nodeReadinessProvider), status)
        : StatusLabels.process(status);

    return Container(
      width: 224,
      color: context.colors.sidebar,
      padding: const EdgeInsets.fromLTRB(12, 20, 12, 16),
      child: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Icon(
                    Icons.forest_outlined,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text('Floresta', style: context.text.titleMedium),
                ],
              ),
            ),
            const SizedBox(height: 24),
            for (final d in _destinations)
              _NavItem(destination: d, selected: location.startsWith(d.path)),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('NETWORK', style: context.text.labelSmall),
                  const SizedBox(height: 6),
                  // Always visible: which chain this app is driving.
                  Semantics(
                    label: 'Active network: ${network.label}',
                    child: StatusIndicator(
                      label: network.label,
                      caption: network.isMainnet
                          ? 'Real bitcoin'
                          : 'Test network: coins have no value',
                      tone: network.isMainnet ? Tone.info : Tone.warning,
                    ),
                  ),
                  if (ref.watch(buildFlavorProvider) ==
                      BuildFlavor.development) ...[
                    const SizedBox(height: 6),
                    Text('Development build', style: context.text.bodySmall),
                  ],
                  const SizedBox(height: 14),
                  Text('NODE', style: context.text.labelSmall),
                  const SizedBox(height: 6),
                  StatusIndicator(
                    label: summary.label,
                    caption: summary.caption,
                    tone: summary.tone,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.destination, required this.selected});
  final _Destination destination;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected
              ? scheme.primary.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => context.go(destination.path),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                children: [
                  Icon(
                    destination.icon,
                    size: 18,
                    color: selected ? scheme.primary : context.colors.muted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      destination.label,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodyMedium?.copyWith(
                        fontWeight: selected ? FontWeight.w600 : null,
                        color: selected ? scheme.primary : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
