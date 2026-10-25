import 'wallet_state.dart';

/// Pure satoshi accounting over a wallet's known transactions.
abstract final class BalanceCalculator {
  static const coinbaseMaturity = 100;

  /// [ownScripts] are this wallet's scriptPubKeys (hex). [tipHeight] is the
  /// highest verified height, used for coinbase maturity.
  static ({WalletBalance balance, List<WalletTransactionView> history})
  compute({
    required Iterable<WalletTxRecord> records,
    required Set<String> ownScripts,
    required int tipHeight,
  }) {
    final usable = [
      for (final r in records)
        if (r.confirmation is! Unverified) r,
    ];
    final byTxid = {for (final r in usable) r.tx.txid: r};

    // Outpoints spent by any usable transaction, and by confirmed ones only.
    final spentByAny = <OutPoint>{};
    final spentByConfirmed = <OutPoint>{};
    for (final r in usable) {
      for (final input in r.tx.inputs) {
        spentByAny.add(input);
        if (r.confirmation is Confirmed) spentByConfirmed.add(input);
      }
    }

    var confirmed = 0;
    var immature = 0;
    var spendable = 0;
    var pendingIn = 0;
    for (final r in usable) {
      for (final out in r.tx.outputs) {
        if (!ownScripts.contains(out.scriptPubKey)) continue;
        final point = OutPoint(r.tx.txid, out.vout);
        switch (r.confirmation) {
          case Confirmed(:final height):
            if (spentByConfirmed.contains(point)) continue;
            confirmed += out.valueSats;
            final depth = tipHeight - height + 1;
            final isImmature = r.tx.isCoinbase && depth < coinbaseMaturity;
            if (isImmature) immature += out.valueSats;
            if (!isImmature && !spentByAny.contains(point)) {
              spendable += out.valueSats;
            }
          case PendingValidation() || Unconfirmed():
            if (!spentByAny.contains(point)) pendingIn += out.valueSats;
          case Unverified():
            break;
        }
      }
    }

    // Confirmed coins spent by not-yet-confirmed transactions leave the
    // pending side negative.
    var pendingOut = 0;
    for (final r in usable) {
      if (r.confirmation is Confirmed) continue;
      for (final input in r.tx.inputs) {
        final prev = byTxid[input.txid];
        if (prev == null || prev.confirmation is! Confirmed) continue;
        final out = prev.tx.outputs.where((o) => o.vout == input.vout);
        if (out.isNotEmpty && ownScripts.contains(out.first.scriptPubKey)) {
          pendingOut += out.first.valueSats;
        }
      }
    }

    final history = <WalletTransactionView>[];
    for (final r in usable) {
      var net = 0;
      for (final out in r.tx.outputs) {
        if (ownScripts.contains(out.scriptPubKey)) net += out.valueSats;
      }
      for (final input in r.tx.inputs) {
        final prev = byTxid[input.txid];
        if (prev == null) continue;
        for (final o in prev.tx.outputs) {
          if (o.vout == input.vout && ownScripts.contains(o.scriptPubKey)) {
            net -= o.valueSats;
          }
        }
      }
      history.add(
        WalletTransactionView(
          txid: r.tx.txid,
          netSats: net,
          confirmation: r.confirmation,
        ),
      );
    }
    history.sort(
      (a, b) => _order(b.confirmation).compareTo(_order(a.confirmation)),
    );

    return (
      balance: WalletBalance(
        confirmed: confirmed,
        immature: immature,
        pending: pendingIn - pendingOut,
        spendable: spendable,
      ),
      history: history,
    );
  }

  /// Newest first: unconfirmed, pending, then by height.
  static int _order(TxConfirmation c) => switch (c) {
    Unconfirmed() => 1 << 40,
    PendingValidation(:final height) => (1 << 39) + height,
    Confirmed(:final height) => height,
    Unverified() => -1,
  };
}
