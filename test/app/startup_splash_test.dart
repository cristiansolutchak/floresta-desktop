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
  testWidgets('covers the app until detection answers, then fades out', (
    tester,
  ) async {
    final detection = Completer<_Detection>();
    await _pump(tester, () => detection.future);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_splash, findsOneWidget);
    expect(find.text('the app'), findsOneWidget); // built underneath

    // No artificial wait: it leaves as soon as the answer arrives.
    detection.complete(const Left(ExecutableNotFoundFailure([])));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_splash, findsNothing);
    expect(find.text('the app'), findsOneWidget);
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
    await tester.pump(const Duration(milliseconds: 400));
    expect(_splash, findsNothing);
  });

  testWidgets('reduced motion: no animation, gone at once', (tester) async {
    final detection = Completer<_Detection>();
    await _pump(tester, () => detection.future, reduceMotion: true);
    await tester.pump();
    expect(_splash, findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    detection.complete(const Left(ExecutableNotFoundFailure([])));
    await tester.pump();
    await tester.pump();
    expect(_splash, findsNothing);
  });
}
