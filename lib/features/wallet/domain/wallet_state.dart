import 'package:equatable/equatable.dart';

import '../../../core/errors/failure.dart';
import 'address_activity.dart';

class OutPoint extends Equatable {
  const OutPoint(this.txid, this.vout);
  final String txid;
  final int vout;
  @override
  List<Object?> get props => [txid, vout];
  @override
  String toString() => '$txid:$vout';
}

class TxOutput extends Equatable {
  const TxOutput(this.vout, this.valueSats, this.scriptPubKey);
  final int vout;

  /// Satoshis as an integer; amounts are never represented as doubles.
  final int valueSats;
  final String scriptPubKey;
  @override
  List<Object?> get props => [vout, valueSats, scriptPubKey];
}

/// A transaction parsed from raw bytes whose txid was recomputed locally.
class ParsedTransaction extends Equatable {
  const ParsedTransaction({
    required this.txid,
    required this.inputs,
    required this.outputs,
    required this.isCoinbase,
  });
  final String txid;
  final List<OutPoint> inputs;
  final List<TxOutput> outputs;
  final bool isCoinbase;
  @override
  List<Object?> get props => [txid];
}

/// How much the app trusts that a transaction is in the active chain.
sealed class TxConfirmation extends Equatable {
  const TxConfirmation();
  @override
  List<Object?> get props => [];
}

/// Merkle path verified against the header at [height], whose hash matches
/// the node's block hash at that height.
final class Confirmed extends TxConfirmation {
  const Confirmed(this.height, this.blockHash);
  final int height;
  final String blockHash;
  @override
  List<Object?> get props => [height, blockHash];
}

/// Reported in a block above the node's validated height.
final class PendingValidation extends TxConfirmation {
  const PendingValidation(this.height);
  final int height;
  @override
  List<Object?> get props => [height];
}

/// Reported as unconfirmed (mempool) by the server.
final class Unconfirmed extends TxConfirmation {
  const Unconfirmed();
}

/// The server's claim could not be verified against the chain, e.g. a
/// transaction orphaned by a reorg that florestad v0.9.1 still reports.
/// Excluded from balances.
final class Unverified extends TxConfirmation {
  const Unverified(this.reason);
  final String reason;
  @override
  List<Object?> get props => [reason];
}

class WalletTxRecord extends Equatable {
  const WalletTxRecord(this.tx, this.confirmation);
  final ParsedTransaction tx;
  final TxConfirmation confirmation;
  @override
  List<Object?> get props => [tx, confirmation];
}

class WalletBalance extends Equatable {
  const WalletBalance({
    required this.confirmed,
    required this.immature,
    required this.pending,
    required this.spendable,
  });

  /// Unspent outputs in verified blocks (includes immature coinbase).
  final int confirmed;

  /// Coinbase outputs with fewer than 100 confirmations.
  final int immature;

  /// Net change from transactions not yet verified as confirmed
  /// (pending validation or unconfirmed). May be negative.
  final int pending;

  /// Confirmed, mature, and not spent by any known transaction. Spending
  /// still requires an external signer (watch-only, ADR-0006).
  final int spendable;

  int get total => confirmed + pending;

  @override
  List<Object?> get props => [confirmed, immature, pending, spendable];
}

class WalletTransactionView extends Equatable {
  const WalletTransactionView({
    required this.txid,
    required this.netSats,
    required this.confirmation,
  });
  final String txid;

  /// Received minus sent for this wallet's scripts.
  final int netSats;
  final TxConfirmation confirmation;
  @override
  List<Object?> get props => [txid, netSats, confirmation];
}

sealed class WalletSyncState extends Equatable {
  const WalletSyncState();
  @override
  List<Object?> get props => [];
}

final class SyncNotStarted extends WalletSyncState {
  const SyncNotStarted();
}

final class SyncInProgress extends WalletSyncState {
  const SyncInProgress();
}

final class SyncUpToDate extends WalletSyncState {
  const SyncUpToDate(this.validatedHeight, this.at);
  final int validatedHeight;
  final DateTime at;
  @override
  List<Object?> get props => [validatedHeight, at];
}

/// Data shown is from [lastSuccess] and may be outdated.
final class SyncStale extends WalletSyncState {
  const SyncStale(this.failure, this.lastSuccess);
  final Failure failure;
  final DateTime? lastSuccess;
  @override
  List<Object?> get props => [failure, lastSuccess];
}

/// Syncing refused (e.g. wrong chain); nothing is updated.
final class SyncBlocked extends WalletSyncState {
  const SyncBlocked(this.failure);
  final Failure failure;
  @override
  List<Object?> get props => [failure];
}

class WalletSnapshot extends Equatable {
  const WalletSnapshot({
    required this.accountId,
    required this.balance,
    required this.transactions,
    required this.sync,
    required this.coverageLimit,
    this.addresses = const [],
  });

  final String accountId;

  /// Null until a first successful sync (never shown as zero).
  final WalletBalance? balance;
  final List<WalletTransactionView> transactions;
  final WalletSyncState sync;

  /// Addresses per keychain the node watches (100 on florestad v0.9.1).
  final int coverageLimit;

  /// Every watched address, receive branch first, with its activity.
  final List<AddressActivity> addresses;

  @override
  List<Object?> get props => [
    accountId,
    balance,
    transactions,
    sync,
    addresses,
  ];
}
