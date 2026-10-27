import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../core/build_flavor.dart';
import '../../features/installation/domain/next_action.dart';
import '../../features/installation/presentation/installation_providers.dart';
import '../../features/node/domain/node_status.dart';
import '../../features/node/presentation/node_controller.dart';
import '../../features/node/presentation/status_labels.dart';
import '../../features/settings/presentation/settings_controller.dart';
import '../../features/node/presentation/utreexo_peer_controller.dart';
import '../../features/wallet/presentation/wallet_rescan_controller.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/dash.dart';
import '../theme/dash_tokens.dart';

class _Destination {
  const _Destination(this.path, this.label, this.key, {this.asset, this.icon});
  final String path;
  final String label;

  /// Cmd/Ctrl+digit shortcut; Help has none (only 1…9 exist).
  final LogicalKeyboardKey? key;

  /// Figma sidebar icon; Installation has none and uses [icon].
  final String? asset;
  final IconData? icon;
}

/// The Figma sidebar order (Overview, Sync, Peers, Wallet, RPC Console,
/// Electrum, Logs, Settings, Help), plus Installation, which has no Figma
/// frame yet.
const _destinations = [
  _Destination(
    '/node',
    'Overview',
    LogicalKeyboardKey.digit1,
    asset: DashIcons.overview,
  ),
  _Destination(
    '/sync',
    'Sync',
    LogicalKeyboardKey.digit2,
    asset: DashIcons.sync,
  ),
  _Destination(
    '/peers',
    'Peers',
    LogicalKeyboardKey.digit3,
    asset: DashIcons.peersNav,
  ),
  _Destination(
    '/wallet',
    'Wallet',
    LogicalKeyboardKey.digit4,
    asset: DashIcons.wallet,
  ),
  _Destination(
    '/rpc',
    'RPC Console',
    LogicalKeyboardKey.digit5,
    asset: DashIcons.rpcConsole,
  ),
  _Destination(
    '/electrum',
    'Electrum',
    LogicalKeyboardKey.digit6,
    asset: DashIcons.electrum,
  ),
  _Destination(
    '/logs',
    'Logs',
    LogicalKeyboardKey.digit7,
    asset: DashIcons.logsNav,
  ),
  _Destination(
    '/installation',
    'Installation',
    LogicalKeyboardKey.digit8,
    icon: Icons.download_for_offline_outlined,
  ),
  _Destination(
    '/settings',
    'Settings',
    LogicalKeyboardKey.digit9,
    asset: DashIcons.settings,
  ),
  _Destination('/help', 'Help', null, asset: DashIcons.help),
];

/// Dashboard layout from Figma: 328 px sidebar, 82 px header bar, content.
/// Cmd/Ctrl+1…9 switch sections.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keeps the rescan schedule running on every screen, not only Wallet.
    ref.watch(walletRescanProvider);
    // Keeps the Utreexo peer search alive while the app runs (SYNC-05).
    ref.watch(utreexoPeerSearchProvider);
    final isMac = Theme.of(context).platform == TargetPlatform.macOS;
    final current = _destinations.firstWhere(
      (d) => location.startsWith(d.path),
      orElse: () => _destinations.first,
    );
    return CallbackShortcuts(
      bindings: {
        for (final d in _destinations)
          if (d.key case final key?)
            SingleActivator(key, meta: isMac, control: !isMac): () =>
                context.go(d.path),
      },
      child: Scaffold(
        backgroundColor: context.dash.page,
        body: Row(
          children: [
            _Sidebar(location: location),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _HeaderBar(title: current.label),
                  Expanded(
                    child: ShellTitleScope(
                      child: Theme(
                        data: _dashButtons(Theme.of(context), context.dash),
                        child: FocusTraversalGroup(child: child),
                      ),
                    ),
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

/// Material buttons inside the dashboard look like its own buttons
/// (DashButton): square corners, black primary, outlined secondary.
ThemeData _dashButtons(ThemeData base, DashTokens t) {
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(2));
  return base.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: t.primaryButton,
        foregroundColor: t.onPrimaryButton,
        shape: shape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: t.textPrimary,
        side: BorderSide(color: t.borderStrong),
        shape: shape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: t.textPrimary, shape: shape),
    ),
  );
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.location});
  final String location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.dash;
    final size = MediaQuery.sizeOf(context);
    final width = size.width >= 1360 ? 328.0 : 264.0;
    final compact = size.height < 820;
    final pad = width > 300 ? 32.0 : 20.0;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(right: BorderSide(color: t.border)),
      ),
      child: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(pad, compact ? 20 : 32, pad, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Semantics(
                        label: 'Floresta',
                        excludeSemantics: true,
                        child: SvgPicture.asset(
                          DashIcons.logo,
                          height: 40,
                          colorFilter: ColorFilter.mode(
                            t.textPrimary,
                            BlendMode.srcIn,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: compact ? 16 : 32),
                    for (final d in _destinations)
                      _NavItem(
                        compact: compact,
                        destination: d,
                        selected: location.startsWith(d.path),
                      ),
                    // Decorative: dropped on short windows so every
                    // destination fits without scrolling.
                    if (!compact) ...[
                      const SizedBox(height: 48),
                      const _ValidationCard(),
                    ],
                  ],
                ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: t.border)),
              ),
              padding: EdgeInsets.fromLTRB(pad, 20, pad, 24),
              child: const _SidebarFooter(),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.destination,
    required this.selected,
    this.compact = false,
  });
  final _Destination destination;
  final bool selected;

  /// 40 px items on short windows (10 destinations must fit at 640 px).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = context.dash;
    final color = selected ? t.brand : t.textSecondary;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? t.sidebarActive : Colors.transparent,
        child: InkWell(
          onTap: () => context.go(destination.path),
          child: SizedBox(
            height: compact ? 40 : 56,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  dashGlyph(
                    context,
                    icon: destination.icon,
                    asset: destination.asset,
                    size: compact ? 20 : 24,
                    color: color,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      destination.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: selected ? t.brand : t.textPrimary,
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

class _ValidationCard extends StatelessWidget {
  const _ValidationCard();

  @override
  Widget build(BuildContext context) {
    final t = context.dash;
    return Container(
      padding: const EdgeInsets.all(12),
      color: t.subtle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DashIconBlock.asset(
            DashIcons.shieldTick,
            size: 24,
            iconSize: 16,
            color: t.textSecondary,
          ),
          const SizedBox(height: 16),
          Text(
            'Self-Sovereign Validation',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: t.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'Your Floresta node checks Bitcoin consensus rules locally '
            'instead of trusting third-party explorers.',
            style: DashText.body(context),
          ),
        ],
      ),
    );
  }
}

/// "Online · v0.9.1", plus the network the app drives (owner decision 3:
/// always visible) and the development build marker.
class _SidebarFooter extends ConsumerWidget {
  const _SidebarFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.dash;
    final status = ref.watch(nodeControllerProvider);
    final network = ref.watch(
      settingsControllerProvider.select((s) => s.network),
    );
    final version = switch (ref.watch(nextActionProvider).value) {
      OpenNodeManagement(:final installation) ||
      ConfigureNode(:final installation) ||
      UpdateFloresta(:final installation) => installation.version.toString(),
      _ => null,
    };
    final online = status.api == ApiReachability.reachable;
    final process = StatusLabels.process(status);
    final label = online ? 'Online' : process.label;
    final tone = online ? DashTone.success : DashToneColors.of(process.tone);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: t.textPrimary,
                ),
              ),
            ),
            if (version != null) ...[
              const SizedBox(width: 8),
              DashTag(version, tone: DashTone.neutral),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Semantics(
          label: 'Active network: ${network.label}',
          excludeSemantics: true,
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DashTag(
                network.label,
                tone: network.isMainnet ? DashTone.info : DashTone.warning,
              ),
              Text(
                network.isMainnet
                    ? 'Real bitcoin'
                    : 'Test network: coins have no value',
                style: DashText.small(context),
              ),
            ],
          ),
        ),
        if (ref.watch(buildFlavorProvider) == BuildFlavor.development) ...[
          const SizedBox(height: 6),
          Text('Development build', style: DashText.small(context)),
        ],
      ],
    );
  }
}

