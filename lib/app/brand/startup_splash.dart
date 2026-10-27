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
/// Overview and onboarding need. It leaves as soon as that answers, success
/// or failure, never waiting for its own animation; after [maxWait] it leaves
/// anyway so a hung probe cannot trap the user (the screens behind show
/// their own loading and error states).
class StartupSplash extends ConsumerStatefulWidget {
  const StartupSplash({super.key, required this.child});

  final Widget child;

  static const maxWait = Duration(seconds: 4);

  @override
  ConsumerState<StartupSplash> createState() => _StartupSplashState();
}

class _StartupSplashState extends ConsumerState<StartupSplash>
    with TickerProviderStateMixin {
  /// The symbol builds in 700 ms; the app does not wait for it.
  late final _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  late final _exit = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  Timer? _cap;
  var _leaving = false;
  var _gone = false;

  @override
  void initState() {
    super.initState();
    _cap = Timer(StartupSplash.maxWait, _leave);
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
        _intro.value = 1;
      } else {
        _intro.forward();
      }
    }
  }

  void _leave() {
    if (_leaving || !mounted) return;
    _leaving = true;
    _cap?.cancel();
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _gone = true);
    } else {
      _exit.forward();
    }
  }

  @override
  void dispose() {
    _cap?.cancel();
    _intro.dispose();
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) return widget.child;
    ref.listen(installationDetectionProvider, (_, next) {
      if (!next.isLoading) _leave();
    });
    if (!ref.read(installationDetectionProvider).isLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _leave());
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        AnimatedBuilder(
          animation: Listenable.merge([_intro, _exit]),
          builder: (context, _) {
            final out = Curves.easeIn.transform(_exit.value);
            return IgnorePointer(
              ignoring: _leaving,
              child: Opacity(
                opacity: 1 - out,
                child: _SplashFace(intro: _intro.value, scale: 1 + 0.04 * out),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _SplashFace extends StatelessWidget {
  const _SplashFace({required this.intro, required this.scale});

  /// 0..1 through the 700 ms intro.
  final double intro;
  final double scale;

  /// Block i grows during [i * 0.09, i * 0.09 + 0.45] of the intro.
  List<double> _blocks() => [
    for (var i = 0; i < BrandSymbol.blocks.length; i++)
      Curves.easeOutCubic.transform(((intro - i * 0.09) / 0.45).clamp(0, 1)),
  ];

  @override
  Widget build(BuildContext context) {
    final glow = Curves.easeOut.transform(intro);
    final word = Curves.easeOut.transform(((intro - 0.55) / 0.45).clamp(0, 1));
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
          ],
        ),
      ),
    );
  }
}
