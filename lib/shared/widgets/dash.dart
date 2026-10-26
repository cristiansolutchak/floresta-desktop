import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../app/theme/dash_tokens.dart';
import 'common.dart';

/// Building blocks of the Figma dashboard (Overview and Sync frames). Sizes
/// are the frame's, in logical pixels: 24 card padding, 48 icon blocks,
/// 12 progress bars, 32/40/48 buttons, square corners on cards and buttons.

/// Text styles of the frame (FK Grotesk in Figma; the system font here until
/// a licensed substitute is chosen, DS-03).
abstract final class DashText {
  static TextStyle title(BuildContext c) => TextStyle(
    fontSize: 24,
    height: 1.4,
    fontWeight: FontWeight.w500,
    color: c.dash.textPrimary,
  );

  static TextStyle cardTitle(BuildContext c) => TextStyle(
    fontSize: 18,
    height: 1.3,
    fontWeight: FontWeight.w500,
    color: c.dash.textPrimary,
  );

  static TextStyle big(BuildContext c) => TextStyle(
    fontSize: 32,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: c.dash.textPrimary,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  static TextStyle body(BuildContext c, {Color? color, FontWeight? weight}) =>
      TextStyle(
        fontSize: 14,
        height: 1.4,
        fontWeight: weight ?? FontWeight.w400,
        color: color ?? c.dash.textSecondary,
      );

  static TextStyle value(BuildContext c, {Color? color}) => TextStyle(
    fontSize: 14,
    height: 1.4,
    fontWeight: FontWeight.w500,
    color: color ?? c.dash.textPrimary,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  static TextStyle small(BuildContext c, {Color? color}) => TextStyle(
    fontSize: 12,
    height: 1.4,
    fontWeight: FontWeight.w500,
    color: color ?? c.dash.textSecondary,
  );
}

/// The Figma file's icons and logo (`assets/`, exported from the dashboard
/// frames). All are single-colour, so [DashSvg] tints them for the theme.
abstract final class DashIcons {
  static const logo = 'assets/logo-icon-text.svg';
  static const overview = 'assets/icons/sidebar/overview.svg';
  static const sync = 'assets/icons/sidebar/sync.svg';
  static const wallet = 'assets/icons/sidebar/wallet.svg';
  static const settings = 'assets/icons/sidebar/settings.svg';
  static const peersNav = 'assets/icons/sidebar/peers.svg';
  static const rpcConsole = 'assets/icons/sidebar/rpc-console.svg';
  static const electrum = 'assets/icons/sidebar/electrum.svg';
  static const logsNav = 'assets/icons/sidebar/logs.svg';
  static const help = 'assets/icons/sidebar/help.svg';
  static const shieldTick = 'assets/icons/sidebar/shield-tick.svg';
  static const headerSyncing = 'assets/icons/overview/header/syncing.svg';
  static const height = 'assets/icons/overview/header/height.svg';
  static const behindBy = 'assets/icons/overview/header/behind-by.svg';
  static const copy = 'assets/icons/overview/header/copy.svg';
  static const logs = 'assets/icons/overview/header/logs.svg';
  static const gear = 'assets/icons/overview/header/settings.svg';
  static const activeServices =
      'assets/icons/overview/body/active-services.svg';
  static const statusSyncing = 'assets/icons/overview/body/status-syncing.svg';
  static const syncingIbd = 'assets/icons/overview/body/syncing-ibd.svg';
  static const backfill = 'assets/icons/overview/body/backfill.svg';
  static const peers = 'assets/icons/overview/body/peers.svg';
  static const helpCircle = 'assets/icons/overview/body/help-circle.svg';
}

/// A Figma SVG drawn in one theme colour (the files hard-code light-theme
/// strokes). Decorative: the label next to it carries the meaning.
class DashSvg extends StatelessWidget {
  const DashSvg(this.asset, {super.key, this.size = 24, this.color});

  final String asset;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    asset,
    width: size,
    height: size,
    excludeFromSemantics: true,
    colorFilter: ColorFilter.mode(
      color ?? context.dash.textPrimary,
      BlendMode.srcIn,
    ),
  );
}

/// A Material icon or a Figma SVG, for widgets that take either.
Widget dashGlyph(
  BuildContext context, {
  IconData? icon,
  String? asset,
  required double size,
  Color? color,
}) => asset != null
    ? DashSvg(asset, size: size, color: color)
    : Icon(icon, size: size, color: color ?? context.dash.textPrimary);

/// White card with a 1 px border and square corners.
class DashCard extends StatelessWidget {
  const DashCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
    this.color,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final t = context.dash;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? t.surface,
        border: Border.all(color: borderColor ?? t.border),
      ),
      child: child,
    );
  }
}

