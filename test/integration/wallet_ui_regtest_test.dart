/// WAL-03 on a real regtest cluster, through the Wallet screen only.
///
/// bitcoind mines and signs test transactions for a disposable "subject"
/// wallet; utreexod serves proofs; florestad runs with its Electrum server
/// on regtest's default port 20001, where the app looks for it. The app
/// imports the subject wallet's public descriptor through the Add dialog,
/// and every balance, address and activity row it shows is compared with
/// Bitcoin Core. Opt-in like the other cluster tests (env from
/// `tool/regtest/bootstrap.sh --print-env`); port 20001 must be free.
library;

import 'dart:io';

import 'package:floresta_gui/app/app.dart';
import 'package:floresta_gui/core/providers.dart';
import 'package:floresta_gui/features/wallet/presentation/amount_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/regtest_cluster.dart';

int _sats(Object? btc) => ((btc! as num) * 1e8).round();

void main() {
  testWidgets(
    'the Wallet screen shows what Bitcoin Core shows for the same keys',
    (tester) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = null; // real HTTP to florestad's RPC
      addTearDown(() => HttpOverrides.global = previous);

      late RegtestCluster cluster;
      late Directory appData;
      await tester.runAsync(() async {
        cluster = await RegtestCluster.start(electrumPort: 20001);
        appData = await Directory.systemTemp.createTemp('wallet_ui_');
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await cluster.dispose();
          await appData.delete(recursive: true);
        });
      });

      Future<Object?> core(String method, [List<Object?> params = const []]) =>
          cluster.core.call(method, params, 'subject');
      Future<T> real<T>(Future<T> Function() f) async =>
          (await tester.runAsync(f)) as T;

      tester.view.physicalSize = const Size(1400, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        'settings.onboardingComplete': true,
        'settings.network': 'regtest',
        'settings.rpcPort': cluster.floRpc,
      });
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            environmentProvider.overrideWithValue({
              'HOME': appData.path,
              'PATH': '/usr/bin:/bin',
              'FLORESTA_GUI_DATA_ROOT': '${appData.path}/app',
            }),
          ],
          child: const FlorestaApp(),
        ),
      );

      // Real I/O happens outside the fake clock; timers inside the app
      // (polling, debounce) need the fake clock to move too.
      Future<void> waitFor(Finder f, {int seconds = 60}) async {
        final deadline = DateTime.now().add(Duration(seconds: seconds));
        while (f.evaluate().isEmpty) {
          if (DateTime.now().isAfter(deadline)) {
            final texts = [
              for (final e in find.byType(Text).evaluate())
                (e.widget as Text).data ?? '',
            ].where((t) => t.isNotEmpty).join(' | ');
            File(
              '${Directory.systemTemp.path}/wallet-ui-screen.txt',
            ).writeAsStringSync(texts);
            fail('timed out: $f');
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await waitFor(find.text('Wallet'));
      await tester.tap(find.text('Wallet'));
      await waitFor(find.text('Add descriptor'));

      // Core's public receive descriptor; the app derives the change one.
      final descs =
          ((await real(() => core('listdescriptors'))) as Map)['descriptors']
              as List;
      String desc(bool internal) =>
          (descs.firstWhere(
                    (d) =>
                        (d as Map)['desc'].toString().startsWith('wpkh(') &&
                        d['internal'] == internal,
                  )
                  as Map)['desc']
              as String;
      await tester.tap(find.text('Add descriptor'));
      await waitFor(find.byType(TextField));
      await tester.enterText(find.byType(TextField), desc(false));
      await tester.runAsync(() async => tester.tap(find.text('Add')));
      await waitFor(find.textContaining('1 wallet · 2 descriptors'));

      // Fund the subject wallet: two payments, one block.
      await real(() async {
        final a1 = await core('getnewaddress', ['', 'bech32']);
        final a2 = await core('getnewaddress', ['', 'bech32']);
        await cluster.core.call('sendtoaddress', [a1, 1.0], 'miner');
        await cluster.core.call('sendtoaddress', [a2, 0.3], 'miner');
        await cluster.mine(1);
      });
      await waitFor(find.text(formatBtc(130000000)), seconds: 90);

      // Balance equals Core's trusted balance.
      final balances =
          ((await real(() => core('getbalances'))) as Map)['mine'] as Map;
      expect(find.text(formatBtc(_sats(balances['trusted']))), findsOneWidget);

      // Receive #0 is Core's first receive address for the same descriptor.
      final first =
          ((await real(
                    () => cluster.core.call('deriveaddresses', [
                      desc(false),
                      [0, 0],
                    ]),
                  ))
                  as List)
              .single;
      expect(find.text('Receive #0'), findsOneWidget);
      expect(find.text(first as String), findsOneWidget);

      // A spend with change, signed by Core's test wallet.
      await real(() async {
        final minerAddr = await cluster.core.call('getnewaddress', [], 'miner');
        await core('sendtoaddress', [minerAddr, 0.4]);
        await cluster.mine(1);
      });
      final after =
          ((await real(() => core('getbalances'))) as Map)['mine'] as Map;
      await waitFor(find.text(formatBtc(_sats(after['trusted']))), seconds: 90);
      final coreTxs = <Object?>{
        for (final t
            in (await real(() => core('listtransactions', ['*', 100]))) as List)
          if ((t as Map)['category'] != 'orphan') t['txid'],
      };
      await tester.ensureVisible(find.text('Activity'));
      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('Received'), findsNWidgets(2));
      expect(coreTxs, hasLength(3));
      // ignore: avoid_print
      print(
        'wallet UI matches Core: trusted=${after['trusted']} '
        'txs=${coreTxs.length} receive#0=$first',
      );
    },
    skip: RegtestCluster.missingTools != null,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
