import 'package:floresta_desktop/features/node/domain/verification_breakdown.dart';
import 'package:floresta_desktop/features/settings/domain/bitcoin_network.dart';
import 'package:flutter_test/flutter_test.dart';

VerificationBreakdown _b(BitcoinNetwork n, {required int h, required int v}) =>
    VerificationBreakdown(
      headers: h,
      validated: v,
      snapshotHeight: n.assumeUtreexoHeight,
      assumeValidHeight: n.assumeValidHeight,
    );

void main() {
  test('upstream v0.9.1 snapshot and assume-valid heights', () {
    expect(BitcoinNetwork.bitcoin.assumeUtreexoHeight, 939969);
    expect(BitcoinNetwork.signet.assumeUtreexoHeight, 296870);
    expect(BitcoinNetwork.testnet4.assumeUtreexoHeight, 0);
    expect(BitcoinNetwork.regtest.assumeUtreexoHeight, 0);
    expect(BitcoinNetwork.testnet4.assumeValidHeight, 126514);
  });

  test('signet right after the snapshot: nothing verified by the node', () {
    final b = _b(BitcoinNetwork.signet, h: 327843, v: 296870);
    expect(b.snapshotApplied, isTrue);
    expect(b.acceptedUpTo, 296870);
    expect(b.verifiedByNode, 0);
    expect(b.toVerify, 30973);
    expect(b.fraction, 0);
    expect(b.scriptsSkippedUpTo, 0, reason: 'assume-valid = snapshot');
  });

  test('blocks after the snapshot count once verified', () {
    final b = _b(BitcoinNetwork.signet, h: 327843, v: 300000);
    expect(b.verifiedByNode, 3130);
    expect(b.fraction, closeTo(3130 / 30973, 1e-9));
  });

  test('before the headers reach the snapshot nothing is accepted', () {
    final b = _b(BitcoinNetwork.signet, h: 192000, v: 0);
    expect(b.snapshotApplied, isFalse);
    expect(b.acceptedUpTo, 0);
    expect(b.verifiedByNode, 0);
  });

  test('without a snapshot every block is the node\'s own work', () {
    final b = _b(BitcoinNetwork.testnet4, h: 130000, v: 130000);
    expect(b.snapshotApplied, isFalse);
    expect(b.verifiedByNode, 130000);
    expect(b.fraction, 1);
    expect(b.scriptsSkippedUpTo, 126514, reason: 'testnet4 assume-valid');
  });

  test('mainnet synced past the snapshot', () {
    final b = _b(BitcoinNetwork.bitcoin, h: 960000, v: 960000);
    expect(b.acceptedUpTo, 939969);
    expect(b.verifiedByNode, 20031);
    expect(b.fraction, 1);
  });
}