/// Outlined square holding a card's icon (48 in cards, 32 in the banner).
class DashIconBlock extends StatelessWidget {
  const DashIconBlock(
    IconData this.icon, {
    super.key,
    this.size = 48,
    this.iconSize,
    this.color,
    this.borderColor,
  }) : asset = null;

  /// A Figma icon; drawn at two thirds of the block like the frame (32/48).
  const DashIconBlock.asset(
    String this.asset, {
    super.key,
    this.size = 48,
    this.iconSize,
    this.color,
    this.borderColor,
  }) : icon = null;

  final IconData? icon;
  final String? asset;
  final double size;
  final double? iconSize;
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final t = context.dash;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: borderColor ?? t.border),
      ),
      alignment: Alignment.center,
      child: dashGlyph(
        context,
        icon: icon,
        asset: asset,
        size: iconSize ?? (asset != null ? size * 2 / 3 : size * 0.6),
        color: color ?? t.textPrimary,
      ),
    );
  }
}

/// Icon block, title (and optional subtitle), and a tag or action on the
/// right.
class DashCardHeader extends StatelessWidget {
  const DashCardHeader({
    super.key,
    this.icon,
    this.asset,
    required this.title,
    this.subtitle,
    this.trailing,
  }) : assert(icon != null || asset != null);

  final IconData? icon;

  /// A Figma icon (preferred over [icon]).
  final String? asset;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: DashText.cardTitle(context)),
        ),
        if (subtitle != null) Text(subtitle!, style: DashText.body(context)),
      ],
    );
    return Row(
      children: [
        if (asset != null)
          DashIconBlock.asset(asset!)
        else
          DashIconBlock(icon!),
        const SizedBox(width: 16),
        // Title left, tag right; the tag moves under the title when both do
        // not fit on one line.
        Expanded(
          child: trailing == null
              ? heading
              : Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [heading, trailing!],
                ),
        ),
      ],
    );
  }
}

enum DashTone { neutral, info, warning, success, danger, disabled }

extension DashToneColors on DashTone {
  ({Color fg, Color bg, Color border}) colors(BuildContext context) {
    final t = context.dash;
    return switch (this) {
      DashTone.neutral => (fg: t.textPrimary, bg: t.subtle, border: t.border),
      DashTone.info => (fg: t.info, bg: t.infoBg, border: t.infoBorder),
      DashTone.warning => (
        fg: t.warningText,
        bg: t.warningBg,
        border: t.warningBorder,
      ),
      DashTone.success => (
        fg: t.success,
        bg: t.successBg,
        border: t.successBorder,
      ),
      DashTone.danger => (fg: t.danger, bg: t.dangerBg, border: t.dangerBorder),
      DashTone.disabled => (fg: t.textMuted, bg: t.surface, border: t.border),
    };
  }

  /// Dots and bars.
  Color strong(BuildContext context) {
    final t = context.dash;
    return switch (this) {
      DashTone.neutral => t.textPrimary,
      DashTone.info => t.info,
      DashTone.warning => t.warning,
      DashTone.success => t.successDot,
      DashTone.danger => t.danger,
      DashTone.disabled => t.textMuted,
    };
  }

  static DashTone of(Tone tone) => switch (tone) {
    Tone.success => DashTone.success,
    Tone.warning => DashTone.warning,
    Tone.danger => DashTone.danger,
    Tone.info => DashTone.info,
    Tone.neutral => DashTone.neutral,
  };
}

/// Small bordered label ("Phase: Blocks", "7 Connected", "Ready").
class DashTag extends StatelessWidget {
  const DashTag(
    this.label, {
    super.key,
    this.tone = DashTone.neutral,
    this.icon,
    this.asset,
    this.large = false,
  });

  final String label;
  final DashTone tone;
  final IconData? icon;
  final String? asset;

  /// 28 high card tags; the default is the 20 high header/service tag.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final c = tone.colors(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: large ? 4 : 1),
      decoration: BoxDecoration(
        color: c.bg,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null || asset != null) ...[
            dashGlyph(context, icon: icon, asset: asset, size: 12, color: c.fg),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: large ? 13 : 12,
                height: 1.4,
                fontWeight: FontWeight.w500,
                color: c.fg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 12 px pill progress bar. Only drawn for a real fraction.
class DashBar extends StatelessWidget {
  const DashBar({
    super.key,
    required this.fraction,
    required this.color,
    required this.label,
  });

  final double fraction;
  final Color color;

  /// What the bar measures, for screen readers.
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      value: '${(fraction * 100).toStringAsFixed(1)}%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          height: 12,
          child: LinearProgressIndicator(
            value: fraction.clamp(0.0, 1.0),
            minHeight: 12,
            color: color,
            backgroundColor: context.dash.track,
          ),
        ),
      ),
    );
  }
}

enum DashButtonStyle { primary, secondary, outline }

