// Number, size and duration formatting shared by every screen.

/// "1,234,567".
String formatInt(int n) {
  final s = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

/// "12.3 MB" (decimal units).
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

/// "2d 3h", "4h 5m", "6m", "7s".
String formatDuration(Duration d) {
  if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m';
  return '${d.inSeconds}s';
}

/// "14.4k" for the header's Behind count.
String formatCompact(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    final k = n / 1000;
    return '${k >= 100 ? k.toStringAsFixed(0) : k.toStringAsFixed(1)}k';
  }
  final m = n / 1000000;
  return '${m >= 100 ? m.toStringAsFixed(0) : m.toStringAsFixed(1)}M';
}

/// "62.5%".
String formatPercent1(double f) => '${(f * 100).toStringAsFixed(1)}%';
