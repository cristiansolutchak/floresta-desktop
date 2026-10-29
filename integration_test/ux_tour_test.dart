/// Design review: the REAL macOS app, every first-run and dashboard screen,
/// in light and dark, saved as screenshots. The node, installer and Docker
/// are scripted fakes (no florestad, no network), and preferences and app
/// data are isolated, so it never touches the user's settings or node.
///
///   flutter test integration_test/ux_tour_test.dart -d macos \
///     --dart-define=FLORESTA_EVIDENCE_DIR=/abs/evidence/dir
///
/// Without FLORESTA_EVIDENCE_DIR the test is skipped. It checks layout
/// (no overflow) on the way; the screenshots are for a human to judge.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:floresta_gui/app/app.dart';
import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/core/platform/host_platform.dart';
import 'package:floresta_gui/core/providers.dart';
import 'package:floresta_gui/features/installation/data/existing_node_probe.dart';
import 'package:floresta_gui/features/installation/data/release_source.dart';
import 'package:floresta_gui/features/installation/domain/existing_node.dart';
import 'package:floresta_gui/features/installation/domain/floresta_version.dart';
import 'package:floresta_gui/features/installation/domain/installation.dart';
import 'package:floresta_gui/features/installation/domain/installer.dart';
import 'package:floresta_gui/features/installation/data/signed_manifest.dart';
import 'package:floresta_gui/features/installation/presentation/installation_providers.dart';
import 'package:floresta_gui/features/node/data/rpc_models.dart';
import 'package:floresta_gui/features/node/data/utreexo_peer_finder.dart';
import 'package:floresta_gui/features/node/domain/blockchain_info.dart';
import 'package:floresta_gui/features/node/domain/node_readiness.dart';
import 'package:floresta_gui/features/node/domain/peer.dart';
import 'package:floresta_gui/features/node/domain/utreexo_peer.dart';
import 'package:floresta_gui/features/node/presentation/node_controller.dart';
import 'package:floresta_gui/features/node/presentation/utreexo_peer_controller.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/features/wallet/presentation/wallet_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/features/node/node_rpc_test.dart' show signetAfterSnapshot;
import '../test/helpers/fakes.dart';

const _evidenceDir = String.fromEnvironment('FLORESTA_EVIDENCE_DIR');

const _installed = FlorestaInstallation(
  executablePath: '/Users/a/Library/Application Support/floresta/florestad',
  source: ExecutableSource.managed,
  version: FlorestaVersion(0, 9, 1),
);

class _ScriptedInstaller implements Installer {
  StreamController<InstallProgress>? out;
  @override
  bool supports(HostPlatform platform) => true;
  @override
  Stream<InstallProgress> install(HostPlatform platform) =>
      (out = StreamController<InstallProgress>()).stream;
  @override
  void cancel() {}
}

class _Docker extends DockerProbe {
  _Docker() : super(platform: HostPlatform.current(), environment: const {});
  @override
  Future<DockerScan> scan() async => DockerContainers([
    DockerContainer(
      name: 'Floresta',
      image: 'dlsz/floresta:latest',
      command: 'florestad',
      state: 'running',
      status: 'Up 2 hours',
      ports: parseDockerPorts('0.0.0.0:8332->8332/tcp'),
    ),
  ]);
}

class _ExistingNode extends ExistingNodeProbe {
  _ExistingNode()
    : super(httpClient: MockClient((_) async => http.Response('', 500)));
  @override
  Future<ExistingNodeCheck> check(BitcoinNetwork network, int rpcPort) async =>
      (
        rpc: Right<Failure, BlockchainInfo>(
          RpcModels.blockchainInfo({
            ...signetAfterSnapshot,
            'chain': 'bitcoin',
          }),
        ),
        electrum: ElectrumCheck.unreachable,
      );
}

