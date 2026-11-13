import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Reports whether an executable was built with Swift Sync.
typedef CapabilityScan = Future<bool> Function(String executablePath);

/// A string only florestad builds with Swift Sync contain: the log line
/// `swift_sync_ctx.rs` prints when it starts (master `3a47993`; absent from
/// v0.9.1). `--version` cannot tell them apart: a master build prints
/// "florestad v0.9.0" (observed 2026-11-13).
const swiftSyncMarker = 'Performing SwiftSync';

/// Scans [path] for [swiftSyncMarker] off the UI isolate. False when the
/// file cannot be read.
Future<bool> scanForSwiftSync(String path) =>
    Isolate.run(() => fileContains(path, swiftSyncMarker.codeUnits));

/// Streams [path] in chunks and looks for [needle], carrying the tail of
/// each chunk over so a match across chunks is found.
bool fileContains(String path, List<int> needle) {
  RandomAccessFile? raf;
  try {
    raf = File(path).openSync();
    final keep = needle.length - 1;
    var carry = Uint8List(0);
    while (true) {
      final chunk = raf.readSync(1 << 20);
      if (chunk.isEmpty) return false;
      final buf = Uint8List(carry.length + chunk.length)
        ..setAll(0, carry)
        ..setAll(carry.length, chunk);
      if (_indexOf(buf, needle) >= 0) return true;
      carry = buf.length > keep
          ? Uint8List.sublistView(buf, buf.length - keep)
          : buf;
    }
  } on FileSystemException {
    return false;
  } finally {
    raf?.closeSync();
  }
}

int _indexOf(Uint8List hay, List<int> needle) {
  final first = needle[0];
  final last = hay.length - needle.length;
  outer:
  for (var i = 0; i <= last; i++) {
    if (hay[i] != first) continue;
    for (var j = 1; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
