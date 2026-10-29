import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/installation/presentation/installation_providers.dart';
import 'brand_symbol.dart';

/// Brand colours of the splash and app icon, sampled from the announcement
/// render (`assets/app-icon/img-announcement-post1.png`). The splash keeps
/// them in both themes, like the icon; the native window background matches
/// [dark] so the first frame does not flash.
abstract final class SplashColors {
  static const light = Color(0xFF2D6062);
  static const mid = Color(0xFF174142);
  static const dark = Color(0xFF0D2D2E);
}

/// Covers the app while its first startup work finishes: detecting florestad
/// and probing its version ([installationDetectionProvider]), which the
/// Overview and onboarding need.
///
/// It leaves when both are true: that work answered (success or failure),
/// and the symbol finished building ([minVisible]). Before, it left the
/// moment detection answered, often under 300 ms, cutting its own intro off
/// half-built (2026-10-28). Startup is never delayed beyond [minVisible];
/// after [maxWait] it leaves anyway, so a hung probe cannot trap the user
/// (the screens behind show their own loading and error states).
class StartupSplash extends ConsumerStatefulWidget {
  const StartupSplash({super.key, required this.child});

  final Widget child;

  /// The intro: long enough to read as intentional, short enough not to
  /// feel like waiting.
  static const minVisible = Duration(milliseconds: 1200);
  static const maxWait = Duration(seconds: 6);

  /// The cross-fade into the app.
  static const exitDuration = Duration(milliseconds: 520);

  @override
  ConsumerState<StartupSplash> createState() => _StartupSplashState();
}

class _StartupSplashState extends ConsumerState<StartupSplash>
    with TickerProviderStateMixin {
  late final _intro = AnimationController(
    vsync: this,
    duration: StartupSplash.minVisible,
  );
  late final _exit = AnimationController(
    vsync: this,
    duration: StartupSplash.exitDuration,
  );
  Timer? _cap;
  Timer? _min;
  var _minDone = false;
  var _ready = false;
  var _leaving = false;
  var _gone = false;

  @override
  void initState() {
    super.initState();
    _cap = Timer(StartupSplash.maxWait, () => _leave(force: true));
    // The intro's length; dropped with reduced motion (no intro plays).
    _min = Timer(StartupSplash.minVisible, () {
      _minDone = true;
      if (_ready) _leave();
    });
    _exit.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _gone = true);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_intro.isAnimating && _intro.value == 0) {
      if (MediaQuery.disableAnimationsOf(context)) {
        // No intro to wait for: leave as soon as startup answers.
        _intro.value = 1;
        _min?.cancel();
        _minDone = true;
      } else {
        _intro.forward();
      }
    }
  }

  void _onReady() {
    _ready = true;
    if (_minDone) _leave();
  }

  void _leave({bool force = false}) {
    if (_leaving || !mounted) return;
    if (!force && !(_ready && _minDone)) return;
    _leaving = true;
    _cap?.cancel();
    _min?.cancel();
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _gone = true);
    } else {
      _exit.forward();
    }
  }

  @override
  void dispose() {
    _cap?.cancel();
    _min?.cancel();
    _intro.dispose();
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) return widget.child;
    ref.listen(installationDetectionProvider, (_, next) {
      if (!next.isLoading) _onReady();
    });
    if (!_ready && !ref.read(installationDetectionProvider).isLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onReady());
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        // The app settles in from slightly smaller as the splash lifts, so
        // the hand-over reads as one motion rather than a cut.
        AnimatedBuilder(
          animation: _exit,
          builder: (context, child) => Transform.scale(
            scale: 0.985 + 0.015 * Curves.easeOutCubic.transform(_exit.value),
            child: child,
          ),
          child: widget.child,
        ),
        AnimatedBuilder(
          animation: Listenable.merge([_intro, _exit]),
          builder: (context, _) {
            final out = Curves.easeInOutCubic.transform(_exit.value);
            return IgnorePointer(
              ignoring: _leaving,
              child: Opacity(
                opacity: 1 - out,
                child: _SplashFace(intro: _intro.value, lift: out),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _SplashFace extends StatelessWidget {
  const _SplashFace({required this.intro, required this.lift});

  /// 0..1 through the intro ([StartupSplash.minVisible]).
  final double intro;

  /// 0..1 through the exit: the mark rises and grows a touch as it fades.
  final double lift;

  /// Block i grows during [0.06 + i * 0.07, … + 0.42] of the intro: the
  /// symbol assembles in the first ~80 %, then holds.
  List<double> _blocks() => [
    for (var i = 0; i < BrandSymbol.blocks.length; i++)
      Curves.easeOutCubic.transform(
        ((intro - 0.06 - i * 0.07) / 0.42).clamp(0, 1),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    // The light comes up with the symbol; the name follows once it formed.
    final glow = Curves.easeInOut.transform((intro / 0.8).clamp(0, 1));
    final word = Curves.easeOutCubic.transform(
      ((intro - 0.5) / 0.38).clamp(0, 1),
    );
    final scale = 1 + 0.05 * lift;
    return Semantics(
      label: 'Floresta is starting',
      container: true,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [SplashColors.light, SplashColors.mid, SplashColors.dark],
            stops: [0, 0.55, 1],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The light from the top right in the brand render.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.75, -0.85),
                    radius: 0.9,
                    colors: [
                      Colors.white.withValues(alpha: 0.12 * glow),
                      Colors.white.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
            Center(
              child: Transform.translate(
                offset: Offset(0, -10 * lift),
                child: Transform.scale(
                  scale: scale,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 120,
                        height: 120 * BrandSymbol.height / BrandSymbol.width,
                        child: CustomPaint(
                          painter: BrandSymbolPainter(
                            color: Colors.white,
                            progress: _blocks(),
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      Opacity(
                        opacity: word,
                        child: Transform.translate(
                          offset: Offset(0, 6 * (1 - word)),
                          child: Text(
                            'Floresta',
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: max(0, 1.2 * (1 - word)),
                                ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
