import 'package:floresta_gui/features/node/domain/swift_sync.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HintsHeader', () {
    test('reads the stop height of the published signet file', () {
      // First bytes of utxohints.store/hints/signet, 2026-11-13.
      const head = [0x55, 0x54, 0x58, 0x4f, 0x00, 0x00, 0xe2, 0x04, 0x00];
      expect(HintsHeader.stopHeight(head), 320000);
    });

    test('rejects anything else', () {
      expect(HintsHeader.stopHeight([0x55, 0x54, 0x58]), isNull);
      expect(HintsHeader.stopHeight('<html>...'.codeUnits), isNull);
      expect(HintsHeader.plausiblePrefix('UT'.codeUnits), isTrue);
      expect(HintsHeader.plausiblePrefix('<h'.codeUnits), isFalse);
    });
  });

  group('hints origin', () {
    test('https, or http to this computer only', () {
      expect(hintsOriginProblem(defaultHintsOrigin), isNull);
      expect(hintsOriginProblem('http://127.0.0.1:8080/hints'), isNull);
      expect(hintsOriginProblem('http://localhost/hints'), isNull);
      expect(hintsOriginProblem('http://example.com/hints'), isNotNull);
      expect(hintsOriginProblem('ftp://example.com/hints'), isNotNull);
      expect(hintsOriginProblem('example.com/hints'), isNotNull);
    });

    test('no query, fragment or credentials', () {
      expect(hintsOriginProblem('https://a.example/h?x=1'), isNotNull);
      expect(hintsOriginProblem('https://a.example/h#x'), isNotNull);
      expect(hintsOriginProblem('https://u:p@a.example/h'), isNotNull);
    });

    test('the network name is appended, for networks with hints', () {
      expect(
        hintsUrl(defaultHintsOrigin, BitcoinNetwork.bitcoin).toString(),
        'https://utxohints.store/hints/bitcoin',
      );
      expect(
        hintsUrl('https://m.example/h/', BitcoinNetwork.signet).toString(),
        'https://m.example/h/signet',
      );
      expect(hintsUrl(defaultHintsOrigin, BitcoinNetwork.testnet4), isNull);
      expect(hintsUrl(defaultHintsOrigin, BitcoinNetwork.regtest), isNull);
    });

    test('file names follow florestad (`{network}.hints`)', () {
      expect(hintsFileName(BitcoinNetwork.bitcoin), 'bitcoin.hints');
      expect(
        parkedHintsFileName(BitcoinNetwork.signet),
        'signet.hints.disabled',
      );
    });
  });

  group('SwiftSyncProgress from florestad output (3a47993)', () {
    SwiftSyncProgress feed(List<String> lines) =>
        lines.fold(const SwiftSyncProgress(), (p, l) => p.next(l));

    const performing =
        '2026-11-13 18:27:08  INFO wire: Performing SwiftSync up to height '
        '320000 with up to 10 validation workers';
    String block(int h) =>
        '2026-11-13 18:27:08  INFO wire: SwiftSync block: '
        'block_hash=00000086d6b2 height=$h tx_count=1';

    test('runs, counts blocks and finishes (signet spike)', () {
      final running = feed([performing, block(2), block(1), block(3)]);
      expect(running.phase, SwiftSyncPhase.running);
      expect(running.processed, 3);
      expect(running.stopHeight, 320000);
      expect(running.workers, 10);
      expect(running.fraction, closeTo(3 / 320000, 1e-12));
      final done = running.next(
        '2026-11-13 18:42:49  INFO wire: SwiftSync is finished, switching to '
        'Utreexo-proof mode',
      );
      expect(done.phase, SwiftSyncPhase.finished);
      expect(done.processed, 3);
    });

    test('block lines before a start are not counted', () {
      expect(feed([block(1)]).processed, 0);
    });

    test('a skip keeps the node\'s reason', () {
      final p = feed([
        'INFO wire: Skipping SwiftSync: hints stop at 970000, beyond '
            'AssumeValid height 939969.',
      ]);
      expect(p.phase, SwiftSyncPhase.skipped);
      expect(p.reason, contains('beyond AssumeValid height 939969'));
    });

    test('bad hints and an invalid chain abort', () {
      expect(
        feed([
          performing,
          'ERROR wire: SwiftSync failed with the provided hints file; end '
              'aggregator is not zero',
        ]).phase,
        SwiftSyncPhase.aborted,
      );
      final invalid = feed([
        performing,
        'ERROR wire: Aborting SwiftSync: the most PoW chain is invalid at '
            'height 12',
      ]);
      expect(invalid.phase, SwiftSyncPhase.aborted);
      expect(invalid.reason, contains('invalid at height 12'));
    });

    test('an unreadable hints file is a skip', () {
      final p = feed([
        'WARN wire: Could not read SwiftSync hints /d/signet.hints: '
            'unexpected end of file',
      ]);
      expect(p.phase, SwiftSyncPhase.skipped);
      expect(p.reason, contains('unexpected end of file'));
    });
  });
}
