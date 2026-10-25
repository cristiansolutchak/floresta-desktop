import 'dart:async';
import 'dart:io';

import 'package:floresta_gui/app/app.dart';
import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/core/platform/app_paths.dart';
import 'package:floresta_gui/core/platform/host_platform.dart';
import 'package:floresta_gui/core/providers.dart';
import 'package:floresta_gui/features/installation/data/managed_installer.dart';
import 'package:floresta_gui/features/installation/data/release_source.dart';
import 'package:floresta_gui/features/installation/data/signed_manifest.dart';
import 'package:floresta_gui/features/installation/domain/floresta_version.dart';
import 'package:floresta_gui/features/installation/domain/installation.dart';
import 'package:floresta_gui/features/installation/domain/installer.dart';
import 'package:floresta_gui/features/installation/presentation/install_controller.dart';
import 'package:floresta_gui/features/installation/presentation/installation_providers.dart';
import 'package:floresta_gui/features/node/presentation/node_controller.dart';
import 'package:floresta_gui/features/wallet/presentation/wallet_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fakes.dart';

/// A real (non-mock) installer whose progress the test drives by hand.
class _ScriptedInstaller implements Installer {
  StreamController<InstallProgress>? _out;
  int installs = 0;
  int cancels = 0;

  @override
  bool supports(HostPlatform platform) => true;

  @override
  Stream<InstallProgress> install(HostPlatform platform) {
    installs++;
    return (_out = StreamController<InstallProgress>()).stream;
  }

  void emit(InstallProgress p) => _out!.add(p);

  Future<void> finish(InstallProgress last) async {
    _out!.add(last);
    await _out!.close();
  }

  @override
  void cancel() => cancels++;
}

const _installed = FlorestaInstallation(
  executablePath: '/data/floresta/versions/0.9.1/florestad',
  source: ExecutableSource.managed,
  version: FlorestaVersion(0, 9, 1),
);

final _devSource = ReleaseSource(
  manifestUrl: Uri.parse('http://127.0.0.1:8787/manifest.json'),
  trustedKeys: const [TrustedReleaseKey(id: 'dev', publicKeyHex: '')],
);

