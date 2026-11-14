import 'dart:io';

import 'package:floresta_desktop/features/installation/data/capability_scan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('scan_test'));
  tearDown(() => tmp.delete(recursive: true));

  Future<String> write(List<int> bytes) async {
    final f = File('${tmp.path}/florestad');
    await f.writeAsBytes(bytes);
    return f.path;
  }

  test('finds the Swift Sync marker, also across read chunks', () async {
    // The marker straddles the 1 MiB chunk boundary.
    final pad = List.filled((1 << 20) - 7, 0);
    final path = await write([...pad, ...swiftSyncMarker.codeUnits, 0]);
    expect(await scanForSwiftSync(path), isTrue);
  });

  test('a build without it (v0.9.1) is reported as such', () async {
    final path = await write('florestad v0.9.1 Performing sync'.codeUnits);
    expect(await scanForSwiftSync(path), isFalse);
  });

  test('a missing file is not an error', () async {
    expect(await scanForSwiftSync('${tmp.path}/none'), isFalse);
  });
}
