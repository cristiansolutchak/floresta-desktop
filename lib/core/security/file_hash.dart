import 'dart:io';
import 'dart:isolate';

import 'package:blockchain_utils/blockchain_utils.dart';

/// Lowercase hex SHA-256 of a file, computed off the UI isolate.
Future<String> sha256OfFile(String path) => Isolate.run(() {
  final hasher = SHA256();
  final raf = File(path).openSync();
  try {
    final buffer = List<int>.filled(1 << 20, 0);
    while (true) {
      final n = raf.readIntoSync(buffer);
      if (n == 0) break;
      hasher.update(n == buffer.length ? buffer : buffer.sublist(0, n));
    }
  } finally {
    raf.closeSync();
  }
  return BytesUtils.toHexString(hasher.digest());
});
