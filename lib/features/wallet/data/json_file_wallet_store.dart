import 'dart:convert';
import 'dart:io';

import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../domain/wallet_sync_ports.dart';

/// One JSON file per account, replaced atomically (write a temp file, then
/// rename). Holds only public chain data.
class JsonFileWalletStore implements WalletStore {
  JsonFileWalletStore(this.directory);

  final Directory directory;
  static const schemaVersion = 1;
  static final _safeId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  File _file(String id) => File('${directory.path}/wallet-$id.json');

  @override
  Future<Either<Failure, WalletSyncData>> load(String accountId) async {
    if (!_safeId.hasMatch(accountId)) {
      return const Left(StorageFailure('invalid account id'));
    }
    final file = _file(accountId);
    if (!await file.exists()) return const Right(WalletSyncData());
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      if (json['schemaVersion'] != schemaVersion) {
        return Left(
          StorageFailure('unsupported schema ${json['schemaVersion']}'),
        );
      }
      final tip = json['tip'] as Map<String, Object?>?;
      return Right(
        WalletSyncData(
          statuses: (json['statuses'] as Map<String, Object?>).map(
            (k, v) => MapEntry(k, v as String?),
          ),
          histories: (json['histories'] as Map<String, Object?>).map(
            (k, v) => MapEntry(k, (v as List).cast<String>()),
          ),
          transactions: (json['transactions'] as Map<String, Object?>).map((
            k,
            v,
          ) {
            final t = v as Map<String, Object?>;
            return MapEntry(
              k,
              StoredTx(
                rawHex: t['raw'] as String,
                height: (t['height'] as num).toInt(),
                verifiedBlockHash: t['verifiedBlockHash'] as String?,
              ),
            );
          }),
          tip: tip == null
              ? null
              : (
                  height: (tip['height'] as num).toInt(),
                  hash: tip['hash'] as String,
                ),
        ),
      );
    } on Object catch (e) {
      // A corrupt file must never be silently overwritten with partial data;
      // the caller decides (the engine falls back to a full resync).
      return Left(StorageFailure('corrupt wallet state: $e'));
    }
  }

  @override
  Future<Either<Failure, Unit>> save(String accountId, WalletSyncData d) async {
    if (!_safeId.hasMatch(accountId)) {
      return const Left(StorageFailure('invalid account id'));
    }
    try {
      await directory.create(recursive: true);
      final json = jsonEncode({
        'schemaVersion': schemaVersion,
        'statuses': d.statuses,
        'histories': d.histories,
        'transactions': d.transactions.map(
          (k, t) => MapEntry(k, {
            'raw': t.rawHex,
            'height': t.height,
            'verifiedBlockHash': t.verifiedBlockHash,
          }),
        ),
        'tip': d.tip == null
            ? null
            : {'height': d.tip!.height, 'hash': d.tip!.hash},
      });
      final target = _file(accountId);
      final temp = File('${target.path}.tmp');
      await temp.writeAsString(json, flush: true);
      await temp.rename(target.path);
      return const Right(unit);
    } on FileSystemException catch (e) {
      return Left(StorageFailure(e.message));
    }
  }
}
