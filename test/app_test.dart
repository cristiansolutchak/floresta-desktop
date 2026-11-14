import 'package:floresta_gui/app/app.dart';
import 'package:floresta_gui/app/licenses.dart';
import 'package:floresta_gui/core/build_flavor.dart';
import 'package:floresta_gui/core/logging/log_buffer.dart';
import 'package:floresta_gui/features/console/domain/console_repository.dart';
import 'package:floresta_gui/features/console/presentation/console_page.dart';
import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/core/platform/host_platform.dart';
import 'package:floresta_gui/core/providers.dart';
import 'package:floresta_gui/features/installation/domain/floresta_version.dart';
import 'package:floresta_gui/features/installation/domain/installation.dart';
import 'package:floresta_gui/features/installation/data/existing_node_probe.dart';
import 'package:floresta_gui/features/installation/domain/existing_node.dart';
import 'package:floresta_gui/features/installation/presentation/installation_providers.dart';
import 'package:floresta_gui/features/node/domain/node_readiness.dart';
import 'package:floresta_gui/features/node/data/rpc_models.dart';
import 'package:floresta_gui/features/node/data/utreexo_peer_finder.dart';
import 'package:floresta_gui/features/node/domain/utreexo_peer.dart';
import 'package:floresta_gui/features/node/presentation/node_controller.dart';
import 'package:floresta_gui/features/node/presentation/utreexo_peer_controller.dart';
import 'package:floresta_gui/features/node/domain/node_process_state.dart';
import 'package:floresta_gui/features/node/domain/node_status.dart';
import 'package:floresta_gui/features/node/domain/node_rpc_repository.dart';
import 'package:floresta_gui/features/node/domain/peer.dart';
import 'package:floresta_gui/features/node/domain/preflight.dart';
import 'package:floresta_gui/features/node/domain/swift_sync.dart';
import 'package:floresta_gui/features/node/data/swift_sync_hints.dart';
import 'package:floresta_gui/features/settings/domain/node_settings.dart';
import 'package:floresta_gui/features/settings/presentation/settings_controller.dart';
import 'package:floresta_gui/features/onboarding/presentation/wizard_widgets.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/features/wallet/presentation/wallet_controller.dart';
import 'package:floresta_gui/features/wallet/presentation/amount_format.dart';
import 'package:floresta_gui/features/wallet/presentation/wallet_sync_controller.dart';
import 'package:floresta_gui/features/wallet/data/wallet_sync_engine.dart';
import 'package:floresta_gui/features/wallet/data/bip32_address_deriver.dart';
import 'package:floresta_gui/shared/widgets/common.dart';
import 'package:floresta_gui/shared/widgets/dash.dart' show DashStatRow;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'features/node/node_rpc_test.dart'
    show blockchainInfoJson, signetAfterSnapshot;
import 'helpers/fake_process.dart';
import 'helpers/fakes.dart';
import 'helpers/wallet_fixtures.dart';

const _found = FlorestaInstallation(
  executablePath: '/Users/a/.cargo/bin/florestad',
  source: ExecutableSource.wellKnown,
  version: FlorestaVersion(0, 9, 1),
);

/// Scripted Docker listing: no process is run.
class _FakeDocker extends DockerProbe {
  _FakeDocker(this.result)
    : super(
        platform: const HostPlatform(HostOs.macos, CpuArch.arm64),
        environment: const {},
      );
  final DockerScan result;
  @override
  Future<DockerScan> scan() async => result;
}

/// Scripted connection check: no socket is opened.
class _FakeExistingNode extends ExistingNodeProbe {
  _FakeExistingNode(this.result)
    : super(httpClient: MockClient((_) async => http.Response('', 500)));
  final ExistingNodeCheck result;
  final checked = <(BitcoinNetwork, int)>[];
  @override
  Future<ExistingNodeCheck> check(BitcoinNetwork network, int rpcPort) async {
    checked.add((network, rpcPort));
    return result;
  }
}

class _Harness {
  final install = FakeInstallationRepository(const Right(_found));
  final rpc = FakeNodeRpcRepository();
  final manager = FakeProcessManager();
  final wallet = FakeWalletRepository();
  final preflight = FakePreflightProbe();
  final hints = FakeSwiftSyncHints();
  final electrum = FakeElectrumProbe();

  BuildFlavor flavor = BuildFlavor.production;

  /// Per-test provider overrides, applied last.
  final extra = <Override>[];
  PeerProbe probeResult = const PeerProbe.failed('test');

  Future<void> pump(
    WidgetTester tester, {
    bool onboarded = true,
    String? network,
    Size size = const Size(1280, 860),
    bool? compactSidebar,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Status motion runs for as long as the node works (a syncing node
    // never "settles"), so these tests use the system's reduced-motion
    // setting, under which every status widget is static. Motion itself is
    // tested in test/shared/status_motion_test.dart.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    SharedPreferences.setMockInitialValues({
      'settings.onboardingComplete': onboarded,
      'settings.network': ?network,
      'ui.sidebarCompact': ?compactSidebar,
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        retry: (_, _) => null,
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          hostPlatformProvider.overrideWithValue(
            const HostPlatform(HostOs.macos, CpuArch.arm64),
          ),
          environmentProvider.overrideWithValue(const {'HOME': '/Users/a'}),
          installationRepositoryProvider.overrideWithValue(install),
          nodeRpcRepositoryProvider.overrideWithValue(rpc),
          nodeProcessManagerProvider.overrideWithValue(manager),
          walletRepositoryProvider.overrideWithValue(wallet),
          preflightProbeProvider.overrideWithValue(preflight),
          swiftSyncHintsProvider.overrideWithValue(hints),
          electrumProbeProvider.overrideWithValue(electrum),
          buildFlavorProvider.overrideWithValue(flavor),
          // The real engine over the Bitcoin Core fixture chain: no sockets.
          walletEngineFactoryProvider.overrideWithValue((account) {
            final server = FixtureElectrumClient();
            final engine = WalletSyncEngine(
              account: account,
              client: server,
              chain: FixtureChainView(),
              store: MemoryWalletStore(),
              deriver: Bip32AddressDeriver(),
              coverage: 25,
              indexingGrace: Duration.zero,
            );
            server.indexFixtureChain(engine.scripts.map((s) => s.scriptPubKey));
            return engine;
          }),
          // No DNS or P2P from widget tests.
          utreexoPeerFinderProvider.overrideWithValue(
            UtreexoPeerFinder(
              rpc: rpc,
              resolve: (_) async => const [],
              probe: (_, _, _) async => probeResult,
            ),
          ),
          ...extra,
        ],
        child: const FlorestaApp(),
      ),
    );
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('first launch shows onboarding', (tester) async {
    await _Harness().pump(tester, onboarded: false);
    expect(find.text('Welcome to Floresta'), findsOneWidget);

    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    expect(find.text('Get Floresta'), findsOneWidget);
    // One state for the whole screen: installed, so nothing offers to
    // install it again (2026-10-28).
    expect(find.text('Floresta is installed'), findsOneWidget);
    expect(find.textContaining('Floresta v0.9.1 is ready to use'), findsOne);
    expect(find.text('Install Floresta'), findsNothing);
    expect(find.text('Continue'), findsOneWidget);
    // Platform details are no longer on this screen (Diagnostics has them).
    expect(find.text('Operating system'), findsNothing);
    expect(find.text('This computer'), findsNothing);
  });

  Future<void> toWizard(WidgetTester tester) async {
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
  }