/// Title, sync status, height, behind count, Copy Endpoint, Logs, settings.
class _HeaderBar extends ConsumerWidget {
  const _HeaderBar({required this.title});
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.dash;
    final status = ref.watch(nodeControllerProvider);
    final readiness = ref.watch(nodeReadinessProvider);
    final progress = ref.watch(syncProgressProvider);
    final network = ref.watch(
      settingsControllerProvider.select((s) => s.network),
    );
    final short = StatusLabels.short(readiness, status);
    final tone = DashToneColors.of(short.tone);
    final endpoint = 'tcp://127.0.0.1:${network.electrumPort}';
    final chain = status.chain;

    Widget meta(String asset, String text) => Flexible(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DashSvg(asset, size: 16, color: t.textSecondary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: DashText.small(context),
            ),
          ),
        ],
      ),
    );

    return Container(
      height: 82,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          final roomy = c.maxWidth >= 860;
          return Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: DashText.title(context),
                  ),
                ),
              ),
              DashTag(
                short.label,
                tone: tone,
                asset: tone == DashTone.warning
                    ? DashIcons.headerSyncing
                    : null,
                icon: switch (tone) {
                  DashTone.success => Icons.check,
                  DashTone.danger => Icons.error_outline,
                  _ => null,
                },
              ),
              if (roomy && chain != null) ...[
                const SizedBox(width: 12),
                meta(
                  DashIcons.height,
                  'Height: ${formatInt(chain.headerHeight)}',
                ),
                if (progress case final p? when p.behind > 0) ...[
                  const SizedBox(width: 12),
                  meta(
                    DashIcons.behindBy,
                    'Behind by: ${p.tipIsEstimate ? '~' : ''}'
                    '${formatCompact(p.behind)}',
                  ),
                ],
              ],
              Container(
                width: 1,
                height: 32,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                color: t.border,
              ),
              DashButton(
                'Copy Endpoint',
                height: 32,
                asset: DashIcons.copy,
                tooltip: 'Copy the Electrum address for wallets: $endpoint',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: endpoint));
                  if (context.mounted) {
                    showMessage(context, 'Copied $endpoint');
                  }
                },
              ),
              const SizedBox(width: 8),
              DashButton(
                'Logs',
                height: 32,
                asset: DashIcons.logs,
                onPressed: () => context.go('/logs'),
              ),
              const SizedBox(width: 12),
              IconButton(
                tooltip: 'Settings',
                onPressed: () => context.go('/settings'),
                icon: DashSvg(DashIcons.gear, size: 24, color: t.textSecondary),
              ),
            ],
          );
        },
      ),
    );
  }
}
