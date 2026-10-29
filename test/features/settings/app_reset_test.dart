@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/core/platform/app_paths.dart';
import 'package:floresta_gui/features/settings/data/app_reset_service.dart';
import 'package:floresta_gui/features/settings/domain/app_reset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('app_reset domain (INS-12)', () {
    test('only a folder with florestad chain state counts as Floresta', () {
      expect(looksLikeFlorestaData({'chaindata', 'db'}), isTrue);
      expect(looksLikeFlorestaData({'db', 'debug.log'}), isFalse);
      expect(
        looksLikeFlorestaData({'chaindata', 'chainstate', 'blocks'}),
        isFalse,
        reason: 'Bitcoin Core data',
      );
      expect(looksLikeFlorestaData({'chaindata', 'bitcoin.conf'}), isFalse);
    });

    test('deletes only known florestad entries that exist', () {
      expect(chainDataToDelete({'chaindata', 'signet', 'notes.txt', 'db'}), [
        'chaindata',
        'db',
      ]);
    });

    test('deletes the wallet database\'s Sled snapshots with it', () {
      // A snapshot left behind next to a fresh, empty db makes florestad
      // refuse to open its wallet store (mainnet, 2026-10-28).
      expect(
        chainDataToDelete({
          'chaindata',
          'db',
          'conf',
          'snap.00000000000001D6',
          'snap.0000000000000A10',
          'snapshot-notes.txt',
          'snap.',
          'snap.xyz',
        }),
        [
          'chaindata',
          'db',
          'conf',
          'snap.00000000000001D6',
          'snap.0000000000000A10',
        ],
      );
      expect(isSledSnapshot('snap.00000000000001d6'), isTrue);
      expect(isSledSnapshot('snap.00000000000001D6.bak'), isFalse);
    });
  });

  group('AppResetService (real files)', () {
    late Directory temp;
    late AppPaths paths;
    late SharedPreferences prefs;
    late AppResetService service;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('reset_');
      paths = AppPaths(Directory('${temp.path}/app'));
      SharedPreferences.setMockInitialValues({
        'settings.onboardingComplete': true,
        'settings.network': 'signet',
        'wallet.rescanOwedFrom': 10,
        'ui.sidebarCompact': true,
        'other.app.key': 'kept',
      });
      prefs = await SharedPreferences.getInstance();
      service = AppResetService(prefs: prefs, paths: paths);
    });
    tearDown(() => temp.deleteSync(recursive: true));

    test('resetting settings clears only this app\'s keys', () async {
      expect((await service.resetSettings()).isRight(), isTrue);
      expect(prefs.getKeys(), {'other.app.key'});
    });

    test('removing Floresta keeps the anti-rollback record', () async {
      paths.versionDir('0.9.1').createSync(recursive: true);
      File(
        '${paths.versionDir('0.9.1').path}/florestad',
      ).writeAsStringSync('x');
      paths.staging.createSync(recursive: true);
      paths.currentPointer.writeAsStringSync('{}');
      paths.trustRecord.writeAsStringSync('{"highestSerial":3}');

      expect(service.managedFloresta, hasLength(3));
      expect((await service.removeManagedFloresta()).isRight(), isTrue);
      expect(paths.versions.existsSync(), isFalse);
      expect(paths.staging.existsSync(), isFalse);
      expect(paths.currentPointer.existsSync(), isFalse);
      expect(paths.trustRecord.readAsStringSync(), contains('3'));
      expect(service.managedFloresta, isEmpty);
    });

    test(
      'deleting node data removes florestad entries and nothing else',
      () async {
        // Mainnet layout: the base folder is the network folder, and other
        // networks live in subfolders of it.
        final base = Directory('${temp.path}/.floresta')..createSync();
        for (final d in ['chaindata', 'blobs', 'db', 'cfilters']) {
          Directory('${base.path}/$d/inner').createSync(recursive: true);
        }
        File('${base.path}/debug.log').writeAsStringSync('log');
        File('${base.path}/peers.json').writeAsStringSync('[]');
        File('${base.path}/snap.00000000000001D6').writeAsStringSync('sled');
        Directory('${base.path}/signet/chaindata').createSync(recursive: true);
        File('${base.path}/my-notes.txt').writeAsStringSync('mine');
        // A link inside must be removed as a link, never followed.
        final outside = Directory('${temp.path}/outside')..createSync();
        File('${outside.path}/precious').writeAsStringSync('keep');
        Link('${base.path}/conf').createSync(outside.path);

        final plan = service
            .chainDataIn(base.path)
            .getOrElse((f) => fail('$f'));
        expect(plan, [
          'chaindata',
          'blobs',
          'db',
          'cfilters',
          'conf',
          'peers.json',
          'debug.log',
          'snap.00000000000001D6',
        ]);
        final deleted = await service.deleteChainData(base.path);
        expect(deleted.getOrElse((f) => fail('$f')), plan);

        final left = base.listSync().map((e) => e.uri.pathSegments).toList();
        expect(
          base.listSync().map((e) => e.path.split('/').last).toSet(),
          {'signet', 'my-notes.txt'},
          reason: '$left',
        );
        expect(
          Directory('${base.path}/signet/chaindata').existsSync(),
          isTrue,
          reason: 'other networks are untouched',
        );
        expect(File('${outside.path}/precious').existsSync(), isTrue);
      },
    );

    test('refuses folders that are not Floresta\'s', () async {
      final core = Directory('${temp.path}/bitcoin')..createSync();
      Directory('${core.path}/chainstate').createSync();
      Directory('${core.path}/chaindata').createSync();
      final r = await service.deleteChainData(core.path);
      expect(r.getLeft().toNullable(), isA<ResetFailure>());
      expect(Directory('${core.path}/chainstate').existsSync(), isTrue);

      final empty = Directory('${temp.path}/empty')..createSync();
      expect(service.chainDataIn(empty.path).isLeft(), isTrue);
      expect(service.chainDataIn('${temp.path}/missing').isLeft(), isTrue);
    });
  });
}
