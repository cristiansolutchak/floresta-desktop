import 'package:floresta_desktop/app/theme/app_theme.dart';
import 'package:floresta_desktop/shared/widgets/dash.dart';
import 'package:floresta_desktop/shared/widgets/status_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, Widget child, {bool reduce = false}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduce),
          child: Scaffold(body: Center(child: child)),
        ),
      ),
    );

double _turns(WidgetTester tester) => tester
    .widget<RotationTransition>(
      find.descendant(
        of: find.byType(SpinningGlyph),
        matching: find.byType(RotationTransition),
      ),
    )
    .turns
    .value;

void main() {
  group('SpinningGlyph', () {
    testWidgets('turns only while the work runs, then comes to rest', (
      tester,
    ) async {
      await _pump(
        tester,
        const SpinningGlyph(spinning: true, child: Icon(Icons.sync)),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(_turns(tester), greaterThan(0));
      expect(tester.hasRunningAnimations, isTrue);

      await _pump(
        tester,
        const SpinningGlyph(spinning: false, child: Icon(Icons.sync)),
      );
      // It finishes the turn (upright) and stops: nothing left running.
      await tester.pumpAndSettle();
      expect(_turns(tester), 0);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('reduced motion: still, even while working', (tester) async {
      await _pump(
        tester,
        const SpinningGlyph(spinning: true, child: Icon(Icons.sync)),
        reduce: true,
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(_turns(tester), 0);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('StatusDot', () {
    testWidgets('breathes while active, steady otherwise', (tester) async {
      await _pump(
        tester,
        const StatusDot(tone: DashTone.warning, active: true),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.hasRunningAnimations, isTrue);

      await _pump(tester, const StatusDot(tone: DashTone.success));
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
      final fade = tester.widget<FadeTransition>(
        find.descendant(
          of: find.byType(StatusDot),
          matching: find.byType(FadeTransition),
        ),
      );
      expect(fade.opacity.value, 1);
    });
  });

  group('StatusSwap', () {
    testWidgets('a new state fades in over the old, same place', (
      tester,
    ) async {
      Widget at(String s) => StatusSwap(
        stateKey: s,
        child: SizedBox(width: 80, height: 20, child: Text(s)),
      );
      await _pump(tester, at('Syncing'));
      final before = tester.getRect(find.text('Syncing'));
      await _pump(tester, at('Synced'));
      await tester.pump(const Duration(milliseconds: 100));
      // Mid-change both are there, stacked: the layout does not jump.
      expect(find.text('Syncing'), findsOneWidget);
      expect(find.text('Synced'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Syncing'), findsNothing);
      expect(tester.getRect(find.text('Synced')).topLeft, before.topLeft);
    });
  });

  group('AnimatedFraction', () {
    testWidgets('glides to the reading and never past it', (tester) async {
      final seen = <double>[];
      Widget at(double v) => AnimatedFraction(
        value: v,
        builder: (_, x) {
          seen.add(x);
          return const SizedBox();
        },
      );
      await _pump(tester, at(0.2));
      await _pump(tester, at(0.5));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(seen.last, 0.5);
      expect(seen.every((v) => v <= 0.5), isTrue);
    });

    testWidgets('reduced motion: jumps straight to the reading', (
      tester,
    ) async {
      double? shown;
      await _pump(
        tester,
        AnimatedFraction(
          value: 0.7,
          builder: (_, x) {
            shown = x;
            return const SizedBox();
          },
        ),
        reduce: true,
      );
      expect(shown, 0.7);
    });
  });

  testWidgets('statusGlyph: sync icon for work, check, error, power', (
    tester,
  ) async {
    Future<void> glyph(DashTone tone) => _pump(
      tester,
      Builder(
        builder: (context) => statusGlyph(
          context,
          tone: tone,
          active: true,
          size: 16,
          color: Colors.black,
        ),
      ),
    );
    await glyph(DashTone.warning);
    expect(find.byType(SpinningGlyph), findsOneWidget);
    await glyph(DashTone.success);
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.byType(SpinningGlyph), findsNothing);
    await glyph(DashTone.danger);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    await glyph(DashTone.neutral);
    expect(find.byIcon(Icons.power_settings_new), findsOneWidget);
  });
}
