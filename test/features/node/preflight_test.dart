@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:floresta_gui/features/node/data/preflight_probe.dart';
import 'package:floresta_gui/features/node/domain/preflight.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/features/settings/domain/node_settings.dart';
import 'package:flutter_test/flutter_test.dart';

const _gib = 1024 * 1024 * 1024;

PreflightFacts _facts({
  bool rpcFree = true,
  bool electrumFree = true,
  bool? writable = true,
  int? free = 100 * _gib,
  bool core = false,
}) => PreflightFacts(
  rpcPort: 38332,
  rpcPortFree: rpcFree,
  electrumPort: 60001,
  electrumPortFree: electrumFree,
  dataDir: '/d/signet',
  dataDirWritable: writable,
  freeBytes: free,
  looksLikeBitcoinCore: core,
);

void main() {
  group('evaluatePreflight', () {
    test('a healthy machine raises nothing', () {
      expect(evaluatePreflight(_facts()), isEmpty);
    });

    test('each problem blocks with its own explanation', () {
      for (final (facts, title) in [
        (_facts(rpcFree: false), 'Port 38332 is in use'),
        (_facts(electrumFree: false), 'Port 60001 is in use'),
        (_facts(core: true), 'This folder belongs to Bitcoin Core'),
        (_facts(writable: false), 'Cannot write to the data folder'),
        (_facts(free: _gib ~/ 2), 'Not enough disk space'),
      ]) {
        final issues = evaluatePreflight(facts);
        expect(issues.single.title, title);
        expect(issues.single.blocks, isTrue, reason: title);
        expect(issues.single.recovery, isNotNull, reason: title);
      }
    });

    test('low space only warns', () {
      final issue = evaluatePreflight(_facts(free: 3 * _gib)).single;
      expect(issue.severity, PreflightSeverity.warning);
    });

    test('unknown facts never block', () {
      expect(evaluatePreflight(_facts(writable: null, free: null)), isEmpty);
    });

    test('blocking issues come first', () {
      final issues = evaluatePreflight(_facts(free: 3 * _gib, rpcFree: false));
      expect(issues.map((i) => i.severity), [
        PreflightSeverity.blocking,
        PreflightSeverity.warning,
      ]);
    });
  });

  group('PreflightProbe on this machine', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('preflight_'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('detects a port held by another listener', () async {
      final held = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(held.close);
      expect(await PreflightProbe.portIsFree(held.port), isFalse);
      final freePort = held.port;
      await held.close();
      expect(await PreflightProbe.portIsFree(freePort), isTrue);
    });

    test('write check leaves no file behind', () async {
      expect(await PreflightProbe.canWrite(temp), isTrue);
      expect(temp.listSync(), isEmpty);
    });

    test(
      'a read-only folder is reported as not writable',
      () async {
        final ro = Directory('${temp.path}/ro')..createSync();
        await Process.run('chmod', ['555', ro.path]);
        addTearDown(() => Process.runSync('chmod', ['755', ro.path]));
        expect(await PreflightProbe.canWrite(ro), isFalse);
      },
      // Root ignores permission bits (e.g. in a Linux container).
      skip: '${Process.runSync('id', ['-u']).stdout}'.trim() == '0'
          ? 'root can write anywhere'
          : false,
    );

    test('free space comes from the OS', () async {
      final free = await PreflightProbe(
        homeDir: temp.path,
      ).freeBytes(temp.path);
      expect(free, isNotNull);
      expect(free, greaterThan(0));
    });

    test('recognises a Bitcoin Core data folder', () {
      expect(PreflightProbe.looksLikeBitcoinCore(temp), isFalse);
      Directory('${temp.path}/blocks').createSync();
      Directory('${temp.path}/chainstate').createSync();
      expect(PreflightProbe.looksLikeBitcoinCore(temp), isTrue);
    });

    test('gather checks the network data folder florestad will use', () async {
      final facts = await PreflightProbe(homeDir: temp.path).gather(
        NodeSettings(network: BitcoinNetwork.regtest, dataDir: temp.path),
      );
      expect(facts.dataDir, '${temp.path}/regtest');
      // The regtest subfolder does not exist yet: the closest existing
      // folder (temp) is checked, and nothing is created.
      expect(facts.dataDirWritable, isTrue);
      expect(Directory('${temp.path}/regtest').existsSync(), isFalse);
      expect(facts.freeBytes, greaterThan(0));
      expect(facts.looksLikeBitcoinCore, isFalse);
    });
  });
}