/// Square-cornered button: black primary, gray secondary, outline.
class DashButton extends StatelessWidget {
  const DashButton(
    this.label, {
    super.key,
    required this.onPressed,
    this.style = DashButtonStyle.outline,
    this.icon,
    this.asset,
    this.height = 40,
    this.expand = false,
    this.tooltip,
  });

  final String label;
  final VoidCallback? onPressed;
  final DashButtonStyle style;
  final IconData? icon;
  final String? asset;

  /// 32 (header), 40 (banner, toolbars) or 48 (card footers).
  final double height;
  final bool expand;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final t = context.dash;
    final (bg, fg, border) = switch (style) {
      DashButtonStyle.primary => (t.primaryButton, t.onPrimaryButton, null),
      DashButtonStyle.secondary => (t.secondaryButton, t.textPrimary, null),
      DashButtonStyle.outline => (t.surface, t.textPrimary, t.borderStrong),
    };
    final enabled = onPressed != null;
    final fontSize = height <= 32 ? 12.0 : 14.0;
    final button = SizedBox(
      height: height,
      width: expand ? double.infinity : null,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          backgroundColor: enabled ? bg : t.subtle,
          foregroundColor: fg,
          disabledForegroundColor: t.textMuted,
          padding: EdgeInsets.symmetric(horizontal: height <= 32 ? 10 : 16),
          minimumSize: Size(0, height),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(2),
            side: border == null ? BorderSide.none : BorderSide(color: border),
          ),
          // Extends the theme's label style; a bare TextStyle would drop its
          // font family.
          textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontSize: fontSize,
            fontWeight: FontWeight.w500,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null || asset != null) ...[
              dashGlyph(
                context,
                icon: icon,
                asset: asset,
                size: height <= 32 ? 16 : 18,
                color: enabled ? fg : t.textMuted,
              ),
              const SizedBox(width: 6),
            ],
            Text(label),
          ],
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

/// "Current Height ........ 820,670".
class DashStatRow extends StatelessWidget {
  const DashStatRow(this.label, this.value, {super.key, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: DashText.body(context))),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: DashText.value(context, color: valueColor),
            ),
          ),
        ],
      ),
    );
  }
}

/// A full-width label/value row for longer explanations (Sync details).
class DashDetailRow extends StatelessWidget {
  const DashDetailRow(this.label, this.value, {super.key, this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 200,
            child: Text(label, style: DashText.body(context)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: mono
                  ? monoStyle(
                      context,
                      size: 12.5,
                    ).copyWith(color: context.dash.textPrimary)
                  : DashText.body(context, color: context.dash.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Gray box with a help icon, used under backfill progress.
class DashHelpBox extends StatelessWidget {
  const DashHelpBox(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.dash;
    return Container(
      padding: const EdgeInsets.all(12),
      color: t.subtle,
      child: Row(
        children: [
          DashIconBlock.asset(
            DashIcons.helpCircle,
            size: 24,
            iconSize: 16,
            color: t.textSecondary,
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: DashText.body(context))),
        ],
      ),
    );
  }
}

/// Pill row of the Active Services card: dot, name, status tag.
class DashServiceRow extends StatelessWidget {
  const DashServiceRow({
    super.key,
    required this.name,
    required this.status,
    required this.tone,
  });

  final String name;
  final String status;
  final DashTone tone;

  @override
  Widget build(BuildContext context) {
    final t = context.dash;
    final off = tone == DashTone.disabled;
    return Semantics(
      label: '$name: $status',
      excludeSemantics: true,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: t.surface,
          border: Border.all(color: t.border),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: off ? t.border : tone.strong(context),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: DashText.body(
                  context,
                  color: off ? t.textMuted : t.textSecondary,
                  weight: FontWeight.w500,
                ),
              ),
            ),
            DashTag(status, tone: tone),
          ],
        ),
      ),
    );
  }
}

class DashDivider extends StatelessWidget {
  const DashDivider({super.key, this.height = 33});
  final double height;

  @override
  Widget build(BuildContext context) =>
      Divider(height: height, thickness: 1, color: context.dash.border);
}

/// Lays children out as equal columns with a gap, or stacks them when the
/// space is narrower than [minChildWidth] per child.
class DashColumns extends StatelessWidget {
  const DashColumns({
    super.key,
    required this.children,
    this.gap = 22,
    this.minChildWidth = 360,
  });

  final List<Widget> children;
  final double gap;
  final double minChildWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final fits =
            c.maxWidth >=
            minChildWidth * children.length + gap * (children.length - 1);
        if (!fits) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) SizedBox(height: gap),
                // Cards push their footer down with a Spacer, which needs
                // a bounded height.
                IntrinsicHeight(child: children[i]),
              ],
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) SizedBox(width: gap),
                Expanded(child: children[i]),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Scrollable dashboard content: page background, 952 wide like the frame,
