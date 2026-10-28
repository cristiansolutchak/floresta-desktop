import 'dart:io';

import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../settings/domain/app_reset.dart';
import '../../settings/domain/node_settings.dart';

/// What [WalletStoreRepair.moveAside] moved, for the confirmation message.
typedef MovedWalletStore = ({String folder, List<String> names, int dbBytes});

/// Moves florestad's watch-only store aside so it can start again.
///
/// florestad v0.9.1 keeps that store as a Sled database directly in the data
/// folder: `conf`, `db`, `snap.*` and `blobs/`
/// (`floresta-watch-only/src/kv_database.rs`, `KvDatabase::new(datadir)`).
/// When it cannot be opened, florestad refuses to start. This moves exactly
/// those entries into `damaged-wallet-store-<time>/` inside the same folder:
/// nothing is deleted, and the chain data (`chaindata/`, `cfilters*`),
/// other networks' subfolders and the app's own data are not touched.
/// florestad creates a fresh, empty store on the next start; watched
/// descriptors are then imported again.
class WalletStoreRepair {
  WalletStoreRepair({required this.homeDir});

  final String? homeDir;

  static bool isStoreEntry(String name) =>
      name == 'conf' || name == 'db' || name == 'blobs' || isSledSnapshot(name);

  String dataDir(NodeSettings settings) => settings.effectiveDataDir(
    homeDir: homeDir,
    separator: Platform.pathSeparator,
  );

  /// Size of the store's `db` file, or null when there is none.
  int? dbBytes(NodeSettings settings) {
    final f = File('${dataDir(settings)}${Platform.pathSeparator}db');
    return f.existsSync() ? f.lengthSync() : null;
  }

  /// Never call while florestad runs: it holds the store open.
  Future<Either<Failure, MovedWalletStore>> moveAside(
    NodeSettings settings, {
    DateTime? now,
  }) async {
    final sep = Platform.pathSeparator;
    final dir = Directory(dataDir(settings));
    try {
      final entries = dir
          .listSync(followLinks: false)
          .where(
            (e) =>
                isStoreEntry(e.uri.pathSegments.lastWhere((p) => p.isNotEmpty)),
          )
          .toList();
      if (entries.isEmpty) {
        return Left(
          FileWriteFailure(dir.path, 'no wallet store files to move'),
        );
      }
      final t = (now ?? DateTime.now()).toLocal();
      String two(int v) => v.toString().padLeft(2, '0');
      final stamp =
          '${t.year}${two(t.month)}${two(t.day)}-'
          '${two(t.hour)}${two(t.minute)}${two(t.second)}';
      final target = Directory('${dir.path}${sep}damaged-wallet-store-$stamp')
        ..createSync();
      final bytes = dbBytes(settings) ?? 0;
      final names = <String>[];
      for (final e in entries) {
        final name = e.uri.pathSegments.lastWhere((p) => p.isNotEmpty);
        e.renameSync('${target.path}$sep$name');
        names.add(name);
      }
      names.sort();
      return Right((folder: target.path, names: names, dbBytes: bytes));
    } on FileSystemException catch (e) {
      return Left(FileWriteFailure(dir.path, e.osError?.message ?? e.message));
    }
  }
}
