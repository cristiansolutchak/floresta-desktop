import 'dart:async';

import 'package:floresta_gui/app/brand/startup_splash.dart';
import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/features/installation/domain/installation.dart';
import 'package:floresta_gui/features/installation/presentation/installation_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';

typedef _Detection = Either<Failure, FlorestaInstallation>;

Future<void> _pump(
  WidgetTester tester,
  Future<_Detection> Function() detection, {
  bool reduceMotion = false,
}) => tester.pumpWidget(
  ProviderScope(
    retry: (_, _) => null,
    overrides: [installationDetectionProvider.overrideWith((_) => detection())],
    child: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: const MaterialApp(home: StartupSplash(child: Text('the app'))),
    ),
  ),
);

final _splash = find.bySemanticsLabel('Floresta is starting');

void main() {
  // The fade starts on the frame after it is triggered.
  const exit = Duration(milliseconds: 620);

  testWidgets('a fast detection still shows the whole intro, then fades', (
    tester,
  ) async {
    final detection = Completer<_Detection>();
    await _pump(tester, () => detection.future);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_splash, findsOneWidget);
    expect(find.text('the app'), findsOneWidget); // built underneath

    // Detection answers at once; the symbol is still forming, so it stays
    // (before 2026-10-28 it left here, cutting the intro off).
    detection.complete(const Left(ExecutableNotFoundFailure([])));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_splash, findsOneWidget);

    // Never longer than the intro plus the fade.
    await tester.pump(StartupSplash.minVisible);
    await tester.pump(exit);
    await tester.pump();
    expect(_splash, findsNothing);
    expect(find.text('the app'), findsOneWidget);
  });

  testWidgets('a slow detection keeps the splash until it answers', (
    tester,
  ) async {
    final detection = Completer<_Detection>();
    await _pump(tester, () => detection.future);
    await tester.pump(const Duration(seconds: 3));
    expect(_splash, findsOneWidget);
    detection.complete(const Left(ExecutableNotFoundFailure([])));
    await tester.pump();
    expect(_splash, findsOneWidget); // fading, not cut
    await tester.pumpAndSettle();
    expect(_splash, findsNothing);
  });

  testWidgets('a failed detection still lets the user in', (tester) async {
    await _pump(tester, () async => throw StateError('probe crashed'));
    await tester.pumpAndSettle();
    expect(_splash, findsNothing);
  });

  testWidgets('a hung detection does not trap the user', (tester) async {
    final never = Completer<_Detection>();
    await _pump(tester, () => never.future);
    await tester.pump(const Duration(seconds: 2));
    expect(_splash, findsOneWidget);
    await tester.pump(StartupSplash.maxWait);
    await tester.pump(exit);
    await tester.pump();
    expect(_splash, findsNothing);
  });

  testWidgets('reduced motion: no animation, gone at once when ready', (
    tester,
  ) async {
    final detection = Completer<_Detection>();
    await _pump(tester, () => detection.future, reduceMotion: true);
    await tester.pump();
    expect(_splash, findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    detection.complete(const Left(ExecutableNotFoundFailure([])));
    await tester.pump(StartupSplash.minVisible);
    await tester.pump();
    expect(_splash, findsNothing);
  });
}
