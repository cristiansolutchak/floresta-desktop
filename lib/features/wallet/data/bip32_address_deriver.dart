import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart';

import '../domain/wallet_account.dart';
import '../domain/wallet_sync_ports.dart';

/// Derives scripts with bitcoin_base/blockchain_utils (BIP-32 public
/// derivation, secp256k1, BIP-86 tweak). No cryptography is implemented here.
/// Verified against Bitcoin Core: 200/200 scripts for pkh, sh(wpkh), wpkh, tr
/// on both branches (docs/wallet-balance-history-architecture.md §2).
class Bip32AddressDeriver implements AddressDeriver {
  final _branchKeys = <(String, int), Bip32Slip10Secp256k1>{};

  @override
  DerivedScript derive(WalletDescriptor d, int index) {
    if (index < 0 || index >= 0x80000000) {
      throw ArgumentError.value(index, 'index', 'must be unhardened');
    }
    final branch = _branchKeys.putIfAbsent(
      (d.extendedKey, d.keychain.branch),
      () {
        final account = Bip32Slip10Secp256k1.fromExtendedKey(
          d.extendedKey,
          d.isMainnetKey
              ? Bip32Const.mainNetKeyNetVersions
              : Bip32Const.testNetKeyNetVersions,
        );
        return account.childKey(Bip32KeyIndex(d.keychain.branch));
      },
    );
    final pub = ECPublic.fromBip32(
      branch.childKey(Bip32KeyIndex(index)).publicKey,
    );
    final script = switch (d.scriptType) {
      ScriptType.wpkh => pub.toSegwitAddress().toScriptPubKey(),
      ScriptType.shWpkh => pub.toP2wpkhInP2sh().toScriptPubKey(),
      ScriptType.pkh => pub.toAddress().toScriptPubKey(),
      ScriptType.tr => pub.toTaprootAddress().toScriptPubKey(),
    };
    final spk = script.toHex().toLowerCase();
    return DerivedScript(
      keychain: d.keychain,
      index: index,
      scriptPubKey: spk,
      scripthash: electrumScripthash(spk),
    );
  }
}

/// sha256(scriptPubKey), byte-reversed, hex — the Electrum script hash.
String electrumScripthash(String scriptPubKeyHex) => BytesUtils.toHexString(
  QuickCrypto.sha256Hash(
    BytesUtils.fromHexString(scriptPubKeyHex),
  ).reversed.toList(),
);
