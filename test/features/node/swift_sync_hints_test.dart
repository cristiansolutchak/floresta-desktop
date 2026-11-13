import 'dart:io';

import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/features/node/data/swift_sync_hints.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/features/settings/domain/node_settings.dart';
import 'package:flutter_test/flutter_test.dart';

/// A signet-like hints body: the real header (stop 320 000) and filler.
final _hints = [
  0x55, 0x54, 0x58, 0x4f, 0x00, 0x00, 0xe2, 0x04, 0x00, //
  ...List.filled(70000, 7),
];

void main() {
  late Directory tmp;
  late HttpServer server;
  late List<String> requests;
  late List<int> body;
  late int status;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hints_test');
    requests = [];
    body = _hints;
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) {
      requests.add(r.uri.path);
      r.response.statusCode = status;
      r.response.add(body);
      r.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  NodeSettings settings({SyncMethod method = SyncMethod.swiftSync}) =>
      NodeSettings(
        network: BitcoinNetwork.signet,
        dataDir: tmp.path,
        hintsOrigin: 'http://127.0.0.1:${server.port}/hints',
      ).withSyncMethod(method);

  final service = SwiftSyncHints(homeDir: null, separator: '/');
  File file(String name) => File('${tmp.path}/signet/$name');

  test('downloads into the network folder, then renames', () async {
    final seen = <int>[];
    final r = await service.prepare(settings(), onProgress: seen.add);
    final ready = r.getOrElse((f) => fail('$f')) as HintsReady;
    expect(ready.stopHeight, 320000);
    expect(ready.downloaded, isTrue);
    expect(requests, ['/hints/signet']);
    expect(await file('signet.hints').readAsBytes(), _hints);
    expect(await file('signet.hints.part').exists(), isFalse);
    expect(seen.last, _hints.length);
  });

  test('an existing file is checked, not downloaded again', () async {
    await file('signet.hints').create(recursive: true);
    await file('signet.hints').writeAsBytes(_hints);
    final r = await service.prepare(settings());
    expect((r.getOrElse((f) => fail('$f')) as HintsReady).downloaded, isFalse);
    expect(requests, isEmpty);
  });

  test('a folder that already holds a chain downloads nothing', () async {
    await Directory('${tmp.path}/signet/chaindata').create(recursive: true);
    final r = await service.prepare(settings());
    expect(r.getOrElse((f) => fail('$f')), isA<HintsExistingChain>());
    expect(requests, isEmpty);
  });

  test('a body that is not a hints file is refused and not kept', () async {
    body = '<html>not found</html>'.codeUnits;
    final r = await service.prepare(settings());
    expect(r.getLeft().toNullable(), isA<SwiftSyncHintsFailure>());
    expect(await file('signet.hints').exists(), isFalse);
    expect(await file('signet.hints.part').exists(), isFalse);
  });

  test('an HTTP error leaves nothing behind', () async {
    status = 404;
    final r = await service.prepare(settings());
    expect(r.getLeft().toNullable()?.message, contains('HTTP 404'));
    expect(await file('signet.hints').exists(), isFalse);
  });

  test('an oversized body is refused', () async {
    final small = SwiftSyncHints(homeDir: null, separator: '/', maxBytes: 100);
    final r = await small.prepare(settings());
    expect(r.getLeft().toNullable()?.message, contains('too large'));
    expect(await file('signet.hints').exists(), isFalse);
  });

  test('plain http to another host is refused before connecting', () async {
    final r = await service.prepare(
      settings().copyWith(hintsOrigin: 'http://example.com/hints'),
    );
    expect(r.getLeft().toNullable(), isA<SwiftSyncHintsFailure>());
    expect(requests, isEmpty);
  });

  test('turning Swift Sync off parks the file; on brings it back', () async {
    await file('signet.hints').create(recursive: true);
    await file('signet.hints').writeAsBytes(_hints);
    expect(
      (await service.prepare(
        settings(method: SyncMethod.full),
      )).getOrElse((f) => fail('$f')),
      isA<HintsNotUsed>(),
    );
    expect(await file('signet.hints').exists(), isFalse);
    expect(await file('signet.hints.disabled').exists(), isTrue);
    final back = await service.prepare(settings());
    expect(
      (back.getOrElse((f) => fail('$f')) as HintsReady).downloaded,
      isFalse,
    );
    expect(await file('signet.hints').exists(), isTrue);
    expect(requests, isEmpty);
  });

  test('both files present while off is reported, nothing moved', () async {
    await file('signet.hints').create(recursive: true);
    await file('signet.hints.disabled').create(recursive: true);
    final r = await service.prepare(settings(method: SyncMethod.fastStart));
    expect(r.getLeft().toNullable(), isA<SwiftSyncHintsFailure>());
    expect(await file('signet.hints').exists(), isTrue);
    expect(await file('signet.hints.disabled').exists(), isTrue);
  });

  test('networks without hints are left alone', () async {
    final r = await service.prepare(
      settings().copyWith(network: BitcoinNetwork.regtest),
    );
    expect(r.getOrElse((f) => fail('$f')), isA<HintsNotUsed>());
    expect(requests, isEmpty);
  });
}
