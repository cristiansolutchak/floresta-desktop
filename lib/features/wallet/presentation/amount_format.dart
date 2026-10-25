/// Formats satoshis as BTC with all 8 decimals, using integer arithmetic
/// only (amounts are never doubles). Negative values keep their sign.
String formatBtc(int sats, {bool signed = false}) {
  final sign = sats < 0 ? '−' : (signed && sats > 0 ? '+' : '');
  final abs = sats.abs();
  final whole = abs ~/ 100000000;
  final frac = (abs % 100000000).toString().padLeft(8, '0');
  final grouped = whole.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return '$sign$grouped.$frac BTC';
}

/// `1a2b3c…7d8e` for long identifiers shown in lists.
String shortId(String id, {int keep = 8}) => id.length <= keep * 2 + 1
    ? id
    : '${id.substring(0, keep)}…${id.substring(id.length - keep)}';
