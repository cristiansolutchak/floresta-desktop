import 'dart:math' as math;

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
import '../../features/installation/presentation/update_bar.dart';
import '../../features/installation/presentation/update_controller.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/dash.dart';
import '../../shared/widgets/status_motion.dart';
import '../brand/brand_symbol.dart';
import '../theme/dash_tokens.dart';
import 'sidebar_preference.dart';
import 'window_chrome.dart';

class _Destination {
  const _Destination(this.path, this.label, this.key, {required this.asset});
  final String path;
  final String label;

  /// Cmd/Ctrl+digit shortcut; Help has none (only 1…9 exist).
  final LogicalKeyboardKey? key;

  /// Sidebar icon (Figma, and `installation.svg` for Installation).
  final String asset;
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
    asset: DashIcons.installation,
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
    // Checks for updates at start and periodically (ADR-0012).
    ref.watch(updateControllerProvider);
    final isMac = Theme.of(context).platform == TargetPlatform.macOS;
    final current = _destinations.firstWhere(
      (d) => location.startsWith(d.path),
      orElse: () => _destinations.first,
    );
    return CallbackShortcuts(
      bindings: {
        // Cmd/Ctrl+\ collapses or expands the sidebar.
        SingleActivator(
          LogicalKeyboardKey.backslash,
          meta: isMac,
          control: !isMac,
        ): () =>
            ref.read(sidebarCompactProvider.notifier).toggle(),
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
                  const UpdateBar(),
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

/// Expanded: icons and labels. Compact: icons only, labels in tooltips. One
/// sidebar with two widths, animated between them; each part picks its
/// layout from the width it actually has, so nothing overflows mid-way.
class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.location});
  final String location;

  static const compactWidth = 80.0;

