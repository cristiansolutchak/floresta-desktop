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

class _Harness {
  final install = FakeInstallationRepository(const Right(_found));
  final rpc = FakeNodeRpcRepository();
  final manager = FakeProcessManager();
  final wallet = FakeWalletRepository();
  final preflight = FakePreflightProbe();
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
  }) async {
    tester.view.physicalSize = size;
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
    final start = tester.widget<TextButton>(
      find.ancestor(
        of: find.text('Start node'),
        matching: find.byType(TextButton),
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
      find.byType(TextField),
      vectorType('wpkh')['multipath']! as String,
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(h.wallet.loaded, [
      vectorType('wpkh')['external'],
      vectorType('wpkh')['internal'],
    ]);
    expect(find.textContaining('1 wallet · 2 descriptors'), findsOneWidget);
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

  testWidgets('during the headers step both cards show headers downloaded', (
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

    await tester.ensureVisible(find.text('View Sync Details'));
    await tester.tap(find.text('View Sync Details'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Step 1/3'), findsOneWidget);
    expect(find.text('Headers Downloaded'), findsOneWidget);
    expect(find.text('24,000'), findsWidgets);
    expect(find.text('Current Height'), findsNothing);
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
