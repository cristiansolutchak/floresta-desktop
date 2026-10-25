/// SYNC-07: does florestad v0.9.1 clear `ibd` once it reaches the tip?
/// Mandacaru needed a fork patch for `ibd: true` forever at the tip (#66).
///
/// Opt-in: source the env printed by `tool/regtest/bootstrap.sh
/// --print-env` (FLORESTAD_PATH, UTREEXOD_PATH, BITCOIND_PATH). Regtest
/// only; bitcoind mines, utreexod serves Utreexo proofs.
library;

import 'package:flutter_test/flutter_test.dart';

import 'support/regtest_cluster.dart';

void main() {
  test(
    'ibd clears at the tip and stays clear as new blocks arrive',
    () async {
      final cluster = await RegtestCluster.start();
      addTearDown(cluster.dispose);
      // start() waited for validated == Core's tip (110) with ibd false.
      Future<(int, int, bool)> info() async {
        final i = (await cluster.floRpcRepo.getBlockchainInfo()).getOrElse(
          (f) => fail(f.message),
        );
        return (i.headerHeight, i.validatedHeight, i.initialBlockDownload);
      }

      final atTip = await info();
      // ignore: avoid_print
      print('after IBD: headers/validated/ibd = $atTip');
      expect(atTip.$3, isFalse);
      expect(atTip.$2, 110);

      for (var round = 1; round <= 3; round++) {
        await cluster.mine(2); // waits for validated == tip and ibd false
        final now = await info();
        // ignore: avoid_print
        print('after mining round $round: $now');
        expect(now.$3, isFalse);
        expect(now.$1, now.$2);
      }
    },
    skip: RegtestCluster.missingTools,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
