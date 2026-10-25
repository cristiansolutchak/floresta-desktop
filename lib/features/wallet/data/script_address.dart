import 'package:blockchain_utils/blockchain_utils.dart';

import '../../settings/domain/bitcoin_network.dart';

/// The address text for a standard scriptPubKey, or null for anything else.
///
/// Segwit v0 uses bech32 (BIP-173) and v1 (taproot) bech32m (BIP-350); P2PKH
/// and P2SH use Base58Check. Prefixes follow Bitcoin Core's chainparams:
/// `bc`/`tb`/`bcrt`, and version bytes 0x00/0x05 on mainnet, 0x6f/0xc4 on
/// the test networks. Only encoding is done here; the scripts come from the
/// deriver, which is checked against Bitcoin Core.
String? addressForScript(String scriptPubKeyHex, BitcoinNetwork network) {
  final List<int> s;
  try {
    s = BytesUtils.fromHexString(scriptPubKeyHex);
  } on Object {
    return null;
  }
  final hrp = switch (network) {
    BitcoinNetwork.bitcoin => 'bc',
    BitcoinNetwork.signet || BitcoinNetwork.testnet4 => 'tb',
    BitcoinNetwork.regtest => 'bcrt',
  };
  final mainnet = network.isMainnet;

  // OP_0 <20|32 bytes> or OP_1 <32 bytes>.
  if (s.length == 22 && s[0] == 0x00 && s[1] == 0x14 ||
      s.length == 34 && s[0] == 0x00 && s[1] == 0x20) {
    return SegwitBech32Encoder.encode(hrp, 0, s.sublist(2));
  }
  if (s.length == 34 && s[0] == 0x51 && s[1] == 0x20) {
    return SegwitBech32Encoder.encode(hrp, 1, s.sublist(2));
  }
  // OP_DUP OP_HASH160 <20> OP_EQUALVERIFY OP_CHECKSIG
  if (s.length == 25 &&
      s[0] == 0x76 &&
      s[1] == 0xa9 &&
      s[2] == 0x14 &&
      s[23] == 0x88 &&
      s[24] == 0xac) {
    return Base58Encoder.checkEncode([
      mainnet ? 0x00 : 0x6f,
      ...s.sublist(3, 23),
    ]);
  }
  // OP_HASH160 <20> OP_EQUAL
  if (s.length == 23 && s[0] == 0xa9 && s[1] == 0x14 && s[22] == 0x87) {
    return Base58Encoder.checkEncode([
      mainnet ? 0x05 : 0xc4,
      ...s.sublist(2, 22),
    ]);
  }
  return null;
}
