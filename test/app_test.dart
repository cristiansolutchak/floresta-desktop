import 'package:floresta_gui/app/app.dart';
import 'package:floresta_gui/core/build_flavor.dart';
import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/core/platform/host_platform.dart';
import 'package:floresta_gui/core/providers.dart';
import 'package:floresta_gui/features/installation/domain/floresta_version.dart';
import 'package:floresta_gui/features/installation/domain/installation.dart';
import 'package:floresta_gui/features/installation/presentation/installation_providers.dart';
import 'package:floresta_gui/features/node/data/rpc_models.dart';
import 'package:floresta_gui/features/node/presentation/node_controller.dart';
import 'package:floresta_gui/features/node/domain/node_process_state.dart';
import 'package:floresta_gui/features/node/domain/node_status.dart';
import 'package:floresta_gui/features/node/domain/preflight.dart';
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

  testWidgets('onboarding finishes on the node page', (tester) async {
    final h = _Harness();
    await h.pump(tester, onboarded: false);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Set up your node'), findsOneWidget);
    await tester.tap(find.text('Finish setup'));
    await tester.pumpAndSettle();
    expect(find.text('Start node'), findsOneWidget);
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
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Test networks (advanced)'), findsOneWidget);
    expect(find.text('Signet'), findsNothing);
    await tester.tap(find.text('Test networks (advanced)'));
    await tester.pumpAndSettle();
    expect(find.text('Signet'), findsOneWidget);
    expect(find.text('Regtest'), findsOneWidget);
  });

  testWidgets('development builds default to signet with the section open', (
    tester,
  ) async {
    final h = _Harness()..flavor = BuildFlavor.development;
    await h.pump(tester, onboarded: false);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Signet'), findsWidgets);
    expect(
      find.text('Development build'),
      findsNothing,
    ); // onboarding has no sidebar
    final radio = tester.widget<RadioGroup<BitcoinNetwork>>(
      find.byType(RadioGroup<BitcoinNetwork>),
    );
    expect(radio.groupValue, BitcoinNetwork.signet);
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
