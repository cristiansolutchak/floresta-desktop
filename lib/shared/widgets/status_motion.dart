import 'package:flutter/material.dart';

import 'dash.dart';

/// Motion for status, shared by every screen so one state always moves the
/// same way. Each piece is driven only by the state it is given: activity
/// animates while it is true and stops when it is not, nothing loops
/// "just because", and with the system's reduced-motion setting everything
/// is static. Controllers start and stop with the state and are disposed
/// with the widget.

/// How long a state change takes on screen.
const statusSwapDuration = Duration(milliseconds: 220);

bool _reduced(BuildContext context) => MediaQuery.disableAnimationsOf(context);

/// Rotates [child] (the sync icons) at one calm turn per 1.6 s while
/// [spinning]; still otherwise. For work that is actually running:
/// syncing, starting, stopping.
class SpinningGlyph extends StatefulWidget {
  const SpinningGlyph({super.key, required this.child, required this.spinning});

  final Widget child;
  final bool spinning;

  @override
  State<SpinningGlyph> createState() => _SpinningGlyphState();
}

class _SpinningGlyphState extends State<SpinningGlyph>
    with SingleTickerProviderStateMixin {
  late final _turns = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  void _sync() {
    final run = widget.spinning && !_reduced(context);
    if (run && !_turns.isAnimating) {
      _turns.repeat();
    } else if (!run && _turns.isAnimating) {
      // Finish the turn so the icon comes to rest upright, not mid-spin.
      _turns.animateTo(1, duration: const Duration(milliseconds: 300)).then((
        _,
      ) {
        if (mounted && !_turns.isAnimating) _turns.value = 0;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(SpinningGlyph old) {
    super.didUpdateWidget(old);
    if (old.spinning != widget.spinning) _sync();
  }

  @override
  void dispose() {
    _turns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RotationTransition(turns: _turns, child: widget.child);
}

/// A status dot. While [active] (something is in progress) it breathes
/// softly; otherwise it is steady. Colour changes cross-fade.
class StatusDot extends StatefulWidget {
  const StatusDot({
    super.key,
    required this.tone,
    this.active = false,
    this.size = 8,
  });

  final DashTone tone;
  final bool active;
  final double size;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  void _sync() {
    final run = widget.active && !_reduced(context);
    if (run && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!run) {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(StatusDot old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _sync();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.tone.strong(context);
    return FadeTransition(
      opacity: Tween<double>(
        begin: 1,
        end: 0.4,
      ).chain(CurveTween(curve: Curves.easeInOut)).animate(_pulse),
      child: AnimatedContainer(
        duration: _reduced(context) ? Duration.zero : statusSwapDuration,
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// Swaps [child] with a short fade and a slight scale when [stateKey]
/// changes, so a new state (a check mark arriving, an error replacing the
/// sync icon) reads as a change, not a flash. The outgoing and incoming
/// children are centred on each other, so the layout does not jump.
class StatusSwap extends StatelessWidget {
  const StatusSwap({super.key, required this.stateKey, required this.child});

  final Object stateKey;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: _reduced(context) ? Duration.zero : statusSwapDuration,
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeInCubic,
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.92, end: 1).animate(animation),
        child: child,
      ),
    ),
    layoutBuilder: (current, previous) => Stack(
      alignment: Alignment.centerLeft,
      children: [...previous, ?current],
    ),
    child: KeyedSubtree(key: ValueKey(stateKey), child: child),
  );
}

/// Glides from the last value to [value] (a fraction the app received),
/// never past it: the bar moves smoothly between real readings, it does not
/// predict the next one.
class AnimatedFraction extends StatelessWidget {
  const AnimatedFraction({
    super.key,
    required this.value,
    required this.builder,
  });

  final double value;
  final Widget Function(BuildContext context, double value) builder;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: value.clamp(0.0, 1.0)),
    duration: _reduced(context)
        ? Duration.zero
        : const Duration(milliseconds: 600),
    curve: Curves.easeOutCubic,
    builder: (context, v, _) => builder(context, v),
  );
}

/// The dashboard's status icons for one short status, shared by the header
/// tag and the banner so a state looks the same in both. Sync work spins
/// the sync icon; a finished sync shows a check; errors an error.
Widget statusGlyph(
  BuildContext context, {
  required DashTone tone,
  required bool active,
  required double size,
  required Color color,
  String spinningAsset = DashIcons.headerSyncing,
}) => switch (tone) {
  DashTone.warning => SpinningGlyph(
    spinning: active,
    child: DashSvg(spinningAsset, size: size, color: color),
  ),
  DashTone.success => Icon(Icons.check, size: size, color: color),
  DashTone.danger => Icon(Icons.error_outline, size: size, color: color),
  _ => Icon(Icons.power_settings_new, size: size, color: color),
};