  /// Narrower than this, the parts switch to their icon-only layout.
  static const _labelsFrom = 180.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.dash;
    final size = MediaQuery.sizeOf(context);
    final compactPref = ref.watch(sidebarCompactProvider);
    final width = compactPref
        ? math.max(compactWidth, WindowChrome.controlsWidth(context))
        : (size.width >= 1360 ? 328.0 : 264.0);
    final short = size.height < 820;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedContainer(
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 220),
      curve: Curves.easeInOutCubic,
      width: width,
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(right: BorderSide(color: t.border)),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final iconsOnly = box.maxWidth < _labelsFrom;
          final pad = iconsOnly ? 12.0 : (box.maxWidth > 300 ? 32.0 : 20.0);
          // Below the macOS window buttons (WindowChrome).
          final top = math.max(
            short ? 20.0 : 32.0,
            WindowChrome.topInset(context) + (iconsOnly ? 16 : 4),
          );
          return FocusTraversalGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(pad, top, pad, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _SidebarLogo(iconsOnly: iconsOnly),
                        SizedBox(height: short ? 16 : 32),
                        for (final d in _destinations)
                          _NavItem(
                            compact: short,
                            iconsOnly: iconsOnly,
                            destination: d,
                            selected: location.startsWith(d.path),
                          ),
                        // Decorative: dropped on short windows so every
                        // destination fits without scrolling, and when
                        // compact.
                        if (!short && !iconsOnly) ...[
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
                  padding: EdgeInsets.fromLTRB(pad, 16, pad, 20),
                  child: _SidebarFooter(iconsOnly: iconsOnly),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SidebarLogo extends StatelessWidget {
  const _SidebarLogo({required this.iconsOnly});
  final bool iconsOnly;

  @override
  Widget build(BuildContext context) {
    final color = context.dash.textPrimary;
    return Semantics(
      label: 'Floresta',
      excludeSemantics: true,
      child: AnimatedSwitcher(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        child: iconsOnly
            // The symbol alone, from the same geometry as the app icon.
            ? Center(
                key: const ValueKey('symbol'),
                child: SizedBox(
                  width: 30,
                  height: 30 * BrandSymbol.height / BrandSymbol.width,
                  child: CustomPaint(
                    painter: BrandSymbolPainter(
                      color: color,
                      progress: List.filled(BrandSymbol.blocks.length, 1),
                    ),
                  ),
                ),
              )
            : Align(
                key: const ValueKey('logo'),
                alignment: Alignment.centerLeft,
                child: SvgPicture.asset(
                  DashIcons.logo,
                  height: 40,
                  colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                ),
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
    this.iconsOnly = false,
  });
  final _Destination destination;
  final bool selected;

  /// 40 px items on short windows (10 destinations must fit at 640 px).
  final bool compact;

  /// The compact sidebar: the icon centred, the label in a tooltip.
  final bool iconsOnly;

  @override
  Widget build(BuildContext context) {
    final t = context.dash;
    final color = selected ? t.brand : t.textSecondary;
    final glyph = dashGlyph(
      context,
      asset: destination.asset,
      size: compact ? 20 : 24,
      color: color,
    );
    final item = Semantics(
      selected: selected,
      button: true,
      label: iconsOnly ? destination.label : null,
      child: Material(
        color: selected ? t.sidebarActive : Colors.transparent,
        child: InkWell(
          onTap: () => context.go(destination.path),
          child: SizedBox(
            height: compact ? 40 : 56,
            child: iconsOnly
                ? Center(child: glyph)
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        glyph,
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            destination.label,
                            maxLines: 1,
                            overflow: TextOverflow.fade,
                            softWrap: false,
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
    return iconsOnly
        ? Tooltip(
            message: destination.label,
            preferBelow: false,
            verticalOffset: 0,
            margin: const EdgeInsets.only(left: 64),
            excludeFromSemantics: true,
            child: item,
          )
        : item;
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
/// always visible), the development build marker and the compact toggle.
/// Compact: the status dot and the network as one tooltip.
class _SidebarFooter extends ConsumerWidget {
  const _SidebarFooter({required this.iconsOnly});
  final bool iconsOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.dash;
    final status = ref.watch(nodeControllerProvider);
    final network = ref.watch(
      settingsControllerProvider.select((s) => s.network),
    );
    final compact = ref.watch(sidebarCompactProvider);
    final version = switch (ref.watch(nextActionProvider).value) {
      OpenNodeManagement(:final installation) ||
      ConfigureNode(:final installation) ||
      UpdateFloresta(:final installation) => installation.versionLabel,
      _ => null,
    };
    final online = status.api == ApiReachability.reachable;
    final process = StatusLabels.process(status);
    final label = online ? 'Online' : process.label;
    final tone = online ? DashTone.success : DashToneColors.of(process.tone);
    final dot = StatusDot(tone: tone, active: process.tone == Tone.warning);
    final toggle = IconButton(
      tooltip: compact ? 'Expand sidebar' : 'Collapse sidebar',
      onPressed: ref.read(sidebarCompactProvider.notifier).toggle,
      icon: Icon(
        compact
            ? Icons.keyboard_double_arrow_right
            : Icons.keyboard_double_arrow_left,
        size: 20,
        color: t.textSecondary,
      ),
    );
    if (iconsOnly) {
      final summary = [
        label,
        ?version,
        network.label,
        if (!network.isMainnet) 'test network',
      ].join(' · ');
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: summary,
            child: Semantics(
              label: summary,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    dot,
                    const SizedBox(height: 8),
                    Text(
                      network.isMainnet ? 'Main' : network.label,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: DashText.small(
                        context,
                        color: network.isMainnet ? t.info : t.warningText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          toggle,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            dot,
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
            const Spacer(),
            toggle,
          ],
        ),
        const SizedBox(height: 8),
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
    final electrum = ref.watch(
      settingsControllerProvider.select((s) => s.electrumAddress),
    );
    final short = StatusLabels.short(readiness, status);
    final tone = DashToneColors.of(short.tone);
    // Where wallets reach the node's Electrum server (NodeSettings explains
    // why it is the network default on loopback).
    final endpoint = 'tcp://$electrum';
    final chain = status.chain;

    // Title on the left; status, figures and actions together on the right.
    // The right group is the only flexible child and sizes to its content,
    // so all free space sits between the two (spaceBetween) and the group
    // always ends at the right edge. Inside it, only the figures can shrink
    // (with ellipses), so a long status never pushes the actions off.
    Widget meta(String asset, String text) => Flexible(
      child: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DashSvg(asset, size: 16, color: t.textSecondary),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DashText.small(context),
              ),
            ),
          ],
        ),
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
          // Below these widths the figures would show only as ellipses.
          final showHeight = c.maxWidth >= 760;
          final showBehind = c.maxWidth >= 900;
          // Narrow windows: the actions become icons (with tooltips, so they
          // stay labelled) rather than pushing past the edge.
          final iconActions = c.maxWidth < 760;
          Future<void> copyEndpoint() async {
            await Clipboard.setData(ClipboardData(text: endpoint));
            if (context.mounted) showMessage(context, 'Copied $endpoint');
          }

          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: c.maxWidth * 0.3),
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DashText.title(context),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StatusSwap(
                      stateKey: short.label,
                      child: DashTag(
                        short.label,
                        tone: tone,
                        leading: tone == DashTone.neutral
                            ? null
                            : statusGlyph(
                                context,
                                tone: tone,
                                active: StatusLabels.isActive(short),
                                size: 12,
                                color: tone.colors(context).fg,
                              ),
                      ),
                    ),
                    if (showHeight && chain != null)
                      meta(
                        DashIcons.height,
                        'Height: ${formatInt(chain.headerHeight)}',
                      ),
                    if (progress case final p?
                        when showBehind && chain != null && p.behind > 0)
                      meta(
                        DashIcons.behindBy,
                        'Behind by: ${p.tipIsEstimate ? '~' : ''}'
                        '${formatCompact(p.behind)}',
                      ),
                    Container(
                      width: 1,
                      height: 32,
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      color: t.border,
                    ),
                    if (iconActions) ...[
                      IconButton(
                        tooltip: 'Copy Endpoint: $endpoint',
                        onPressed: copyEndpoint,
                        icon: DashSvg(
                          DashIcons.copy,
                          size: 20,
                          color: t.textSecondary,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Logs',
                        onPressed: () => context.go('/logs'),
                        icon: DashSvg(
                          DashIcons.logs,
                          size: 20,
                          color: t.textSecondary,
                        ),
                      ),
                    ] else ...[
                      DashButton(
                        'Copy Endpoint',
                        height: 32,
                        asset: DashIcons.copy,
                        tooltip:
                            'Copy the Electrum address for wallets: $endpoint',
                        onPressed: copyEndpoint,
                      ),
                      const SizedBox(width: 8),
                      DashButton(
                        'Logs',
                        height: 32,
                        asset: DashIcons.logs,
                        onPressed: () => context.go('/logs'),
                      ),
                    ],
                    const SizedBox(width: 12),
                    IconButton(
                      tooltip: 'Settings',
                      onPressed: () => context.go('/settings'),
                      icon: DashSvg(
                        DashIcons.gear,
                        size: 24,
                        color: t.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
