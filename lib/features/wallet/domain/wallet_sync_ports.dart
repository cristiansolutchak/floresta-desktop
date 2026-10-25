import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../settings/domain/bitcoin_network.dart';
import 'wallet_account.dart';

/// Parses user input into an account's external and internal descriptors.
abstract interface class DescriptorParser {
  /// Accepts a multipath `/<0;1>/*` descriptor, or a `/0/*` descriptor whose
  /// internal branch is the same key at `/1/*` (BIP-44 family convention).
  Either<Failure, ({WalletDescriptor external, WalletDescriptor internal})>
  parseAccount(String input, BitcoinNetwork network);
}

abstract interface class AddressDeriver {
  DerivedScript derive(WalletDescriptor descriptor, int index);
}

/// The node's view of the chain, used to verify server claims.
abstract interface class ChainView {
  Future<Either<Failure, ({int validatedHeight, bool ibd})>> status();
  Future<Either<Failure, String>> blockHash(int height);
}

/// Persisted per-account sync state. Contains only public data.
class StoredTx extends Equatable {
  const StoredTx({
    required this.rawHex,
    required this.height,
    this.verifiedBlockHash,
  });

  final String rawHex;

  /// Height last reported by the server (<= 0 = unconfirmed).
  final int height;

  /// Block hash the merkle proof was verified against, if verified.
  final String? verifiedBlockHash;

  StoredTx copyWith({
    int? height,
    String? verifiedBlockHash,
    bool clear = false,
  }) => StoredTx(
    rawHex: rawHex,
    height: height ?? this.height,
    verifiedBlockHash: clear
        ? null
        : verifiedBlockHash ?? this.verifiedBlockHash,
  );

  @override
  List<Object?> get props => [rawHex, height, verifiedBlockHash];
}

class WalletSyncData extends Equatable {
  const WalletSyncData({
    this.statuses = const {},
    this.histories = const {},
    this.transactions = const {},
    this.tip,
  });

  /// Electrum status per scripthash at the last successful sync.
  final Map<String, String?> statuses;

  /// txids per scripthash at the last successful sync.
  final Map<String, List<String>> histories;
  final Map<String, StoredTx> transactions;

  /// Verified (height, blockHash) of the tip at the last successful sync.
  final ({int height, String hash})? tip;

  @override
  List<Object?> get props => [statuses, histories, transactions, tip];
}

abstract interface class WalletStore {
  Future<Either<Failure, WalletSyncData>> load(String accountId);
  Future<Either<Failure, Unit>> save(String accountId, WalletSyncData data);
}
