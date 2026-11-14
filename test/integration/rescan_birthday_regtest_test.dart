/// Opt-in: owed rescans and the wallet start height against REAL processes
/// (bitcoind → utreexod → florestad v0.9.1):
///
///   source "$(tool/regtest/bootstrap.sh --print-env)"
///   flutter test test/integration/rescan_birthday_regtest_test.dart
///
/// * Start height (partial): florestad v0.9.1 starts, syncs and serves RPC with
///   `--filters-start-height`. The *effect* of the start height cannot be
///   shown on this cluster: florestad gets no compact filters here (its log
///   says "Loaded compact filters store at height 0" and every filter
///   rescan reports `rescan filter hits: []`, with or without the flag;
///   observed 2026-10-25).
/// * Owed rescans: the app's real `WalletRescanController`, on the real RPC, does
///   not send an owed rescan while the node is not ready, and sends it (and
///   the node accepts it) once ready.
@Tags(['integration'])
@TestOn('mac-os || linux')
library;

import 'package:floresta_gui/core/providers.dart';
import 'package:floresta_gui/core/rpc/json_rpc_client.dart';
import 'package:floresta_gui/features/node/domain/node_readiness.dart';
import 'package:floresta_gui/features/node/presentation/node_controller.dart';
import 'package:floresta_gui/features/wallet/data/wallet_repository_impl.dart';
import 'package:floresta_gui/features/wallet/domain/descriptor_input.dart';
import 'package:floresta_gui/features/wallet/presentation/wallet_controller.dart';
import 'package:floresta_gui/features/wallet/presentation/wallet_rescan_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/regtest_cluster.dart';

final _skip = RegtestCluster.missingTools;
const _filtersStart = 116;

void main() {
  late RegtestCluster cluster;
  late http.Client client;
  late JsonRpcClient floRpc;

  setUpAll(() async {
    if (_skip != null) return;
    // RegtestCluster.start waits until florestad has validated Core's tip:
    // starting with the flag at all is part of what this test checks.
    cluster = await RegtestCluster.start(
      florestadExtraArgs: ['--filters-start-height', '$_filtersStart'],
    );
    client = http.Client();
    floRpc = JsonRpcClient(
      endpoint: cluster.floSettings.rpcEndpoint,
      httpClient: client,
    );
  });

  tearDownAll(() async {
    if (_skip != null) return;
    client.close();
    await cluster.dispose();
  });

  test(
    'owed rescans wait for readiness, then the node accepts them',
    () async {
      // Past the start height, so the node has blocks after it.
      await cluster.mine(_filtersStart - 110 + 3);

      final descs =
          ((await cluster.core.call('listdescriptors', [], 'subject'))
                  as Map)['descriptors']
              as List;
      final external =
          (descs.firstWhere(
                    (d) =>
                        (d as Map)['desc'].toString().startsWith('wpkh(') &&
                        d['internal'] == false,
                  )
                  as Map)['desc']
              as String;
      final repo = WalletRepositoryImpl(floRpc);
      // rescanblockchain needs watched addresses ("NoAddressesToRescan").
      final loaded = await repo.loadDescriptor(
        DescriptorInput.parse(
          external,
        ).getOrElse((f) => throw StateError(f.message)),
      );
      expect(loaded.isRight(), isTrue, reason: '$loaded');

      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var ready = false;
      var now = Duration.zero;
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          walletRepositoryProvider.overrideWithValue(repo),
          rescanClockProvider.overrideWithValue(() => now),
          nodeReadinessProvider.overrideWith(
            (ref) => NodeReadiness(
              ready ? ReadinessStage.ready : ReadinessStage.validatingBlocks,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final rescan = container.read(walletRescanProvider.notifier);
      await rescan.request(from: _filtersStart);
      expect(container.read(walletRescanProvider).owed, isTrue);
      expect(prefs.containsKey('wallet.rescanOwedFrom'), isTrue);

      // Not ready: nothing is sent, however long it waits.
      now += const Duration(minutes: 10);
      await rescan.tick();
      expect(container.read(walletRescanProvider).owed, isTrue);

      // Ready: the grace window starts, then the rescan goes out.
      ready = true;
      container.invalidate(nodeReadinessProvider);
      await rescan.tick();
      expect(container.read(walletRescanProvider).owed, isTrue);
      now += const Duration(seconds: 61);
      await rescan.tick();
      final after = container.read(walletRescanProvider);
      expect(after.owed, isFalse, reason: 'florestad accepted the rescan');
      expect(after.startedAt, isNotNull);
      expect(after.gaveUp, isNull);
      expect(prefs.containsKey('wallet.rescanOwedFrom'), isFalse);
    },
    skip: _skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
