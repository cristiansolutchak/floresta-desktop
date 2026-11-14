import 'package:floresta_desktop/features/node/domain/log_category.dart';
import 'package:floresta_desktop/features/node/domain/peer_address.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('log categories', () {
    // Real v0.9.1 lines from a mainnet debug.log (2026-10-25).
    const lines = [
      '2026-10-25 16:28:37  INFO floresta_chain::pruned_utreexo::chain_state: New tip! height=940729',
      '2026-10-25 18:23:42  INFO floresta_wire::p2p_wire::node: Shutting down node...',
      '2026-10-25 18:23:41  INFO floresta_node::florestad: Stopping node...',
      '2026-10-25 18:23:41  WARN floresta_node::json_rpc::server: bad request',
      '2026-10-25 18:23:41  INFO floresta_electrum::electrum_protocol: client connected',
      '2026-10-25 18:23:41  INFO floresta_watch_only: loaded 2 descriptors',
      'a wrapped continuation line',
    ];

    test('each crate maps to its filter', () {
      final parsed = parseLogLines(lines);
      expect(parsed.map((l) => l.category), [
        LogCategory.sync,
        LogCategory.network,
        LogCategory.services,
        LogCategory.rpc,
        LogCategory.electrum,
        LogCategory.wallet,
        LogCategory.wallet, // continues the previous line
      ]);
    });

    test('time, level and message are split out', () {
      final l = parseLogLines([lines[3]]).single;
      expect(l.time, '18:23:41');
      expect(l.level, 'WARN');
      expect(l.isProblem, isTrue);
      expect(l.message, 'bad request');
    });

    test('lines in another format stay whole', () {
      final l = parseLogLines(['plain text']).single;
      expect(l.message, isNull);
      expect(l.category, LogCategory.services);
    });
  });

  group('validatePeerAddress (v0.9.1 addnode)', () {
    for (final ok in [
      '1.2.3.4:8333',
      '1.2.3.4',
      '[2001:db8::1]:8333',
      '2001:db8::1',
    ]) {
      test(
        'accepts $ok',
        () => expect(validatePeerAddress(ok).isRight(), isTrue),
      );
    }
    for (final bad in [
      '',
      'seed.example.com:8333',
      '1.2.3.4:0',
      '1.2.3.4:70000',
      '1.2.3:8333',
      '[2001:db8::1]:x',
    ]) {
      test(
        'refuses "$bad"',
        () => expect(validatePeerAddress(bad).isLeft(), isTrue),
      );
    }
  });
}
