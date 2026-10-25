import 'package:equatable/equatable.dart';

import 'wallet_account.dart';
import 'wallet_state.dart';

/// What happened at one derived address, from the wallet's verified records.
class AddressActivity extends Equatable {
  const AddressActivity({
    required this.keychain,
    required this.index,
    required this.scriptPubKey,
    required this.receivedSats,
    required this.balanceSats,
    required this.txCount,
    required this.lastHeight,
  });

  final Keychain keychain;
  final int index;
  final String scriptPubKey;

  /// Everything ever paid to this address by usable transactions.
  final int receivedSats;

  /// Outputs at this address not spent by any known transaction, including
  /// ones still pending verification.
  final int balanceSats;

  /// Transactions that pay to or spend from this address.
  final int txCount;

  /// Height of the newest confirmed or pending transaction; 0 when the
  /// newest one is unconfirmed; null when the address was never used.
  final int? lastHeight;

  bool get used => txCount > 0;

  @override
  List<Object?> get props => [
    keychain,
    index,
    scriptPubKey,
    receivedSats,
    balanceSats,
    txCount,
    lastHeight,
  ];

  /// Pure: one entry per script in [scripts], in the same order.
  /// [Unverified] records are ignored, exactly as in balances.
  static List<AddressActivity> compute({
    required Iterable<WalletTxRecord> records,
    required List<DerivedScript> scripts,
  }) {
    final usable = [
      for (final r in records)
        if (r.confirmation is! Unverified) r,
    ];
    final spent = <OutPoint>{for (final r in usable) ...r.tx.inputs};
    final outputsByTx = {for (final r in usable) r.tx.txid: r.tx.outputs};

    final received = <String, int>{};
    final balance = <String, int>{};
    final txs = <String, Set<String>>{};
    final last = <String, int>{};
    void touch(String spk, WalletTxRecord r) {
      txs.putIfAbsent(spk, () => {}).add(r.tx.txid);
      final h = switch (r.confirmation) {
        Confirmed(:final height) || PendingValidation(:final height) => height,
        _ => 0,
      };
      final prev = last[spk];
      // Unconfirmed (0) counts as the newest.
      if (prev == null || prev != 0 && (h == 0 || h > prev)) last[spk] = h;
    }

    for (final r in usable) {
      for (final o in r.tx.outputs) {
        received[o.scriptPubKey] =
            (received[o.scriptPubKey] ?? 0) + o.valueSats;
        if (!spent.contains(OutPoint(r.tx.txid, o.vout))) {
          balance[o.scriptPubKey] =
              (balance[o.scriptPubKey] ?? 0) + o.valueSats;
        }
        touch(o.scriptPubKey, r);
      }
      for (final input in r.tx.inputs) {
        final prevOuts = outputsByTx[input.txid];
        if (prevOuts == null) continue;
        for (final o in prevOuts) {
          if (o.vout == input.vout) touch(o.scriptPubKey, r);
        }
      }
    }

    return [
      for (final s in scripts)
        AddressActivity(
          keychain: s.keychain,
          index: s.index,
          scriptPubKey: s.scriptPubKey,
          receivedSats: received[s.scriptPubKey] ?? 0,
          balanceSats: balance[s.scriptPubKey] ?? 0,
          txCount: txs[s.scriptPubKey]?.length ?? 0,
          lastHeight: last[s.scriptPubKey],
        ),
    ];
  }
}
