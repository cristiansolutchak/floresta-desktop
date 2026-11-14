/// Crash recovery and Add Peer against REAL nodes on a regtest cluster
/// (bitcoind → utreexod → florestad), through the app's own code: the process
/// manager, the RPC repository and the Add Peer call.
///
///   - florestad killed with SIGKILL is reported as a crash (not a stop),
///     starts again and resumes from its data (same chain, no resync);
///   - Add Peer's call (`addnode <ip:port> add`) makes florestad connect to
///     bitcoind, which then shows in `getpeerinfo`.
///
/// Opt-in like the other cluster tests (env from
/// `tool/regtest/bootstrap.sh --print-env`).
@Tags(['integration'])
@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:floresta_desktop/features/node/domain/node_process_state.dart';
import 'package:floresta_desktop/features/node/domain/node_rpc_repository.dart';
import 'package:floresta_desktop/features/node/domain/peer_address.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/regtest_cluster.dart';

void main() {
  late RegtestCluster cluster;

  // The tests are skipped without the tools; so is the cluster.
  setUpAll(() async {
    if (RegtestCluster.missingTools != null) return;
    cluster = await RegtestCluster.start();
  });
  tearDownAll(() async {
    if (RegtestCluster.missingTools != null) return;
    await cluster.dispose();
  });

  Future<void> waitFor(
    String what,
    Future<bool> Function() done, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final end = DateTime.now().add(timeout);
    while (!await done()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  test(
    'a killed node is reported as a crash, then resumes from its data',
    () async {
      final before = (await cluster.floRpcRepo.getBlockchainInfo()).getOrElse(
        (f) => fail('$f'),
      );
      final pid = switch (cluster.florestad.state) {
        ProcessRunning(:final pid) => pid,
        final s => fail('not running: $s'),
      };

      expect(Process.killPid(pid, ProcessSignal.sigkill), isTrue);
      await waitFor('the crash', () async {
        return cluster.florestad.state is ProcessCrashed;
      });
      final crashed = cluster.florestad.state as ProcessCrashed;
      expect(crashed.exitCode, isNot(0));
      expect(crashed.looksLikeDamagedWalletStore, isFalse);

      await cluster.startFlorestad(); // waits until synced to bitcoind
      final after = (await cluster.floRpcRepo.getBlockchainInfo()).getOrElse(
        (f) => fail('$f'),
      );
      expect(after.network, before.network);
      expect(
        after.validatedHeight,
        greaterThanOrEqualTo(before.validatedHeight),
      );
      expect(after.bestBlockHash, before.bestBlockHash);
    },
    skip: RegtestCluster.missingTools,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    "Add Peer's call connects florestad to a real node",
    () async {
      final address = validatePeerAddress(
        '127.0.0.1:${cluster.coreP2p}',
      ).getOrElse((e) => fail(e));
      final added = await cluster.floRpcRepo.addNode(
        address,
        command: AddNodeCommand.add,
      );
      expect(added.isRight(), isTrue, reason: '$added');
      await waitFor('bitcoind in getpeerinfo', () async {
        final peers = (await cluster.floRpcRepo.getPeers()).toNullable();
        return peers?.any((p) => p.address == address) ?? false;
      });
    },
    skip: RegtestCluster.missingTools,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
