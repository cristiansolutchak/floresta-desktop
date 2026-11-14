import 'dart:io';

import 'package:floresta_desktop/core/errors/failure.dart';
import 'package:floresta_desktop/core/platform/app_paths.dart';
import 'package:floresta_desktop/core/platform/host_platform.dart';
import 'package:floresta_desktop/core/providers.dart';
import 'package:floresta_desktop/features/installation/data/app_updater.dart';
import 'package:floresta_desktop/features/installation/data/artifact_downloader.dart';
import 'package:floresta_desktop/features/installation/data/release_source.dart';
import 'package:floresta_desktop/features/installation/domain/app_update.dart';
import 'package:floresta_desktop/features/installation/presentation/installation_providers.dart';
import 'package:floresta_desktop/features/installation/presentation/update_bar.dart';
import 'package:floresta_desktop/features/installation/presentation/update_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kind = SelfUpdatable(
  AppPackageFormat.macosAppZip,
  '/Applications/Floresta.app',
  executable: '/Applications/Floresta.app',
);

/// Answers checks with [offer]; records downloads; touches nothing.
class _FakeUpdater extends AppUpdater {
  _FakeUpdater()
    : super(
        paths: AppPaths(Directory('/nonexistent')),
        source: ReleaseSource(
          manifestUrl: Uri.parse('https://r.example/florestad/manifest.json'),
          trustedKeys: const [],
        ),
        platform: const HostPlatform(HostOs.macos, CpuArch.arm64),
      );

  AppUpdateOffer? offer;
  int downloads = 0;

  @override
  Future<Either<Failure, AppUpdateOffer?>> check({
    required AppVersion current,
    required AppInstallKind kind,
  }) async => Right(offer);

  @override
  Future<Either<Failure, StagedUpdate>> download(
    AppUpdateOffer offer, {
    void Function(int, int)? onProgress,
    CancelToken? cancel,
  }) async {
    downloads++;
    return const Left(
      InstallationFailure(stage: 'download', message: 'offline in tests'),
    );
  }

  @override
  Future<SwapResult?> lastResult() async => null;

  @override
  bool get swapPending => false;
}

AppUpdateOffer _offer() {
  final now = DateTime.now().toUtc();
  final manifest = AppReleaseManifest(
    serial: 1,
    issued: now,
    expires: now.add(const Duration(days: 1)),
    version: const AppVersion(9, 9, 9),
    notes: 'Faster sync.',
    artifacts: [
      AppArtifact(
        os: HostOs.macos,
        arch: null,
        format: AppPackageFormat.macosAppZip,
        url: Uri.parse('https://r.example/app/pkg.zip'),
        sha256: 'ab' * 32,
        size: 10,
      ),
    ],
  );
  return AppUpdateOffer(
    manifest: manifest,
    artifact: manifest.artifacts.single,
    current: const AppVersion(0, 0, 1),
    kind: _kind,
  );
}

void main() {
  late _FakeUpdater updater;
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, {bool auto = false}) async {
    SharedPreferences.setMockInitialValues({'updates.autoInstall': auto});
    final prefs = await SharedPreferences.getInstance();
    updater = _FakeUpdater()..offer = _offer();
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appUpdaterProvider.overrideWithValue(updater),
        installerProvider.overrideWithValue(null),
        appInstallKindProvider.overrideWithValue(_kind),
        appUpdateChecksProvider.overrideWithValue(true),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: UpdateBar())),
      ),
    );
    await container.read(updateControllerProvider.notifier).check();
    await tester.pump();
  }

  /// The controller's start and periodic timers end with its container.
  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  }

  testWidgets('an offer shows; Later hides it for a day', (tester) async {
    await pump(tester);
    expect(find.text('An update is available'), findsOneWidget);
    expect(
      find.textContaining('Floresta Desktop 9.9.9 is available'),
      findsOneWidget,
    );
    expect(find.textContaining('Faster sync.'), findsOneWidget);
    expect(find.text('Update now'), findsOneWidget);
    await tester.tap(find.text('Later'));
    await tester.pump();
    expect(find.text('An update is available'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('updates.postponedUntil'), isNotNull);
    await done(tester);
  });

  testWidgets('without automatic updates nothing is downloaded unasked', (
    tester,
  ) async {
    await pump(tester);
    expect(updater.downloads, 0);
    await done(tester);
  });

  testWidgets('automatic updates download (and verify) by themselves', (
    tester,
  ) async {
    await pump(tester, auto: true);
    expect(updater.downloads, 1);
    // The download failed here, so nothing is armed and the reason shows.
    expect(
      container.read(updateControllerProvider).failure?.message,
      'offline in tests',
    );
    await done(tester);
  });

  testWidgets('a failed download leaves the app as it is', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Update now'));
    await tester.pump();
    expect(updater.downloads, 1);
    expect(container.read(updateControllerProvider).phase, AppUpdatePhase.idle);
    await done(tester);
  });
}
