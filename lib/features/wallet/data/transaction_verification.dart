import 'package:bitcoin_base/bitcoin_base.dart' hide TxOutput;
import 'package:blockchain_utils/blockchain_utils.dart';

import '../../../core/electrum/electrum_client.dart';
import '../domain/wallet_state.dart';

/// Verification of server-supplied transactions and inclusion proofs.
///
/// Hashing and transaction parsing come from bitcoin_base/blockchain_utils;
/// this class only composes them.
abstract final class TransactionVerification {
  /// Parses [rawHex] and checks it is exactly the transaction [txid] names.
  ///
  /// `BtcTransaction.txId()` hashes a re-serialisation, so the parse must
  /// round-trip byte-for-byte before its txid is trusted.
  static ParsedTransaction? parse(String txid, String rawHex) {
    final BtcTransaction tx;
    try {
      tx = BtcTransaction.deserialize(BytesUtils.fromHexString(rawHex));
    } catch (_) {
      return null;
    }
    if (tx.serialize().toLowerCase() != rawHex.toLowerCase()) return null;
    if (tx.txId() != txid.toLowerCase()) return null;
    final isCoinbase = tx.inputs.length == 1 && tx.inputs.first.coinbase;
    return ParsedTransaction(
      txid: tx.txId(),
      isCoinbase: isCoinbase,
      inputs: [
        if (!isCoinbase)
          for (final i in tx.inputs) OutPoint(i.txId.toLowerCase(), i.txIndex),
      ],
      outputs: [
        for (var v = 0; v < tx.outputs.length; v++)
          TxOutput(
            v,
            tx.outputs[v].amount.toInt(),
            tx.outputs[v].scriptPubKey.toHex().toLowerCase(),
          ),
      ],
    );
  }

  /// Block hash (display hex) of an 80-byte header.
  static String headerHash(String headerHex) => BytesUtils.toHexString(
    QuickCrypto.sha256DoubleHash(
      BytesUtils.fromHexString(headerHex),
    ).reversed.toList(),
  );

  /// True if [proof] links [txid] to the merkle root inside [headerHex].
  static bool merkleMatches({
    required String txid,
    required MerkleProof proof,
    required String headerHex,
  }) {
    final header = BytesUtils.fromHexString(headerHex);
    if (header.length != 80) return false;
    final root = header.sublist(36, 68);
    var current = BytesUtils.fromHexString(txid).reversed.toList();
    var position = proof.position;
    for (final siblingHex in proof.siblings) {
      final sibling = BytesUtils.fromHexString(siblingHex).reversed.toList();
      current = QuickCrypto.sha256DoubleHash(
        position & 1 == 1 ? [...sibling, ...current] : [...current, ...sibling],
      );
      position >>= 1;
    }
    return position == 0 && BytesUtils.bytesEqual(current, root);
  }

  /// Electrum status: sha256 of "txid:height:" concatenated, hex; null when
  /// there is no history (Electrum protocol 1.4).
  static String? electrumStatus(List<HistoryEntry> history) {
    if (history.isEmpty) return null;
    final text = history.map((e) => '${e.txid}:${e.height}:').join();
    return BytesUtils.toHexString(QuickCrypto.sha256Hash(text.codeUnits));
  }
}
