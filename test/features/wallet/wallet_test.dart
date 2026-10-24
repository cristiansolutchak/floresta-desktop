import 'dart:convert';

import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/core/rpc/json_rpc_client.dart';
import 'package:floresta_gui/features/wallet/data/wallet_repository_impl.dart';
import 'package:floresta_gui/features/wallet/domain/descriptor_input.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../helpers/fake_process.dart';

void main() {
  group('DescriptorInput.parse', () {
    test('accepts public descriptors, with or without checksum', () {
      for (final d in [
        'wpkh(${FakeKeys.xpub}/<0;1>/*)',
        'sh(wpkh([d34db33f/49h/0h/0h]${FakeKeys.xpub}/0/*))#8f2m0x6z',
        'tr(${FakeKeys.tpub}/<0;1>/*)',
        'wsh(multi(2,${FakeKeys.xpub}/0/*,${FakeKeys.tpub}/0/*))',
        'addr(bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq)',
      ]) {
        expect(DescriptorInput.parse(d).isRight(), isTrue, reason: d);
      }
    });

    test('trims surrounding whitespace', () {
      final r = DescriptorInput.parse('  wpkh(${FakeKeys.xpub}/0/*)\n');
      expect(r.toNullable()?.value, 'wpkh(${FakeKeys.xpub}/0/*)');
    });

    test('rejects private keys before anything is sent', () {
      for (final secret in [
        'wpkh(${FakeKeys.xprv}/0/*)',
        FakeKeys.tprv,
        'wpkh(${FakeKeys.wifCompressed})',
        'abandon ability able about above absent absorb abstract absurd '
            'abuse access accident',
      ]) {
        expect(
          DescriptorInput.parse(secret).getLeft().toNullable(),
          isA<SecretMaterialRejectedFailure>(),
          reason: secret,
        );
      }
    });

    test('explains that bare xpubs need wrapping', () {
      final f = DescriptorInput.parse(FakeKeys.zpub).getLeft().toNullable();
      expect(f, isA<ValidationFailure>());
      expect(f?.recovery, contains('wpkh('));
    });

    test('rejects malformed input', () {
      for (final bad in [
        '',
        'hello',
        'wpkh(abc',
        'wpkh(a) extra',
        'wpkh(a))(',
      ]) {
        expect(DescriptorInput.parse(bad).isLeft(), isTrue, reason: bad);
      }
    });
  });

  group('WalletRepositoryImpl', () {
    late List<Map<String, Object?>> requests;

    WalletRepositoryImpl repo(http.Response Function(String method) respond) {
      requests = [];
      return WalletRepositoryImpl(
        JsonRpcClient(
          endpoint: Uri.parse('http://127.0.0.1:38332/'),
          httpClient: MockClient((req) async {
            final body = jsonDecode(req.body) as Map<String, Object?>;
            requests.add(body);
            return respond(body['method']! as String);
          }),
        ),
      );
    }

    http.Response ok(Object? result) =>
        http.Response(jsonEncode({'id': 1, 'result': result}), 200);
    http.Response err(int code, String msg, int status) => http.Response(
      jsonEncode({
        'id': 1,
        'error': {'code': code, 'message': msg},
      }),
      status,
    );

    test('lists descriptors', () async {
      final r = repo((_) => ok(['wpkh(a)', 'tr(b)']));
      expect((await r.listDescriptors()).toNullable(), ['wpkh(a)', 'tr(b)']);
    });

    test('loads a validated descriptor verbatim', () async {
      final r = repo((_) => ok(true));
      final input = DescriptorInput.parse(
        'wpkh(${FakeKeys.xpub}/0/*)',
      ).toNullable()!;
      expect((await r.loadDescriptor(input)).isRight(), isTrue);
      expect(requests.single['method'], 'loaddescriptor');
      expect(requests.single['params'], [input.value]);
    });

    test('omits the start height when rescanning from genesis', () async {
      final r = repo((_) => ok(true));
      await r.rescan();
      await r.rescan(fromHeight: 800000);
      expect(requests[0]['params'], isEmpty);
      expect(requests[1]['params'], [800000]);
    });

    test('explains wallet errors from the node', () async {
      final ibd = await repo((_) => err(-32093, 'IBD', 503)).rescan();
      expect(ibd.getLeft().toNullable()?.title, 'Node is still syncing');

      final noFilters = await repo(
        (_) => err(-32092, 'No block filters', 503),
      ).rescan();
      expect(
        noFilters.getLeft().toNullable()?.recovery,
        contains('compact block filters'),
      );
    });
  });
}