Future<FakeInstallationRepository> _pump(
  WidgetTester tester, {
  required Installer? installer,
  ReleaseSource? source,
}) async {
  tester.view.physicalSize = const Size(1280, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final repo = FakeInstallationRepository(
    const Left(ExecutableNotFoundFailure(['/usr/bin/florestad'])),
  );
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        hostPlatformProvider.overrideWithValue(
          const HostPlatform(HostOs.macos, CpuArch.arm64),
        ),
        environmentProvider.overrideWithValue(const {'HOME': '/Users/a'}),
        installationRepositoryProvider.overrideWithValue(repo),
        nodeRpcRepositoryProvider.overrideWithValue(FakeNodeRpcRepository()),
        nodeProcessManagerProvider.overrideWithValue(FakeProcessManager()),
        walletRepositoryProvider.overrideWithValue(FakeWalletRepository()),
        preflightProbeProvider.overrideWithValue(FakePreflightProbe()),
        electrumProbeProvider.overrideWithValue(FakeElectrumProbe()),
        releaseSourceProvider.overrideWithValue(source),
        installerProvider.overrideWithValue(installer),
      ],
      child: const FlorestaApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Get started'));
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('no release source: no automatic install, no simulation', (
    tester,
  ) async {
    await _pump(tester, installer: null);
    expect(find.text('Automatic installation'), findsNothing);
    expect(find.text('Install Floresta'), findsNothing);
    expect(find.textContaining('not configured in this build'), findsOneWidget);
    expect(find.text('Build from source'), findsOneWidget);
  });

  testWidgets('installs, then onboarding can continue', (tester) async {
    final installer = _ScriptedInstaller();
    final repo = await _pump(tester, installer: installer, source: _devSource);
    expect(find.text('SIMULATION'), findsNothing);
    expect(find.text('DEVELOPMENT SOURCE'), findsOneWidget);
    expect(find.textContaining('Install it automatically'), findsOneWidget);
    expect(find.text('Continue'), findsNothing);

    await tester.tap(find.text('Install Floresta'));
    await tester.pump();
    installer.emit(const InstallDownloading(0.5));
    await tester.pump();
    expect(find.text('Downloading 50%'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    repo.result = const Right(_installed);
    await installer.finish(const InstallCompleted('/data/x/florestad'));
    await tester.pumpAndSettle();
    expect(find.text('Floresta installed'), findsOneWidget);
    expect(find.text('Found florestad v0.9.1'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(installer.installs, 1);
  });

  testWidgets('a failure explains itself and offers a retry', (tester) async {
    final installer = _ScriptedInstaller();
    await _pump(tester, installer: installer, source: _devSource);
    await tester.tap(find.text('Install Floresta'));
    await tester.pump();
    await installer.finish(
      const InstallFailed(
        'The release information failed its signature check.',
        recovery: 'Try again later.',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Nothing was installed'), findsOneWidget);
    expect(
      find.text(
        'The release information failed its signature check. '
        'Try again later.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(installer.installs, 2);
  });

  testWidgets('cancel reaches the installer while it runs', (tester) async {
    final installer = _ScriptedInstaller();
    await _pump(tester, installer: installer, source: _devSource);
    await tester.tap(find.text('Install Floresta'));
    await tester.pump();
    installer.emit(const InstallDownloading(0.1));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    expect(installer.cancels, 1);
    await installer.finish(
      const InstallFailed(
        'The download was cancelled.',
        recovery: 'Start it again to resume.',
        stage: InstallStage.download,
        cancelled: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Download paused'), findsOneWidget);
    // INS-04: the partial download is kept; the button resumes it.
    await tester.tap(find.text('Resume download'));
    await tester.pump();
    expect(installer.installs, 2);
    installer.emit(
      const InstallDownloading(0.6, received: 6000000, total: 10000000),
    );
    await tester.pump();
    expect(find.text('Downloading 60% · 6.0 MB of 10.0 MB'), findsOneWidget);
    await installer.finish(const InstallCompleted('/data/x/florestad'));
    await tester.pumpAndSettle();
    expect(find.text('Floresta installed'), findsOneWidget);
  });

  // INS-03: every stage a real install can stop at has its own headline.
  for (final (stage, title) in [
    (InstallStage.resolve, 'Could not get the release information'),
    (InstallStage.download, 'The download did not finish'),
    (InstallStage.verify, 'The download did not pass verification'),
    (InstallStage.install, 'Floresta could not be installed'),
  ]) {
    testWidgets('a ${stage.name} failure says so and offers a retry', (
      tester,
    ) async {
      final installer = _ScriptedInstaller();
      await _pump(tester, installer: installer, source: _devSource);
      await tester.tap(find.text('Install Floresta'));
      await tester.pump();
      await installer.finish(
        InstallFailed(
          'Detail.',
          recovery: 'Nothing was installed.',
          stage: stage,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      expect(find.text('Detail. Nothing was installed.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  }

  group('providers', () {
    test('the installer follows the release source', () {
      final root = Directory.systemTemp.createTempSync('ip_');
      addTearDown(() => root.deleteSync(recursive: true));
      ProviderContainer make(ReleaseSource? source) {
        final c = ProviderContainer(
          overrides: [
            releaseSourceProvider.overrideWithValue(source),
            appPathsProvider.overrideWithValue(AppPaths(root)),
          ],
        );
        addTearDown(c.dispose);
        return c;
      }

      expect(make(null).read(installerProvider), isNull);
      expect(make(_devSource).read(installerProvider), isA<ManagedInstaller>());
    });

    test('a second start while running is ignored', () async {
      final installer = _ScriptedInstaller();
      final c = ProviderContainer(
        overrides: [
          installerProvider.overrideWithValue(installer),
          hostPlatformProvider.overrideWithValue(
            const HostPlatform(HostOs.macos, CpuArch.arm64),
          ),
        ],
      );
      addTearDown(c.dispose);
      final controller = c.read(installControllerProvider.notifier);
      final first = controller.start();
      await Future<void>.delayed(Duration.zero);
      await controller.start();
      expect(installer.installs, 1);
      await installer.finish(const InstallFailed('x'));
      await first;
      expect(c.read(installControllerProvider).running, isFalse);
    });
  });
}