/// centred with 24 px top padding.
class DashPage extends StatefulWidget {
  const DashPage({super.key, required this.children, this.maxWidth = 952});

  final List<Widget> children;
  final double maxWidth;

  @override
  State<DashPage> createState() => _DashPageState();
}

class _DashPageState extends State<DashPage> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.dash.page,
      child: Scrollbar(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widget.maxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: widget.children,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "14.4k" for the header's Behind count.
String formatCompact(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    final k = n / 1000;
    return '${k >= 100 ? k.toStringAsFixed(0) : k.toStringAsFixed(1)}k';
  }
  final m = n / 1000000;
  return '${m >= 100 ? m.toStringAsFixed(0) : m.toStringAsFixed(1)}M';
}

/// "62.5%".
String formatPercent1(double f) => '${(f * 100).toStringAsFixed(1)}%';

/// Top card of the Peers, RPC, Electrum, Logs and Help screens: a 32 icon
/// block, title (and tag), subtitle, actions on the right and an optional
/// help box underneath.
class DashPageHeader extends StatelessWidget {
  const DashPageHeader({
    super.key,
    required this.asset,
    required this.title,
    this.tag,
    this.subtitle,
    this.actions = const [],
    this.help,
  });

  final String asset;
  final String title;
  final Widget? tag;
  final String? subtitle;
  final List<Widget> actions;
  final String? help;

  @override
  Widget build(BuildContext context) {
    return DashCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 16,
            runSpacing: 12,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: DashIconBlock.asset(asset, size: 32, iconSize: 16),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Semantics(
                              header: true,
                              child: Text(
                                title,
                                style: DashText.cardTitle(
                                  context,
                                ).copyWith(fontSize: 16),
                              ),
                            ),
                            ?tag,
                          ],
                        ),
                        if (subtitle != null)
                          SelectableText(
                            subtitle!,
                            style: DashText.body(context),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              if (actions.isNotEmpty)
                Wrap(spacing: 8, runSpacing: 8, children: actions),
            ],
          ),
          if (help != null) ...[const SizedBox(height: 16), DashHelpBox(help!)],
        ],
      ),
    );
  }
}

/// Underlined text tabs (RPC console categories).
class DashTabs extends StatelessWidget {
  const DashTabs({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final t = context.dash;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.border, width: 2)),
      ),
      child: Wrap(
        children: [
          for (var i = 0; i < labels.length; i++)
            Semantics(
              selected: i == selected,
              button: true,
              child: InkWell(
                onTap: () => onSelected(i),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: i == selected ? t.brand : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Text(
                    labels[i],
                    style: DashText.body(
                      context,
                      color: i == selected ? t.textPrimary : t.textSecondary,
                      weight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Filter chip of the Logs screen: black when selected, gray otherwise.
class DashChip extends StatelessWidget {
  const DashChip(
    this.label, {
    super.key,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.dash;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? t.primaryButton : t.secondaryButton,
        borderRadius: BorderRadius.circular(2),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(2),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Text(
              label,
              style: DashText.small(
                context,
                color: selected ? t.onPrimaryButton : t.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Near-black panel for code: RPC/Electrum responses and logs.
class DashCodeBox extends StatelessWidget {
  const DashCodeBox({super.key, required this.child, this.height});

  final Widget child;
  final double? height;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    width: double.infinity,
    color: context.dash.codeBg,
    padding: const EdgeInsets.all(16),
    child: child,
  );
}

/// Monospace style for code panels.
TextStyle dashCode(BuildContext context, {Color? color}) => monoStyle(
  context,
  size: 12.5,
).copyWith(color: color ?? context.dash.codeText, height: 1.6);

final _jsonToken = RegExp(
  r'("(?:[^"\\]|\\.)*")(\s*:)?|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|\b(true|false|null)\b',
);

/// Colours pretty-printed JSON like the Figma response panel.
TextSpan highlightJson(BuildContext context, String json) {
  final t = context.dash;
  final spans = <TextSpan>[];
  var last = 0;
  for (final m in _jsonToken.allMatches(json)) {
    if (m.start > last) {
      spans.add(TextSpan(text: json.substring(last, m.start)));
    }
    final color = m.group(1) != null
        ? (m.group(2) != null ? t.codeKey : t.codeString)
        : t.codeNumber;
    spans.add(
      TextSpan(
        text: m.group(1) ?? m.group(3) ?? m.group(4),
        style: TextStyle(color: color),
      ),
    );
    if (m.group(2) != null) spans.add(TextSpan(text: m.group(2)));
    last = m.end;
  }
  if (last < json.length) spans.add(TextSpan(text: json.substring(last)));
  return TextSpan(style: dashCode(context), children: spans);
}