Future<void> _shot(String name, WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  final view = RendererBinding.instance.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final image = await layer.toImage(
    Offset.zero & view.flutterView.physicalSize,
  );
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File('$_evidenceDir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final dark in [false, true]) {
    final theme = dark ? 'dark' : 'light';
    testWidgets('UX tour ($theme)', (tester) async {
      Directory(_evidenceDir).createSync(recursive: true);
      binding.platformDispatcher.platformBrightnessTestValue = dark
          ? Brightness.dark
          : Brightness.light;
      addTearDown(binding.platformDispatcher.clearPlatformBrightnessTestValue);
      // Status motion runs while the node works and never "settles"; the
      // screenshots are of layout, so motion is off (reduced motion).
      binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final temp = Directory.systemTemp.createTempSync('floresta_tour_');
      addTearDown(() => temp.deleteSync(recursive: true));
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final install = FakeInstallationRepository(
        const Left(ExecutableNotFoundFailure(['/usr/local/bin/florestad'])),
      );
      final rpc = FakeNodeRpcRepository();
      final manager = FakeProcessManager();
      final installer = _ScriptedInstaller();
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            environmentProvider.overrideWithValue({
              'HOME': '${temp.path}/home',
              'FLORESTA_GUI_DATA_ROOT': '${temp.path}/app',
            }),
            installationRepositoryProvider.overrideWithValue(install),
            releaseSourceProvider.overrideWithValue(
              ReleaseSource(
                manifestUrl: Uri.parse(
                  'https://raw.githubusercontent.com/x/y/main/manifest.json',
                ),
                trustedKeys: const [
                  TrustedReleaseKey(id: 'prod', publicKeyHex: ''),
                ],
              ),
            ),
            installerProvider.overrideWithValue(installer),
            nodeRpcRepositoryProvider.overrideWithValue(rpc),
            nodeProcessManagerProvider.overrideWithValue(manager),
            walletRepositoryProvider.overrideWithValue(FakeWalletRepository()),
            preflightProbeProvider.overrideWithValue(FakePreflightProbe()),
            electrumProbeProvider.overrideWithValue(FakeElectrumProbe()),
            dockerProbeProvider.overrideWithValue(_Docker()),
            existingNodeProbeProvider.overrideWithValue(_ExistingNode()),
            utreexoPeerFinderProvider.overrideWithValue(
              UtreexoPeerFinder(
                rpc: rpc,
                resolve: (_) async => const [],
                probe: (_, _, _) async => const PeerProbe.failed('tour'),
              ),
            ),
          ],
          child: const FlorestaApp(),
        ),
      );

      // The splash mid-intro, then settled.
      await tester.pump(const Duration(milliseconds: 500));
      await _shot('$theme-00-splash', tester);
      await tester.pumpAndSettle();

      Future<void> tap(String text) async {
        final f = find.text(text).last;
        await tester.ensureVisible(f);
        await tester.pumpAndSettle();
        await tester.tap(f);
        await tester.pumpAndSettle();
      }

      await _shot('$theme-01-welcome', tester);
      await tap('Get started');
      await _shot('$theme-02-install-not-installed', tester);
      await tap('Install Floresta');
      installer.out!.add(
        const InstallDownloading(0.42, received: 5400000, total: 12800000),
      );
      await tester.pumpAndSettle();
      await _shot('$theme-03-installing', tester);
      install.result = const Right(_installed);
      installer.out!.add(const InstallCompleted('/x/florestad'));
      await installer.out!.close();
      await tester.pumpAndSettle();
      await _shot('$theme-04-installed', tester);
      await tap('Other ways to connect');
      await _shot('$theme-05-other-ways', tester);
      await tap('Open Advanced setup');
      await _shot('$theme-06-advanced-executable', tester);
      await tap('Connect to a node that is already running');
      await tap('Check connection');
      await _shot('$theme-07-advanced-running-node', tester);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      await tap('Continue');
      await _shot('$theme-08-network', tester);
      await tap('Next');
      await _shot('$theme-09-storage', tester);
      await tap('Next');
      await _shot('$theme-10-fast-start', tester);
      await tap('Next');
      await _shot('$theme-11-services', tester);
      await tap('Not offered in this version');
      await _shot('$theme-12-services-not-offered', tester);
      await tap('Review configuration');
      await _shot('$theme-13-review', tester);
      await tap('Start Floresta now');
      await tap('Finish');
      await _shot('$theme-14-overview-stopped', tester);

      // A syncing node answering (signet data under a mainnet label is
      // fine for layout), with peers.
      rpc.info = Right(RpcModels.blockchainInfo(signetAfterSnapshot));
      rpc.peers = const [
        Peer(
          id: 1,
          address: '1.2.3.4:8333',
          userAgent: '/Satoshi:30.0.0/',
          inbound: false,
          kind: 'regular',
          state: 'Ready',
          transport: 'V2',
          initialHeight: 327900,
          services: ['NETWORK', 'WITNESS'],
        ),
      ];
      final container = ProviderScope.containerOf(
        tester.element(find.byType(FlorestaApp)),
      );
      await container.read(nodeControllerProvider.notifier).refresh();
      await tester.pumpAndSettle();
      await _shot('$theme-15-overview-syncing', tester);
      await tap('Go to Sync');
      await _shot('$theme-16-sync', tester);
      await tester.tap(find.byTooltip('Collapse sidebar'));
      await tester.pumpAndSettle();
      await _shot('$theme-16b-sync-compact-sidebar', tester);
      await tester.tap(find.byTooltip('Expand sidebar'));
      await tester.pumpAndSettle();
      await tap('Installation');
      await _shot('$theme-17-installation-page', tester);
      expect(tester.takeException(), isNull);
    }, skip: _evidenceDir.isEmpty);
  }
}
