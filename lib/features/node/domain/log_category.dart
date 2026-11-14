import 'package:equatable/equatable.dart';

/// The Logs screen filters, mapped from florestad's tracing
/// targets: v0.9.1 logs `<date> <time>  <LEVEL> <crate::module>: <message>`
/// (`bin/florestad/src/main.rs`, `with_target(true)`), one crate per area.
enum LogCategory {
  sync('Sync', 'sync'),
  network('Network', 'p2p'),
  services('Services', 'svc'),
  wallet('Wallet', 'wallet'),
  rpc('RPC', 'rpc'),
  electrum('Electrum', 'electrum');

  const LogCategory(this.label, this.tag);
  final String label;

  /// Short tag shown before each line ("[p2p]").
  final String tag;

  /// The category for a tracing target.
  static LogCategory forTarget(String target) {
    if (target.startsWith('floresta_node::json_rpc')) return rpc;
    if (target.startsWith('floresta_chain')) return sync;
    if (target.startsWith('floresta_wire') ||
        target.startsWith('floresta_mempool')) {
      return network;
    }
    if (target.startsWith('floresta_electrum')) return electrum;
    if (target.startsWith('floresta_watch_only') ||
        target.startsWith('floresta_compact_filters')) {
      return wallet;
    }
    return services;
  }
}

/// One daemon line split into what the Logs screen shows.
class ParsedLogLine extends Equatable {
  const ParsedLogLine({
    required this.text,
    required this.category,
    this.time,
    this.level,
    this.message,
  });

  /// The line as captured (already redacted).
  final String text;
  final LogCategory category;

  /// "12:04:01", when the line has florestad's timestamp.
  final String? time;

  /// INFO, WARN, ERROR, DEBUG or TRACE.
  final String? level;

  /// The text after the target; null for lines in another format.
  final String? message;

  bool get isProblem => level == 'WARN' || level == 'ERROR';

  @override
  List<Object?> get props => [text, category, time, level, message];
}

final _line = RegExp(
  r'^\d{4}-\d{2}-\d{2} (\d{2}:\d{2}:\d{2})\s+(TRACE|DEBUG|INFO|WARN|ERROR)\s+([A-Za-z0-9_:]+): ?(.*)$',
);

/// Parses daemon lines. Lines without florestad's prefix (wrapped output,
/// the app's own notes) belong to the previous line's category, or to
/// Services when there is none.
List<ParsedLogLine> parseLogLines(Iterable<String> lines) {
  var previous = LogCategory.services;
  return [
    for (final text in lines)
      if (_line.firstMatch(text) case final m?)
        () {
          previous = LogCategory.forTarget(m.group(3)!);
          return ParsedLogLine(
            text: text,
            category: previous,
            time: m.group(1),
            level: m.group(2),
            message: m.group(4),
          );
        }()
      else
        ParsedLogLine(text: text, category: previous),
  ];
}
