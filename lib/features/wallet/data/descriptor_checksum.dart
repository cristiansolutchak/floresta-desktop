/// BIP-380 descriptor checksum (a BCH code; not a cryptographic hash).
///
/// Port of the reference algorithm in BIP-380. Uses 40-bit integers, which
/// is safe on the Dart VM (desktop targets); not intended for web builds.
abstract final class DescriptorChecksum {
  static const _inputCharset =
      "0123456789()[],'/*abcdefgh@:\$%{}"
      'IJKLMNOPQRSTUVWXYZ&+-.;<=>?!^_|~'
      'ijklmnopqrstuvwxyzABCDEFGH`#"\\ ';
  static const _checksumCharset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
  static const _generator = [
    0xf5dee51989,
    0xa9fdca3312,
    0x1bab10e32d,
    0x3706b1677a,
    0x644d626ffd,
  ];

  static int _polymod(Iterable<int> symbols) {
    var chk = 1;
    for (final value in symbols) {
      final top = chk >> 35;
      chk = ((chk & 0x7ffffffff) << 5) ^ value;
      for (var i = 0; i < 5; i++) {
        if ((top >> i) & 1 == 1) chk ^= _generator[i];
      }
    }
    return chk;
  }

  static List<int>? _expand(String s) {
    final symbols = <int>[];
    final groups = <int>[];
    for (final ch in s.split('')) {
      final v = _inputCharset.indexOf(ch);
      if (v < 0) return null;
      symbols.add(v & 31);
      groups.add(v >> 5);
      if (groups.length == 3) {
        symbols.add(groups[0] * 9 + groups[1] * 3 + groups[2]);
        groups.clear();
      }
    }
    if (groups.length == 1) symbols.add(groups[0]);
    if (groups.length == 2) symbols.add(groups[0] * 3 + groups[1]);
    return symbols;
  }

  /// The 8-character checksum for [body] (descriptor without `#…`), or null
  /// if it contains characters outside the descriptor charset.
  static String? compute(String body) {
    final symbols = _expand(body);
    if (symbols == null) return null;
    final c = _polymod([...symbols, 0, 0, 0, 0, 0, 0, 0, 0]) ^ 1;
    return [
      for (var i = 0; i < 8; i++) _checksumCharset[(c >> (5 * (7 - i))) & 31],
    ].join();
  }
}
