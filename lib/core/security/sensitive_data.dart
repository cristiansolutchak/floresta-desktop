/// Detection and redaction of wallet material.
///
/// Floresta's watch-only wallet only ever needs public data. Anything that
/// looks like a private key or seed phrase is rejected before it reaches the
/// node, and extended public keys are masked before text is shown in logs,
/// because an xpub reveals a wallet's complete history.
abstract final class SensitiveData {
  static const _base58 = '[1-9A-HJ-NP-Za-km-z]';

  /// BIP-32 / SLIP-132 extended private keys (mainnet and testnet variants).
  static final _extendedPrivateKey = RegExp(
    '(?:[xyzt]prv|[uv]prv|[YZUV]prv)$_base58{100,}',
  );

  /// WIF private keys: mainnet uncompressed `5…` (51 chars), compressed
  /// `K…`/`L…` (52), and testnet `9…` (51) / `c…` (52).
  static final _wif = RegExp(
    '(?:^|[^1-9A-HJ-NP-Za-km-z])'
    '(?:5$_base58{50}|[KLc]$_base58{51}|9$_base58{50})'
    r'(?![1-9A-HJ-NP-Za-km-z])',
  );

  /// Extended public keys, used only for redaction.
  static final _extendedPublicKey = RegExp(
    '(?:[xyzt]pub|[uv]pub|[YZUV]pub)$_base58{100,}',
  );

  /// Twelve or more lowercase words and nothing else: the shape of a BIP-39
  /// mnemonic. Deliberately does not check the wordlist; the cost of a false
  /// positive is a refused paste, which is acceptable.
  static final _mnemonic = RegExp(r'^\s*(?:[a-z]{3,8}\s+){11,}[a-z]{3,8}\s*$');

  /// Returns a reason when [input] contains private key material, else null.
  static String? detectSecret(String input) {
    if (_extendedPrivateKey.hasMatch(input)) {
      return 'The input contains an extended private key (xprv/tprv/…).';
    }
    if (_mnemonic.hasMatch(input)) {
      return 'The input looks like a seed phrase.';
    }
    if (_wif.hasMatch(input)) {
      return 'The input contains what looks like a WIF private key.';
    }
    return null;
  }

  /// Masks extended keys so log output can be displayed and copied safely.
  static String redact(String text) {
    return text
        .replaceAllMapped(_extendedPrivateKey, (m) => _mask(m[0]!))
        .replaceAllMapped(_extendedPublicKey, (m) => _mask(m[0]!));
  }

  static String _mask(String key) => '${key.substring(0, 4)}…[redacted]';
}
