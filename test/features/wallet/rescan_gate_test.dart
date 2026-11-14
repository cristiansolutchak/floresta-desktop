import 'package:floresta_desktop/features/wallet/domain/rescan_gate.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cases mirror Mandacaru's `WalletRescanGateTest` (MIT), adapted to what
/// florestad 0.9.1 can report (no filter sync or rescan-in-progress).
void main() {
  late Duration now;
  late RescanGate gate;

  setUp(() {
    now = Duration.zero;
    gate = RescanGate(clock: () => now);
  });

  void advance(Duration d) => now += d;

  test('does not fire before the grace window has elapsed', () {
    expect(gate.shouldTrigger(chainSynced: true), isFalse);
    advance(const Duration(seconds: 59));
    expect(gate.shouldTrigger(chainSynced: true), isFalse);
  });

  test('fires once the grace window has elapsed', () {
    gate.shouldTrigger(chainSynced: true);
    advance(const Duration(seconds: 60));
    expect(gate.shouldTrigger(chainSynced: true), isTrue);
  });

  test('never fires while the chain is not synced', () {
    for (var i = 0; i < 10; i++) {
      advance(const Duration(minutes: 5));
      expect(gate.shouldTrigger(chainSynced: false), isFalse);
    }
  });

  test('losing sync restarts the grace window', () {
    gate.shouldTrigger(chainSynced: true);
    advance(const Duration(seconds: 50));
    gate.shouldTrigger(chainSynced: false);
    advance(const Duration(seconds: 20));
    expect(gate.shouldTrigger(chainSynced: true), isFalse);
    advance(const Duration(seconds: 60));
    expect(gate.shouldTrigger(chainSynced: true), isTrue);
  });

  test('a failure backs off twice the grace window', () {
    gate.shouldTrigger(chainSynced: true);
    advance(const Duration(seconds: 60));
    expect(gate.shouldTrigger(chainSynced: true), isTrue);
    gate.onFailed();
    advance(const Duration(seconds: 119));
    expect(gate.shouldTrigger(chainSynced: true), isFalse);
    advance(const Duration(seconds: 1));
    expect(gate.shouldTrigger(chainSynced: true), isTrue);
  });

  test('backoff doubles per failure and caps at thirty minutes', () {
    gate.shouldTrigger(chainSynced: true);
    advance(const Duration(seconds: 60));
    for (var i = 0; i < 8; i++) {
      gate.onFailed();
    }
    advance(const Duration(minutes: 29, seconds: 59));
    expect(gate.shouldTrigger(chainSynced: true), isFalse);
    advance(const Duration(seconds: 1));
    expect(gate.shouldTrigger(chainSynced: true), isTrue);
  });

  test('gives up after ten failed attempts', () {
    for (var i = 1; i < 10; i++) {
      expect(gate.onFailed(), isFalse, reason: 'attempt $i');
    }
    expect(gate.onFailed(), isTrue);
  });

  test('a successful trigger resets the attempt budget and backoff', () {
    gate.shouldTrigger(chainSynced: true);
    advance(const Duration(seconds: 60));
    gate.onFailed();
    gate.onFailed();
    gate.onTriggered();
    expect(gate.failures, 0);
    advance(const Duration(seconds: 60));
    expect(gate.shouldTrigger(chainSynced: true), isTrue);
  });
}