  Future<void> tapNext(WidgetTester tester, [String label = 'Next']) async {
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('the setup wizard walks every step and saves on Finish', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester, onboarded: false);
    await toWizard(tester);
    expect(find.text('Choose a network'), findsOneWidget);
    expect(find.bySemanticsLabel('Step 1 of 4: Network'), findsOneWidget);
    await tapNext(tester);
    expect(find.text('Storage'), findsWidgets);
    expect(find.bySemanticsLabel('Step 2 of 4: Storage'), findsOneWidget);
    expect(find.text('/Users/a/.floresta'), findsOneWidget);
    expect(find.textContaining('free on this disk'), findsOneWidget);
    await tapNext(tester);
    expect(find.textContaining('Assume Utreexo'), findsOneWidget);
    await tapNext(tester);
    expect(find.textContaining('Electrum server'), findsOneWidget);
    expect(find.textContaining('Node API (RPC)'), findsOneWidget);
    expect(find.text('Always on'), findsNWidgets(2));
    expect(find.text('Remote RPC'), findsNothing);
    expect(find.text('Not offered in this version'), findsOneWidget);
    await tapNext(tester, 'Review configuration');
    expect(find.text('Review your setup'), findsOneWidget);
    expect(
      find.textContaining('(Assume Utreexo), then re-checks the history'),
      findsOneWidget,
    );
    expect(find.text('Mainnet · real bitcoin'), findsOneWidget);
    expect(find.text('Edit'), findsNWidgets(4));

    await tapNext(tester, 'Start Floresta now');
    await tapNext(tester, 'Finish');
    expect(find.text('Start node'), findsOneWidget);
    expect(h.manager.starts, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('settings.onboardingComplete'), isTrue);
  });

  testWidgets('Back returns to the previous step, keeping choices', (
    tester,
  ) async {
    await _Harness().pump(tester, onboarded: false);
    await toWizard(tester);
    await tapNext(tester);
    await tapNext(tester);
    await tester.tap(find.textContaining('Full validation'));
    await tester.pumpAndSettle();
    expect(find.text('Starting from the first block is slow'), findsOneWidget);
    await tapNext(tester, 'Back');
    expect(find.text('Data directory'), findsOneWidget);
    await tapNext(tester);
    expect(find.text('Starting from the first block is slow'), findsOneWidget);
  });

  testWidgets('Finish with "start now" launches the chosen configuration', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester, onboarded: false);
    await toWizard(tester);
    await tapNext(tester);
    await tapNext(tester);
    await tester.tap(find.textContaining('Backfill in background'));
    await tester.pumpAndSettle();
    expect(find.text('History stays assumed'), findsOneWidget);
    await tapNext(tester);
    await tapNext(tester, 'Review configuration');
    expect(
      find.textContaining('(Assume Utreexo), history before it stays'),
      findsOneWidget,
    );
    await tapNext(tester, 'Finish');
    final (exe, settings) = h.manager.starts.single;
    expect(exe, _found.executablePath);
    expect(settings.network, BitcoinNetwork.bitcoin);
    expect(settings.assumeUtreexo, isTrue);
    expect(settings.backfill, isFalse);
    expect(settings.onboardingComplete, isTrue);
  });

  testWidgets('the wizard shows real folder problems from the preflight', (
    tester,
  ) async {
    final h = _Harness();
    h.preflight.facts = const PreflightFacts(
      rpcPort: 8332,
      rpcPortFree: true,
      electrumPort: 50001,
      electrumPortFree: true,
      dataDir: '/Users/a/.floresta',
      dataDirWritable: true,
      freeBytes: 2 * 1024 * 1024 * 1024,
      looksLikeBitcoinCore: true,
    );
    await h.pump(tester, onboarded: false);
    await toWizard(tester);
    await tapNext(tester);
    expect(find.text('This folder belongs to Bitcoin Core'), findsOneWidget);
    expect(find.text('Disk space is low'), findsOneWidget);
  });

  testWidgets('missing executable points to installation', (tester) async {
    final h = _Harness()
      ..install.result = const Left(
        ExecutableNotFoundFailure(['/usr/bin/florestad']),
      );
    await h.pump(tester);

    expect(find.text('Floresta is not ready to run'), findsOneWidget);
    final start = tester.widget<TextButton>(
      find.ancestor(
        of: find.text('Start node'),
        matching: find.byType(TextButton),
      ),
    );
    expect(start.onPressed, isNull);

    await tester.tap(find.text('Open Installation'));
    await tester.pumpAndSettle();
    expect(find.text('Floresta is not installed'), findsOneWidget);
    // No release source in this build: nothing offers an automatic install.
    expect(find.text('Install Floresta'), findsNothing);
    expect(find.text('Choose florestad…'), findsOneWidget);
    await tester.tap(find.text('Other ways to connect'));
    await tester.pumpAndSettle();
    expect(find.text('Build from source'), findsOneWidget);
    expect(find.text('Connect to a node that is already running'), findsOne);
  });

  testWidgets('Review: Edit returns to that step with the choices kept', (
    tester,
  ) async {
    await _Harness().pump(tester, onboarded: false);
    await toWizard(tester);
    await tapNext(tester);
    await tapNext(tester);
    await tester.tap(find.textContaining('Backfill in background'));
    await tester.pumpAndSettle();
    await tapNext(tester);
    await tapNext(tester, 'Review configuration');
    await tester.tap(find.bySemanticsLabel('Edit sync'));
    await tester.pumpAndSettle();
    expect(find.text('How the node gets to the tip of the chain.'), findsOne);
    expect(find.text('History stays assumed'), findsOneWidget);
    await tapNext(tester);
    await tapNext(tester, 'Review configuration');
    expect(find.textContaining('history before it stays assumed'), findsOne);
  });

  testWidgets('Advanced setup: connect to a running node, run none here', (
    tester,
  ) async {
    final existing = _FakeExistingNode((
      rpc: Right(
        RpcModels.blockchainInfo(blockchainInfoJson(chain: 'bitcoin')),
      ),
      electrum: ElectrumCheck.ok,
    ));
    final h = _Harness()
      ..install.result = const Left(ExecutableNotFoundFailure(['/x']))
      ..extra.addAll([
        existingNodeProbeProvider.overrideWithValue(existing),
        dockerProbeProvider.overrideWithValue(
          _FakeDocker(
            DockerContainers([
              DockerContainer(
                name: 'Floresta',
                image: 'dlsz/floresta:latest',
                command: 'florestad',
                state: 'running',
                status: 'Up 2 hours',
                ports: parseDockerPorts('0.0.0.0:8332->8332/tcp'),
              ),
            ]),
          ),
        ),
      ]);
    await h.pump(tester, onboarded: false);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    expect(find.text('Floresta is not installed'), findsOneWidget);

    await tester.tap(find.text('Advanced setup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect to a node that is already running'));
    await tester.pumpAndSettle();
    final use = find.widgetWithText(FilledButton, 'Use this node');
    // Nothing can be saved before the node answered.
    expect(tester.widget<FilledButton>(use).onPressed, isNull);
    await tester.tap(find.text('Check connection'));
    await tester.pumpAndSettle();
    expect(existing.checked.single, (BitcoinNetwork.bitcoin, 8332));
    expect(find.text('Floresta answers on Mainnet'), findsOneWidget);
    expect(find.text('Electrum server answers'), findsOneWidget);
    // The unauthenticated RPC published to the whole network is called out.
    expect(
      find.text('Container Floresta publishes port 8332 on every interface'),
      findsOneWidget,
    );
    await tester.ensureVisible(use);
    await tester.tap(use);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('settings.useExistingNode'), isTrue);
    expect(prefs.getBool('settings.onboardingComplete'), isTrue);
    // On Overview: nothing to start here, and no "not installed" warning.
    expect(find.text('Floresta is not ready to run'), findsNothing);
    expect(find.text('Start node'), findsNothing);
    expect(find.text('Check again'), findsOneWidget);
    expect(find.textContaining('Start your node where it runs'), findsOne);
    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();
    expect(h.manager.starts, isEmpty);
  });

  testWidgets('Sync shows the same status banner as Overview', (tester) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(signetAfterSnapshot));
    await h.pump(tester, network: 'signet');
    expect(find.text('Status: SYNCING'), findsOneWidget);
    expect(find.text('Go to Sync'), findsOneWidget);
    await tester.tap(find.text('Go to Sync'));
    await tester.pumpAndSettle();
    expect(find.text('Status: SYNCING'), findsOneWidget);
    expect(find.textContaining('leave it running in the background'), findsOne);
    // Actions that fit this page instead of a link to itself.
    expect(find.text('Go to Sync'), findsNothing);
    expect(find.text('View Peers'), findsOneWidget);
  });

  testWidgets('header bar: title left, status and actions at the right edge', (
    tester,
  ) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(signetAfterSnapshot));
    await h.pump(tester, network: 'signet', size: const Size(1600, 900));
    Rect bar() => tester.getRect(
      find
          .ancestor(
            of: find.byTooltip('Settings'),
            matching: find.byType(LayoutBuilder),
          )
          .first,
    );
    final gear = tester.getRect(find.byTooltip('Settings'));
    final title = tester.getRect(find.text('Overview').last);
    final tag = tester.getRect(find.text('Syncing'));
    final height = tester.getRect(find.text('Height: 327,843'));
    // The last action ends at the bar's edge (the gap used to be after
    // it), and the status group sits right, away from the title, in order:
    // status, height, actions.
    // (The 40 px button sits in a 48 px tap target, hence up to 4 px.)
    expect(bar().right - gear.right, lessThanOrEqualTo(4));
    expect(title.left - bar().left, lessThan(1));
    // The free space is between the title and the status (more than the
    // fixed 16 px spacer), and the right group is packed together.
    expect(tag.left - title.right, greaterThan(32));
    expect(height.left - tag.right, lessThan(48)); // gap + icon
    expect(height.left, greaterThan(tag.right));
    expect(find.text('Copy Endpoint'), findsOneWidget);

    // The smallest window: icon actions, still labelled, still at the edge.
    await h.pump(tester, network: 'signet', size: const Size(960, 640));
    expect(find.text('Copy Endpoint'), findsNothing);
    expect(find.byTooltip('Copy Endpoint: tcp://127.0.0.1:60001'), findsOne);
    expect(
      bar().right - tester.getRect(find.byTooltip('Settings')).right,
      lessThanOrEqualTo(4),
    );
  });

  testWidgets('a long Floresta version never overflows the sidebar, '
      'also while it collapses and expands', (tester) async {
    // Regression (2026-11-13): "v0.9.0 (master 3a47993)" overflowed the
    // footer by 2 px at 264 px, and by 38 px mid-animation.
    final h = _Harness()
      ..install.result = const Right(
        FlorestaInstallation(
          executablePath: '/Users/a/.cargo/bin/florestad',
          source: ExecutableSource.managed,
          version: FlorestaVersion(0, 9, 0),
          upstreamRef: 'master@3a47993595d1d865fb6bea6bce5e9818b5a6bd7e',
        ),
      );
    await h.pump(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('v0.9.0 (master 3a47993)'), findsOneWidget);
    expect(find.byTooltip('Floresta v0.9.0 (master 3a47993)'), findsOneWidget);

    // Real motion, frame by frame, through every intermediate width.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures();
    for (final toggle in ['Collapse sidebar', 'Expand sidebar']) {
      await tester.tap(find.byTooltip(toggle));
      for (var ms = 0; ms <= 300; ms += 10) {
        await tester.pump(const Duration(milliseconds: 10));
        expect(tester.takeException(), isNull, reason: '$toggle at $ms ms');
      }
    }
    // Narrowest window: still no overflow, at either width.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    tester.view.physicalSize = const Size(960, 640);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact sidebar: icons only, labels in tooltips, remembered', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester);
    double sidebarWidth() => tester
        .getSize(
          find
              .ancestor(
                of: find.byTooltip('Collapse sidebar'),
                matching: find.byType(AnimatedContainer),
              )
              .first,
        )
        .width;
    expect(sidebarWidth(), 264);
    expect(find.text('Self-Sovereign Validation'), findsOneWidget);

    await tester.tap(find.byTooltip('Collapse sidebar'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Expand sidebar'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('ui.sidebarCompact'), isTrue);
    double compactWidth() => tester
        .getSize(
          find
              .ancestor(
                of: find.byTooltip('Expand sidebar'),
                matching: find.byType(AnimatedContainer),
              )
              .first,
        )
        .width;
    expect(compactWidth(), 80);
    // Every destination is an icon with its name as a tooltip, still
    // selectable, and the decoration is gone.
    for (final label in ['Overview', 'Sync', 'Peers', 'Wallet', 'Help']) {
      expect(find.byTooltip(label), findsOneWidget, reason: label);
    }
    expect(find.text('Self-Sovereign Validation'), findsNothing);
    await tester.tap(find.byTooltip('Peers'));
    await tester.pumpAndSettle();
    expect(find.text('Peers'), findsWidgets); // the header title

    // Kept across restarts.
    await h.pump(tester, compactSidebar: true);
    expect(find.byTooltip('Expand sidebar'), findsOneWidget);
    // Ctrl+\ (Cmd on macOS) toggles it back; tests run as non-macOS.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.backslash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Collapse sidebar'), findsOneWidget);
  });

  testWidgets('setup screens sit in the middle of the window', (tester) async {
    await _Harness().pump(tester, onboarded: false);
    Rect card() => tester.getRect(
      find
          .ancestor(
            of: find.text('Welcome to Floresta'),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    // 1280 x 860: centred on both axes (it used to hug the top).
    expect(card().center.dx, moreOrLessEquals(640, epsilon: 1));
    expect(card().center.dy, moreOrLessEquals(430, epsilon: 80));
    final welcomeWidth = card().width;
    expect(welcomeWidth, WizardFrame.cardWidth);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    final install = tester.getRect(
      find
          .ancestor(
            of: find.text('Get Floresta'),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    expect(install.center.dx, moreOrLessEquals(640, epsilon: 1));
    expect(install.width, welcomeWidth);
  });

  testWidgets('INS-12: resetting settings brings the wizard back', (
    tester,
  ) async {
    await _Harness().pump(tester);
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    final reset = find.text('Reset settings…');
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(find.text('Reset app settings?'), findsOneWidget);
    await tester.tap(find.text('Reset settings'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Floresta'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('settings.onboardingComplete'), isNull);
  });

  testWidgets('INS-12: nothing can be reset while the node runs', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.tap(find.text('Start node'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Delete node data…'));
    expect(
      find.text('Stop it from Node before resetting anything here.'),
      findsOneWidget,
    );
    for (final label in ['Reset settings…', 'Delete node data…']) {
      final button = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(button.onPressed, isNull, reason: label);
    }
  });

  testWidgets('SYNC-05: our node without Utreexo peers gets verified ones', (
    tester,
  ) async {
    final h = _Harness()
      ..probeResult = const PeerProbe(
        protocolVersion: 70016,
        services: 0x340d,
        userAgent: '/btcwire:0.5.0/utreexod:0.5.2/',
        height: 970486,
      )
      ..rpc.peers = const [
        Peer(
          id: 1,
          address: '1.2.3.4:8333',
          userAgent: '/Satoshi:31.1.0/',
          inbound: false,
          kind: 'regular',
          state: 'Ready',
          transport: 'V2',
          initialHeight: 973047,
          services: ['NETWORK', 'WITNESS'],
        ),
      ];
    await h.pump(tester);
    await tester.tap(find.text('Start node'));
    await tester.pumpAndSettle();
    // Our node is up and answering now.
    h.rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()));
    h.manager.emit(ProcessRunning(9, DateTime(2026)));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    // Mainnet (production default): the curated utreexod entry, verified
    // by the (fake) handshake, is added over v1 for good.
    expect(
      h.rpc.addNodeCalls,
      contains(('161.97.178.61:8333', AddNodeCommand.add, false)),
    );
  });

  testWidgets('after a restart past the snapshot, a behind utreexod is '
      'dropped and not re-added while the node selects its chain '
      '(mainnet 2026-10-28)', (tester) async {
    Peer peer(int id, String address, int height, List<String> services) =>
        Peer(
          id: id,
          address: address,
          userAgent: '/Satoshi:31.1.0/',
          inbound: false,
          kind: 'regular',
          state: 'Ready',
          transport: 'V2',
          initialHeight: height,
          services: services,
        );
    final h = _Harness()
      ..probeResult = const PeerProbe(
        protocolVersion: 70016,
        services: 0x340d,
        userAgent: '/btcwire:0.5.0/utreexod:0.5.2/',
        height: 970486,
      )
      ..rpc.peers = [
        for (var i = 1; i <= 9; i++)
          peer(i, '10.0.0.$i:8333', 973511, ['NETWORK', 'WITNESS']),
        peer(12, '161.97.178.61:8333', 970486, ['NETWORK', '0x3000']),
      ];
    await h.pump(tester);
    await tester.tap(find.text('Start node'));
    await tester.pumpAndSettle();
    final starts = h.manager.starts.length;
    // An earlier run validated up to 940 045; this one is selecting.
    h.manager.logs = [
      LogLine(
        DateTime(2026, 10, 28, 3, 21, 7),
        LogSource.stdout,
        '2026-10-28 03:21:07  INFO floresta_wire::p2p_wire::node::'
        'chain_selector_ctx: Starting IBD, selecting the best chain',
      ),
    ];
    h.rpc.info = Right(
      RpcModels.blockchainInfo({
        ...signetAfterSnapshot,
        'chain': 'bitcoin',
        'height': 973512,
        'validated': 940045,
      }),
    );
    h.manager.emit(ProcessRunning(9, DateTime(2026)));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    // Before, "validated == 0" kept these rules off here and the node
    // waited forever for the utreexod's answer.
    expect(h.rpc.disconnected, contains('161.97.178.61:8333'));
    expect(
      h.rpc.addNodeCalls.where((c) => c.$1 == '161.97.178.61:8333'),
      isEmpty,
    );
    expect(h.manager.starts, hasLength(starts)); // dropped, not restarted
  });

  testWidgets(
    'SYNC-05: silent Utreexo peers do not stop the search (observed)',
    (tester) async {
      final h = _Harness()
        ..probeResult = const PeerProbe(
          protocolVersion: 70016,
          services: 0x340d,
          userAgent: '/btcwire:0.5.0/utreexod:0.5.2/',
          height: 970486,
        )
        ..rpc.peers = const [
          Peer(
            id: 2,
            address: '189.44.63.101:8333',
            userAgent: '/bridge:0.1.3/',
            inbound: false,
            kind: 'regular',
            state: 'Ready',
            transport: 'V2',
            initialHeight: 973099,
            services: ['WITNESS', 'P2P_V2', '0x1000'],
          ),
          Peer(
            id: 3,
            address: '194.163.132.180:8333',
            userAgent: '/bridge:0.1.3/',
            inbound: false,
            kind: 'regular',
            state: 'Ready',
            transport: 'V2',
            initialHeight: 973099,
            services: ['WITNESS', 'P2P_V2', '0x1000'],
          ),
          Peer(
            id: 1,
            address: '1.2.3.4:8333',
            userAgent: '/Satoshi:31.1.0/',
            inbound: false,
            kind: 'regular',
            state: 'Ready',
            transport: 'V2',
            initialHeight: 973047,
            services: ['NETWORK', 'WITNESS'],
          ),
        ];
      await h.pump(tester);
      await tester.tap(find.text('Start node'));
      await tester.pumpAndSettle();
      // Our node is up and answering now.
      h.rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()));
      h.manager.emit(ProcessRunning(9, DateTime(2026)));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      // Mainnet (production default): the curated utreexod entry, verified
      // by the (fake) handshake, is added over v1 for good.
      expect(
        h.rpc.addNodeCalls,
        contains(('161.97.178.61:8333', AddNodeCommand.add, false)),
      );
    },
  );

  testWidgets('start launches the detected executable', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.tap(find.text('Start node'));
    await tester.pumpAndSettle();
    expect(h.manager.starts.single.$1, _found.executablePath);
    expect(find.text('Running'), findsWidgets);
    // The data folder holds the watch-only wallet: made private first.
    expect(h.preflight.restricted, ['/Users/a/.floresta']);
  });

  testWidgets('production builds default to mainnet and say so', (
    tester,
  ) async {
    await _Harness().pump(tester);
    expect(find.text('Mainnet'), findsWidgets);
    expect(find.text('Real bitcoin'), findsOneWidget);
    expect(find.text('Development build'), findsNothing);
  });

  testWidgets('development builds are labelled in the sidebar', (tester) async {
    final h = _Harness()..flavor = BuildFlavor.development;
    await h.pump(tester, network: 'signet');
    expect(find.text('Development build'), findsOneWidget);
  });

  testWidgets('a test network is clearly marked everywhere', (tester) async {
    await _Harness().pump(tester, network: 'signet');
    expect(find.text('Test network: coins have no value'), findsOneWidget);
    expect(find.text('Signet: test network'), findsOneWidget);
  });

  testWidgets('test networks sit under an advanced section in production', (
    tester,
  ) async {
    await _Harness().pump(tester, onboarded: false);
    await toWizard(tester);
    expect(find.text('Test networks (advanced)'), findsOneWidget);
    expect(find.text('Signet'), findsNothing);
    await tester.tap(find.text('Test networks (advanced)'));
    await tester.pumpAndSettle();
    expect(find.text('Regtest'), findsOneWidget);
    await tester.tap(find.text('Signet'));
    await tester.pumpAndSettle();
    expect(find.text('Test network: coins have no value'), findsOneWidget);
  });

  testWidgets('development builds default to signet with the section open', (
    tester,
  ) async {
    final h = _Harness()..flavor = BuildFlavor.development;
    await h.pump(tester, onboarded: false);
    await toWizard(tester);
    expect(
      find.text('Development build'),
      findsNothing,
    ); // onboarding has no sidebar
    final signet = tester.widget<OptionCard>(
      find.widgetWithText(OptionCard, 'Signet'),
    );
    expect(signet.selected, isTrue);
  });

  testWidgets('networks without a built-in state skip the fast start choice', (
    tester,
  ) async {
    await _Harness().pump(tester, onboarded: false, network: 'regtest');
    await toWizard(tester);
    await tapNext(tester);
    await tapNext(tester);
    expect(find.textContaining('Full validation'), findsOneWidget);
    expect(find.textContaining('Assume Utreexo'), findsNothing);
    expect(find.textContaining('Swift Sync'), findsNothing);
  });

  group('Swift Sync (ADR-0011)', () {
    const swiftCapable = FlorestaInstallation(
      executablePath: '/Users/a/.cargo/bin/florestad',
      source: ExecutableSource.wellKnown,
      version: FlorestaVersion(0, 9, 0),
      swiftSync: true,
    );

    testWidgets('is the default for a new node and prepares hints first', (
      tester,
    ) async {
      final h = _Harness()..install.result = const Right(swiftCapable);
      h.hints.result = const Right(HintsReady(970000, downloaded: true));
      await h.pump(tester, onboarded: false);
      await toWizard(tester);
      await tapNext(tester);
      await tapNext(tester);
      expect(find.textContaining('Swift Sync (recommended)'), findsOneWidget);
      expect(find.text('Before the first start'), findsOneWidget);
      await tapNext(tester);
      await tapNext(tester, 'Review configuration');
      expect(find.textContaining('Swift Sync from the first block'), findsOne);
      await tapNext(tester, 'Finish');
      final (_, settings) = h.manager.starts.single;
      expect(settings.syncMethod, SyncMethod.swiftSync);
      expect(h.hints.prepared.single.syncMethod, SyncMethod.swiftSync);
    });

    testWidgets('is unavailable with a florestad built without it', (
      tester,
    ) async {
      await _Harness().pump(tester, onboarded: false);
      await toWizard(tester);
      await tapNext(tester);
      await tapNext(tester);
      expect(find.textContaining('Swift Sync (unavailable)'), findsOneWidget);
      expect(find.textContaining('built without Swift Sync'), findsOneWidget);
      // The default gives way to Fast Start so the node can start.
      expect(find.textContaining('Backfill in background'), findsOneWidget);
    });

    testWidgets('a failed hints download keeps the node stopped', (
      tester,
    ) async {
      final h = _Harness()..install.result = const Right(swiftCapable);
      h.hints.result = const Left(
        SwiftSyncHintsFailure('Could not download the Swift Sync hints.'),
      );
      await h.pump(tester, onboarded: false);
      await toWizard(tester);
      for (var i = 0; i < 3; i++) {
        await tapNext(tester);
      }
      await tapNext(tester, 'Review configuration');
      await tapNext(tester, 'Finish');
      expect(h.manager.starts, isEmpty);
      expect(find.textContaining('Swift Sync hints problem'), findsOneWidget);
    });

    testWidgets('a selected Swift Sync never starts a florestad without it', (
      tester,
    ) async {
      final h = _Harness();
      await h.pump(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(FlorestaApp)),
      );
      await container
          .read(settingsControllerProvider.notifier)
          .update(
            container
                .read(settingsControllerProvider)
                .withSyncMethod(SyncMethod.swiftSync),
          );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start node'));
      await tester.pumpAndSettle();
      expect(h.manager.starts, isEmpty);
      expect(h.hints.prepared, isEmpty);
    });

    testWidgets('progress from the log keeps a long Swift Sync from '
        'looking stalled', (tester) async {
      final h = _Harness()
        ..install.result = const Right(swiftCapable)
        ..rpc.info = Right(
          RpcModels.blockchainInfo(
            blockchainInfoJson(blocks: 0, headers: 320500, ibd: true),
          ),
        );
      await h.pump(tester, network: 'signet');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(FlorestaApp)),
      );
      h.manager.swiftSync = const SwiftSyncProgress(
        phase: SwiftSyncPhase.running,
        processed: 98000,
        stopHeight: 320000,
        workers: 10,
      );
      h.manager.emit(ProcessRunning(9, DateTime(2026)));
      await container.read(nodeControllerProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(
        container.read(nodeReadinessProvider).stage,
        ReadinessStage.swiftSyncing,
      );
      // Overview: the processed count, not a validated height of 0.
      expect(find.text('Blocks Processed'), findsOneWidget);
      expect(find.text('98,000'), findsOneWidget);
      expect(container.read(nodeReadinessProvider).stalledFor, isNull);
    });
  });

  testWidgets('a blocking preflight problem prevents the start', (
    tester,
  ) async {
    final h = _Harness();
    h.preflight.facts = const PreflightFacts(
      rpcPort: 38332,
      rpcPortFree: true,
      electrumPort: 60001,
      electrumPortFree: false,
      dataDir: '/Users/a/.floresta/signet',
      dataDirWritable: true,
      freeBytes: 100 * 1024 * 1024 * 1024,
      looksLikeBitcoinCore: false,
    );
    await h.pump(tester);
    await tester.tap(find.text('Start node'));
    await tester.pumpAndSettle();
    expect(h.manager.starts, isEmpty);
    expect(find.textContaining('Port 60001 is in use'), findsOneWidget);
  });

  testWidgets('low disk space warns but still starts', (tester) async {
    final h = _Harness();
    h.preflight.facts = const PreflightFacts(
      rpcPort: 38332,
      rpcPortFree: true,
      electrumPort: 60001,
      electrumPortFree: true,
      dataDir: '/Users/a/.floresta/signet',
      dataDirWritable: true,
      freeBytes: 3 * 1024 * 1024 * 1024,
      looksLikeBitcoinCore: false,
    );
    await h.pump(tester);
    await tester.tap(find.text('Start node'));
    await tester.pumpAndSettle();
    expect(h.manager.starts, hasLength(1));
    expect(find.text('Disk space is low'), findsOneWidget);
  });

  testWidgets('a node left running by an earlier session is adopted', (
    tester,
  ) async {
    final h = _Harness()
      ..manager.adoptable = ProcessAdopted(321, DateTime(2026))
      ..rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()));
    await h.pump(tester);
    expect(find.text('Started outside this app'), findsNothing);
    expect(find.textContaining('Process 321, reconnected'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
  });

  testWidgets('sync panel separates the snapshot from own verification', (
    tester,
  ) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(signetAfterSnapshot));
    await h.pump(tester, network: 'signet');
    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();
    expect(find.text('Accepted from snapshot'), findsOneWidget);
    expect(find.text('Verified by this node'), findsOneWidget);
    expect(find.text('None yet'), findsOneWidget);
    expect(find.textContaining('% validated'), findsNothing);
    expect(find.textContaining('90.5'), findsNothing);
  });

  testWidgets('SYNC-03: the network tip from peers is labelled an estimate', (
    tester,
  ) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(signetAfterSnapshot))
      ..rpc.peers = const [
        Peer(
          id: 1,
          address: '1.2.3.4:38333',
          userAgent: '/Satoshi:30.0.0/',
          inbound: false,
          kind: 'regular',
          state: 'Ready',
          transport: 'V2',
          initialHeight: 327900,
          services: ['NETWORK', 'WITNESS'],
        ),
      ];
    await h.pump(tester, network: 'signet');
    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();
    expect(find.text('Network tip (estimate from peers)'), findsOneWidget);
    // 327 900 from the peer, 296 870 validated (signetAfterSnapshot).
    expect(
      find.text('327,900 · about 31,030 blocks left to verify'),
      findsOneWidget,
    );
  });

  testWidgets('after our node exits, no stale API makes it look external', (
    tester,
  ) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()));
    await h.pump(tester);
    h.manager.emit(ProcessRunning(9, DateTime(2026)));
    await tester.pumpAndSettle();
    expect(find.text('Stop'), findsOneWidget);

    // The node exits; its API is gone too.
    h.rpc.info = const Left(RpcUnreachableFailure('http://127.0.0.1:8332/'));
    h.manager.emit(const ProcessStopped(0));
    await tester.pump();
    expect(find.text('Started outside this app'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('Start node'), findsOneWidget);
    expect(find.text('Started outside this app'), findsNothing);
  });

  testWidgets('a busy node missing polls is not shown as down (NODE-12)', (
    tester,
  ) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()));
    await h.pump(tester);
    h.manager.emit(ProcessRunning(9, DateTime(2026)));
    await tester.pumpAndSettle();
    final controller = ProviderScope.containerOf(
      tester.element(find.byType(FlorestaApp)),
    ).read(nodeControllerProvider.notifier);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(FlorestaApp)),
    );

    h.rpc.info = const Left(RpcUnreachableFailure('http://127.0.0.1:8332/'));
    for (var i = 1; i < NodeController.failuresBeforeUnreachable; i++) {
      await controller.refresh();
      await tester.pump();
      expect(
        container.read(nodeControllerProvider).api,
        ApiReachability.reachable,
        reason: 'failure $i is tolerated',
      );
    }
    await controller.refresh();
    await tester.pump();
    expect(
      container.read(nodeControllerProvider).api,
      ApiReachability.unreachable,
    );
  });

  testWidgets('a node we did not start is shown down on the first failure', (
    tester,
  ) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()));
    await h.pump(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(FlorestaApp)),
    );
    h.rpc.info = const Left(RpcUnreachableFailure('http://127.0.0.1:8332/'));
    await container.read(nodeControllerProvider.notifier).refresh();
    await tester.pump();
    expect(
      container.read(nodeControllerProvider).api,
      ApiReachability.unreachable,
    );
  });

  testWidgets('shows sync state from the node API', (tester) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()));
    await h.pump(tester);
    expect(find.text('Synced'), findsWidgets);
    expect(find.text('Started outside this app'), findsOneWidget);
    expect(find.text('Start node'), findsNothing);
  });

  testWidgets('page body scrollbar stays attached while scrolling', (
    tester,
  ) async {
    final controller = ScrollController();

    await tester.pumpWidget(
      MaterialApp(
        home: PrimaryScrollController(
          controller: controller,
          child: Scaffold(
            body: PageBody(
              children: [
                const SizedBox(height: 1200),
                const Text('At the bottom'),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.byType(Scrollable), const Offset(0, -240));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('wallet is clearly watch-only with no spend actions', (
    tester,
  ) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()))
      ..wallet.descriptors = Right(['wpkh(${FakeKeys.xpub}/0/*)']);
    await h.pump(tester);
    await tester.tap(find.text('Wallet'));
    await tester.pumpAndSettle();

    expect(find.text('Watch-only: can see, cannot spend'), findsOneWidget);
    for (final forbidden in ['Send', 'Sign', 'Broadcast', 'Receive']) {
      expect(find.text(forbidden), findsNothing);
    }
    // Descriptors are masked until revealed.
    expect(find.textContaining(FakeKeys.xpub), findsNothing);
    expect(find.text('127.0.0.1:50001'), findsOneWidget); // mainnet default
  });

  testWidgets('WAL-03: a synced wallet shows Core\'s balance, addresses '
      'and activity', (tester) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()))
      ..wallet.descriptors = Right([
        vectorType('wpkh')['external']! as String,
        vectorType('wpkh')['internal']! as String,
      ]);
    await h.pump(tester, network: 'regtest');
    await tester.tap(find.text('Wallet'));
    await tester.pumpAndSettle();

    final expected = chainVectors['expected_balances']! as Map;
    final trusted = btcToSats(expected['trusted'] as num);
    final immature = btcToSats(expected['immature'] as num);
    expect(find.text(formatBtc(trusted + immature)), findsOneWidget);
    expect(
      find.text(
        'Spendable ${formatBtc(trusted)} · immature ${formatBtc(immature)}',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('1 wallet · 2 descriptors'), findsOneWidget);
    expect(find.text('Receive #0'), findsOneWidget);
    expect(find.textContaining('bcrt1q'), findsWidgets);
    await tester.ensureVisible(find.text('Activity'));
    expect(find.text('Received'), findsWidgets);
    expect(find.textContaining('confirmations · block'), findsWidgets);
    // Watch-only: still no spending vocabulary anywhere.
    for (final forbidden in ['Send', 'Sign', 'Broadcast']) {
      expect(find.text(forbidden), findsNothing);
    }
  });

  testWidgets('WAL-07: "No wallets yet" only after two empty answers', (
    tester,
  ) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()));
    await h.pump(tester);
    await tester.tap(find.text('Wallet'));
    await tester.pump();
    await tester.pump();
    expect(
      find.text('Checking which wallets the node watches…'),
      findsOneWidget,
    );
    expect(find.text('No wallets yet'), findsNothing);
    await tester.pump(WalletController.recheckAfter);
    await tester.pumpAndSettle();
    expect(find.text('No wallets yet'), findsOneWidget);
  });

  testWidgets('importing a multipath descriptor watches both branches', (
    tester,
  ) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()));
    await h.pump(tester, network: 'regtest');
    await tester.tap(find.text('Wallet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add descriptor'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Descriptor'),
      vectorType('wpkh')['multipath']! as String,
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(h.wallet.loaded, [
      vectorType('wpkh')['external'],
      vectorType('wpkh')['internal'],
    ]);
    expect(find.textContaining('1 wallet · 2 descriptors'), findsOneWidget);
    // Named with the suggestion when the user keeps it.
    expect(find.textContaining('Wallet 1'), findsWidgets);
  });

  Future<void> addWallet(WidgetTester tester, {required String name}) async {
    await tester.tap(find.text('Add descriptor'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), name);
    await tester.enterText(
      find.widgetWithText(TextField, 'Descriptor'),
      vectorType('wpkh')['multipath']! as String,
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
  }

  testWidgets('a wallet is named when added, renamed and kept by its id', (
    tester,
  ) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()));
    await h.pump(tester, network: 'regtest');
    await tester.tap(find.text('Wallet'));
    await tester.pumpAndSettle();
    await addWallet(tester, name: '  Savings  ');
    expect(find.textContaining('Savings'), findsWidgets);

    await tester.tap(find.byTooltip('Rename Savings'));
    await tester.pumpAndSettle();
    // Key material is refused as a name; a private key is also cleared.
    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'mine ${FakeKeys.xprv}',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('extended private key'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Name'))
          .controller!
          .text,
      isEmpty,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      FakeKeys.tpub,
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot contain a key'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'Cold storage',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Cold storage'), findsWidgets);
    expect(find.textContaining('Savings'), findsNothing);

    // Stored by account id only: no descriptor or key in preferences.
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('wallet.labels')!;
    expect(stored, contains('Cold storage'));
    expect(stored, isNot(contains('pub')));
    expect(stored, isNot(contains('wpkh')));
  });

  testWidgets('a key typed as the name never reaches the node', (tester) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()));
    await h.pump(tester, network: 'regtest');
    await tester.tap(find.text('Wallet'));
    await tester.pumpAndSettle();
    await addWallet(tester, name: FakeKeys.wifCompressed);
    expect(find.textContaining('WIF private key'), findsOneWidget);
    expect(h.wallet.loaded, isEmpty);
  });

  testWidgets('removing a wallet hides it here; showing it again brings it '
      'back (the node keeps watching)', (tester) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()));
    await h.pump(tester, network: 'regtest');
    await tester.tap(find.text('Wallet'));
    await tester.pumpAndSettle();
    await addWallet(tester, name: 'Spending');
    expect(find.textContaining('1 wallet · 2 descriptors'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove Spending'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Floresta itself keeps watching'), findsOne);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.textContaining('0 wallets'), findsOneWidget);
    expect(find.byTooltip('Remove Spending'), findsNothing);
    expect(find.text('Removed from this app (1)'), findsOneWidget);
    // Nothing was asked of the node: it cannot forget a descriptor.
    expect(h.wallet.loaded, hasLength(2));

    await tester.tap(find.text('Removed from this app (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show again'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 wallet · 2 descriptors'), findsOneWidget);
    expect(find.byTooltip('Remove Spending'), findsOneWidget);
  });

  testWidgets('import dialog refuses private keys and clears them', (
    tester,
  ) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()));
    await h.pump(tester);
    await tester.tap(find.text('Wallet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add descriptor'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Descriptor'),
      'wpkh(${FakeKeys.xprv}/0/*)',
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('Private key material detected'), findsOneWidget);
    expect(h.wallet.loaded, isEmpty);
    final field = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Descriptor'),
    );
    expect(field.controller!.text, isEmpty);
  });

  testWidgets('UX-03/04: Overview and Sync show the node\'s real numbers', (
    tester,
  ) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(signetAfterSnapshot))
      ..rpc.peers = const [
        Peer(
          id: 1,
          address: '1.2.3.4:38333',
          userAgent: '/Satoshi:30.0.0/',
          inbound: false,
          kind: 'regular',
          state: 'Ready',
          transport: 'V2',
          initialHeight: 327900,
          services: ['NETWORK', 'WITNESS'],
        ),
        Peer(
          id: 2,
          address: '5.6.7.8:38333',
          userAgent: '/Floresta:0.9.1/',
          inbound: true,
          kind: 'regular',
          state: 'Ready',
          transport: 'V1',
          initialHeight: 327843,
          services: ['NETWORK'],
        ),
      ];
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await h.pump(tester, network: 'signet');

    // Header bar: status, header height, behind (estimate from peers).
    expect(find.text('Overview'), findsWidgets);
    expect(find.text('Syncing'), findsOneWidget);
    expect(find.text('Height: 327,843'), findsOneWidget);
    expect(find.text('Behind by: ~31.0k'), findsOneWidget);

    // Banner and Syncing card. 296 870 is the signet snapshot, so nothing
    // after it is verified yet: 0.0 %, not florestad's 90.56 % "progress".
    expect(find.text('Status: SYNCING'), findsOneWidget);
    expect(find.text('Phase: Blocks'), findsOneWidget);
    expect(find.text('0.0%'), findsOneWidget);
    expect(find.textContaining('90.5'), findsNothing);
    expect(find.text('Current Height'), findsOneWidget);
    expect(find.text('296,870'), findsOneWidget);
    expect(find.text('327,900'), findsOneWidget);
    expect(find.text('~ 31,030 blocks'), findsOneWidget);

    // Backfill: no progress reported upstream, so no percentage.
    expect(find.text('Mode: ON (recommended on desktop)'), findsOneWidget);
    expect(find.text('Running'), findsWidgets);
    expect(find.textContaining('does not report how far'), findsOneWidget);

    // Peers and services.
    expect(find.text('2 Connected'), findsOneWidget);
    expect(find.text('v2: 1  •  v1: 1'), findsOneWidget);
    expect(find.text('Ready tcp://127.0.0.1:60001'), findsOneWidget);
    expect(find.text('Metrics (Prometheus)'), findsOneWidget);

    await tester.tap(find.text('Copy Endpoint'));
    await tester.pump();
    expect(copied, 'tcp://127.0.0.1:60001');
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('View Peers'));
    await tester.tap(find.text('View Peers'));
    await tester.pumpAndSettle();
    // Card and advanced table.
    expect(find.text('1.2.3.4:38333'), findsNWidgets(2));
    expect(find.text('5.6.7.8:38333'), findsNWidgets(2));
    await tester.tap(find.text('Overview').first);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('View Sync Details'));
    await tester.tap(find.text('View Sync Details'));
    await tester.pumpAndSettle();
    expect(
      find.text('Step 2/3 – Downloading & Verifying Blocks'),
      findsOneWidget,
    );
    expect(find.text('Phase Blocks'), findsOneWidget);
    expect(find.text('2  (1 v2 / 1 v1)'), findsOneWidget);
    expect(find.text('Background Backfill Active'), findsOneWidget);
    expect(find.text('Pause Backfill'), findsNothing); // not supported
    expect(find.text('Verified by this node'), findsOneWidget);

    await tester.tap(find.text('Logs').first);
    await tester.pumpAndSettle();
    expect(find.text('System Logs'), findsOneWidget);
    expect(find.text('Daemon output'), findsOneWidget);
  });

  testWidgets('headers step without peers: header count, no tip, no 100 %', (
    tester,
  ) async {
    final h = _Harness()
      ..rpc.info = Right(
        RpcModels.blockchainInfo({
          ...signetAfterSnapshot,
          'validated': 0,
          'height': 24000,
        }),
      );
    await h.pump(tester, network: 'signet');

    // Overview: label and count in the same row (with no peers the target
    // is the header count too, so "24,000" appears twice).
    final row = find.ancestor(
      of: find.text('Headers Downloaded'),
      matching: find.byType(DashStatRow),
    );
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('24,000')), findsOne);
    expect(find.text('Current Height'), findsNothing);
    // No peers yet, so no network tip: no "100 %" from the node's own
    // headers and no "Behind by" in the header bar (2026-10-28).
    expect(find.text('100.0%'), findsNothing);
    expect(find.textContaining('Behind by'), findsNothing);
    expect(find.text('Waiting for peers'), findsOneWidget);
    expect(find.text('Unknown'), findsOneWidget);

    await tester.ensureVisible(find.text('View Sync Details'));
    await tester.tap(find.text('View Sync Details'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Step 1/3'), findsOneWidget);
    expect(find.text('Headers Downloaded'), findsOneWidget);
    expect(find.text('24,000'), findsWidgets); // card and details
    expect(find.text('Current Height'), findsNothing);
    expect(find.text('100.0%'), findsNothing);
    expect(find.text('Waiting for peers'), findsOneWidget);
    expect(find.textContaining('waiting for peers to report'), findsOneWidget);
  });

  testWidgets('UX-05..09: every Figma sidebar screen opens', (tester) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()));
    await h.pump(tester);
    for (final (item, shown) in [
      ('Peers', 'Peers are other nodes. More peers = smoother syncing.'),
      ('RPC Console', 'RPC Call Console'),
      ('Electrum', 'Electrum Console'),
      ('Logs', 'System Logs'),
      ('Help', 'Glossary'),
    ]) {
      await tester.tap(find.text(item).first);
      await tester.pumpAndSettle();
      expect(find.text(shown), findsOneWidget, reason: item);
    }
  });

  testWidgets('Add Peer refuses host names and sends addnode for an IP', (
    tester,
  ) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()));
    await h.pump(tester);
    await tester.tap(find.text('Peers').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add Peer'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'seed.example.com:8333');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.textContaining('IP addresses only'), findsOneWidget);
    expect(h.rpc.addNodeCalls, isEmpty);

    await tester.enterText(find.byType(TextField), '203.0.113.7:8333');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(h.rpc.addNodeCalls.single, (
      '203.0.113.7:8333',
      AddNodeCommand.add,
      false,
    ));
  });

  testWidgets('RPC console runs templates and guards risky calls', (
    tester,
  ) async {
    final calls = <(String, List<Object?>)>[];
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()))
      ..extra.add(
        rpcConsoleRepositoryProvider.overrideWithValue(
          _FakeConsole((m, p) {
            calls.add((m, p));
            return {'chain': 'signet', 'blocks': 200000};
          }),
        ),
      );
    await h.pump(tester);
    await tester.tap(find.text('RPC Console').first);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Run Call'));
    await tester.tap(find.text('Run Call'));
    await tester.pumpAndSettle();
    expect(calls.single.$1, 'getblockchaininfo');
    expect(calls.single.$2, isEmpty);
    expect(find.textContaining('"blocks": 200000'), findsOneWidget);

    // State-changing methods ask first; cancelling sends nothing.
    await tester.enterText(find.byType(TextField).first, 'stop');
    await tester.ensureVisible(find.text('Run Call'));
    await tester.tap(find.text('Run Call'));
    await tester.pumpAndSettle();
    expect(find.text('Run stop?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));

    // Key material never leaves the app.
    await tester.enterText(find.byType(TextField).first, 'loaddescriptor');
    await tester.enterText(
      find.byType(TextField).last,
      '["wpkh(${FakeKeys.xprv}/0/*)"]',
    );
    await tester.ensureVisible(find.text('Run Call'));
    await tester.tap(find.text('Run Call'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Private key material detected'),
      findsOneWidget,
    );
    expect(calls, hasLength(1));
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      isEmpty,
    );
  });

  testWidgets('Electrum console shows the server answer', (tester) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()))
      ..extra.add(
        electrumConsoleRepositoryProvider.overrideWithValue(
          _FakeConsole((m, p) => ['Floresta 0.9.1', '1.4']),
        ),
      );
    await h.pump(tester);
    await tester.tap(find.text('Electrum').first);
    await tester.pumpAndSettle();
    expect(find.text('server.version'), findsWidgets);
    await tester.ensureVisible(find.text('Run Call'));
    await tester.tap(find.text('Run Call'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"Floresta 0.9.1"'), findsOneWidget);
  });

  testWidgets('Logs filters daemon output by area', (tester) async {
    final h = _Harness()
      ..rpc.info = Right(RpcModels.blockchainInfo(blockchainInfoJson()));
    h.manager.logs = [
      LogLine(
        DateTime(2026, 10, 25, 18, 23, 41),
        LogSource.stdout,
        '2026-10-25 18:23:41  INFO floresta_chain::pruned_utreexo::chain_state: '
        'New tip! height=940729',
      ),
      LogLine(
        DateTime(2026, 10, 25, 18, 23, 42),
        LogSource.stdout,
        '2026-10-25 18:23:42  WARN floresta_wire::p2p_wire::node: '
        'Peer timed out',
      ),
    ];
    await h.pump(tester);
    await tester.tap(find.text('Logs').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('New tip!'), findsOneWidget);
    expect(find.textContaining('Peer timed out'), findsOneWidget);

    await tester.tap(find.text('Network'));
    await tester.pumpAndSettle();
    expect(find.textContaining('New tip!'), findsNothing);
    expect(find.textContaining('Peer timed out'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets('every screen fits the smallest window (960x640, '
        '${dark ? 'dark' : 'light'})', (tester) async {
      // The macOS/Windows minimum; screens scroll, never overflow.
      tester.platformDispatcher.platformBrightnessTestValue = dark
          ? Brightness.dark
          : Brightness.light;
      final h = _Harness()
        ..rpc.info = Right(RpcModels.blockchainInfo(signetAfterSnapshot))
        ..rpc.peers = const [
          Peer(
            id: 1,
            address: '1.2.3.4:38333',
            userAgent: '/Satoshi:30.0.0/',
            inbound: false,
            kind: 'regular',
            state: 'Ready',
            transport: 'V2',
            initialHeight: 327900,
            services: ['NETWORK', 'WITNESS'],
          ),
        ];
      await h.pump(tester, network: 'signet', size: const Size(960, 640));
      for (final item in [
        'Overview',
        'Sync',
        'Peers',
        'Wallet',
        'RPC Console',
        'Electrum',
        'Logs',
        'Installation',
        'Settings',
        'Help',
      ]) {
        // Every destination is reachable without scrolling the sidebar.
        expect(
          find.text(item).first.hitTestable(),
          findsOneWidget,
          reason: '$item visible at 640 px',
        );
        await tester.tap(find.text(item).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$item dark=$dark');
      }
      tester.platformDispatcher.clearPlatformBrightnessTestValue();
    });
  }

  testWidgets('a damaged wallet store is explained and repaired on request', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester);
    // The exact exit of florestad v0.9.1 seen on 2026-10-26.
    h.manager.emit(
      const ProcessCrashed(1, [
        'Failed to start florestad: Cannot open a key-value database: '
            'KvError: Error in Sled: Read corrupted data at file offset '
            'Some(Inline(413)) backtrace ()',
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text("Floresta's wallet store cannot be read"), findsOneWidget);
    expect(find.text('The node exited unexpectedly'), findsNothing);

    // Nothing moves without confirmation.
    await tester.tap(find.text('Move aside and start'));
    await tester.pumpAndSettle();
    expect(find.text('Move the wallet store aside?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.manager.starts, isEmpty);
  });

  testWidgets('Help lists the app, florestad and font licences', (
    tester,
  ) async {
    registerLicenses();
    final h = _Harness();
    await h.pump(tester);
    await tester.tap(find.text('Help').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Licences'));
    await tester.pumpAndSettle();
    for (final name in [
      'Floresta GUI',
      'florestad (Floresta)',
      'Space Grotesk',
    ]) {
      expect(find.text(name), findsWidgets, reason: name);
    }
  });

  for (final dark in [false, true]) {
    testWidgets('every screen has labelled tap targets and readable text '
        '(${dark ? 'dark' : 'light'})', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.platformDispatcher.platformBrightnessTestValue = dark
          ? Brightness.dark
          : Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final h = _Harness()
        ..rpc.info = Right(RpcModels.blockchainInfo(signetAfterSnapshot));
      await h.pump(tester, network: 'signet');
      for (final item in [
        'Overview',
        'Sync',
        'Peers',
        'Wallet',
        'RPC Console',
        'Electrum',
        'Logs',
        'Installation',
        'Settings',
        'Help',
      ]) {
        await tester.tap(find.text(item).first);
        await tester.pumpAndSettle();
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
      }
      semantics.dispose();
    });
  }

  testWidgets('node status reflects an unreachable API while starting', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(FlorestaApp)),
    );
    expect(
      container.read(nodeControllerProvider).api,
      ApiReachability.unreachable,
    );
  });
}

class _FakeConsole implements ConsoleRepository {
  _FakeConsole(this.answer);
  final Object? Function(String, List<Object?>) answer;

  @override
  String get endpoint => 'test';

  @override
  Future<Either<Failure, Object?>> call(
    String method,
    List<Object?> params,
  ) async => Right(answer(method, params));
}
