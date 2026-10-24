import 'dart:collection';

import 'package:equatable/equatable.dart';

import '../security/sensitive_data.dart';

enum LogSource { stdout, stderr, app }

class LogLine extends Equatable {
  const LogLine(this.time, this.source, this.text);

  final DateTime time;
  final LogSource source;
  final String text;

  @override
  List<Object?> get props => [time, source, text];
}

/// Fixed-capacity, in-memory log of daemon output.
///
/// Bounded because florestad can log continuously for days and the app must
/// not grow without limit. Text is redacted on the way in: florestad logs
/// loaded descriptors at INFO level (`json_rpc/wallet.rs`, "Descriptor
/// pushed"), and nothing downstream should ever see an unmasked xpub.
class LogBuffer {
  LogBuffer({this.capacity = 2000}) : assert(capacity > 0);

  final int capacity;
  final _lines = ListQueue<LogLine>();

  List<LogLine> get lines => List.unmodifiable(_lines);
  int get length => _lines.length;

  LogLine add(LogSource source, String text, {DateTime? at}) {
    final line = LogLine(
      at ?? DateTime.now(),
      source,
      SensitiveData.redact(text),
    );
    _lines.addLast(line);
    while (_lines.length > capacity) {
      _lines.removeFirst();
    }
    return line;
  }

  void clear() => _lines.clear();
}
