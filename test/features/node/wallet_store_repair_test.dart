import 'dart:io';

import 'package:floresta_desktop/features/node/data/wallet_store_repair.dart';
import 'package:floresta_desktop/features/node/domain/node_process_state.dart';
import 'package:floresta_desktop/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_desktop/features/settings/domain/node_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('florestad\'s "cannot open the store" exit is recognised', () {
    // The exact line from a real v0.9.1 run (2026-10-26).
    const crashed = ProcessCrashed(1, [
      'Failed to start florestad: Cannot open a key-value database: KvError: '
          'Error in Sled: Read corrupted data at file offset '
          'Some(Inline(413)) backtrace ()',
    ]);
    expect(crashed.looksLikeDamagedWalletStore, isTrue);
    expect(
      const ProcessCrashed(1, ['Failed to bind']).looksLikeDamagedWalletStore,
      isFalse,
    );
  });

  group('WalletStoreRepair', () {
    late Directory home;
    setUp(() => home = Directory.systemTemp.createTempSync('store_repair_'));
    tearDown(() => home.deleteSync(recursive: true));

    // Mainnet's data folder is ~/.floresta itself, shared with the other
    // networks' subfolders: exactly the layout of the failure.
    Directory mainnet() {
      final d = Directory('${home.path}/.floresta')..createSync();
      File('${d.path}/conf').writeAsStringSync('segment_size: 524288');
      File('${d.path}/db').writeAsStringSync('');
      File('${d.path}/snap.00000000000001D6').writeAsStringSync('stale');
      Directory('${d.path}/blobs').createSync();
      Directory('${d.path}/chaindata').createSync();
      File('${d.path}/chaindata/headers').writeAsStringSync('chain');
      File('${d.path}/debug.log').writeAsStringSync('log');
      Directory('${d.path}/signet').createSync();
      File('${d.path}/signet/db').writeAsStringSync('signet wallet');
      return d;
    }

    test('moves only the store files, keeps everything else', () async {
      final d = mainnet();
      final repair = WalletStoreRepair(homeDir: home.path);
      const settings = NodeSettings(network: BitcoinNetwork.bitcoin);
      expect(repair.dbBytes(settings), 0);

      final moved = (await repair.moveAside(
        settings,
        now: DateTime(2026, 10, 26, 18, 40),
      )).getOrElse((f) => throw StateError('$f'));

      expect(moved.names, ['blobs', 'conf', 'db', 'snap.00000000000001D6']);
      expect(moved.dbBytes, 0);
      expect(moved.folder, endsWith('damaged-wallet-store-20261026-184000'));
      for (final n in moved.names) {
        expect(
          FileSystemEntity.typeSync('${d.path}/$n'),
          FileSystemEntityType.notFound,
        );
        expect(
          FileSystemEntity.typeSync('${moved.folder}/$n'),
          isNot(FileSystemEntityType.notFound),
        );
      }
      // Untouched: chain data, the log, other networks.
      expect(File('${d.path}/chaindata/headers').readAsStringSync(), 'chain');
      expect(File('${d.path}/debug.log').existsSync(), isTrue);
      expect(File('${d.path}/signet/db').readAsStringSync(), 'signet wallet');
    });

    test('with no store files it changes nothing', () async {
      Directory('${home.path}/.floresta').createSync();
      final repair = WalletStoreRepair(homeDir: home.path);
      final r = await repair.moveAside(const NodeSettings());
      expect(r.isLeft(), isTrue);
      expect(Directory('${home.path}/.floresta').listSync(), isEmpty);
    });
  });
}
