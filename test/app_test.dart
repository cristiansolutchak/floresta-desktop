import 'package:floresta_gui/app/app.dart';
import 'package:floresta_gui/core/build_flavor.dart';
import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/core/platform/host_platform.dart';
import 'package:floresta_gui/core/providers.dart';
import 'package:floresta_gui/features/installation/domain/floresta_version.dart';
import 'package:floresta_gui/features/installation/domain/installation.dart';
import 'package:floresta_gui/features/installation/presentation/installation_providers.dart';
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
import 'package:floresta_gui/features/onboarding/presentation/wizard_widgets.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/features/wallet/presentation/wallet_controller.dart';
import 'package:floresta_gui/shared/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'features/node/node_rpc_test.dart'
    show blockchainInfoJson, signetAfterSnapshot;
import 'helpers/fake_process.dart';
import 'helpers/fakes.dart';

const _found = FlorestaInstallation(
  executablePath: '/Users/a/.cargo/bin/florestad',
  source: ExecutableSource.wellKnown,
  version: FlorestaVersion(0, 9, 1),
);

class _Harness {
  final install = FakeInstallationRepository(const Right(_found));
  final rpc = FakeNodeRpcRepository();
  final manager = FakeProcessManager();
  final wallet = FakeWalletRepository();
  final preflight = FakePreflightProbe();
  final electrum = FakeElectrumProbe();

  BuildFlavor flavor = BuildFlavor.production;
  PeerProbe probeResult = const PeerProbe.failed('test');

  Future<void> pump(
    WidgetTester tester, {
    bool onboarded = true,
    String? network,
  }) async {
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'settings.onboardingComplete': onboarded,
      'settings.network': ?network,
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
          electrumProbeProvider.overrideWithValue(electrum),
          buildFlavorProvider.overrideWithValue(flavor),
          // No DNS or P2P from widget tests.
          utreexoPeerFinderProvider.overrideWithValue(
            UtreexoPeerFinder(
              rpc: rpc,
              resolve: (_) async => const [],
              probe: (_, _, _) async => probeResult,
            ),
          ),
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
    expect(find.text('Find Floresta'), findsOneWidget);
    expect(find.text('Next: set up your node'), findsOneWidget);
    expect(find.text('Found florestad v0.9.1'), findsOneWidget);
  });

  Future<void> toWizard(WidgetTester tester) async {
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
  }

  Future<void> tapNext(WidgetTester tester, [String label = 'Next']) async {
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
    await tapNext(tester);
    expect(find.text('Storage'), findsWidgets);
    expect(find.text('/Users/a/.floresta'), findsOneWidget);
    expect(find.textContaining('free on this disk'), findsOneWidget);
    await tapNext(tester);
    expect(find.textContaining('Assume Utreexo'), findsOneWidget);
    await tapNext(tester);
    expect(find.textContaining('Electrum server'), findsOneWidget);
    expect(find.text('Always on'), findsOneWidget);
    expect(find.text('Remote RPC'), findsNothing);
    await tapNext(tester, 'Review configuration');
    expect(find.text('Ready to start'), findsOneWidget);
    expect(find.text('Pruned, Assume Utreexo with backfill'), findsOneWidget);

    await tester.tap(find.text('Start Floresta now'));
    await tester.pumpAndSettle();
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
    await tester.tap(find.textContaining('Assume Utreexo'));
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
    expect(find.text('Pruned, Assume Utreexo, no backfill'), findsOneWidget);
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
    final start = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Start node'),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      ),
    );
    expect(start.onPressed, isNull);

    await tester.tap(find.text('Open Installation'));
    await tester.pumpAndSettle();
    expect(find.text('Next: install Floresta'), findsOneWidget);
    expect(find.text('Build from source'), findsOneWidget);
    expect(find.text('Automatic installation'), findsNothing);
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

  testWidgets('start launches the detected executable', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.tap(find.text('Start node'));
    await tester.pumpAndSettle();
    expect(h.manager.starts.single.$1, _found.executablePath);
    expect(find.text('Running'), findsWidgets);
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
    expect(find.text('Validates from the first block'), findsOneWidget);
    expect(find.textContaining('Assume Utreexo'), findsNothing);
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

    expect(find.text('Watch-only'), findsOneWidget);
    for (final forbidden in ['Send', 'Sign', 'Broadcast', 'Receive']) {
      expect(find.text(forbidden), findsNothing);
    }
    // Descriptors are masked until revealed.
    expect(find.textContaining(FakeKeys.xpub), findsNothing);
    expect(find.text('127.0.0.1:50001'), findsOneWidget); // mainnet default
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
      find.byType(TextField),
      'wpkh(${FakeKeys.xprv}/0/*)',
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('Private key material detected'), findsOneWidget);
    expect(h.wallet.loaded, isEmpty);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
  });

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
