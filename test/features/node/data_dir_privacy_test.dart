@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:floresta_gui/features/node/data/preflight_probe.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/features/settings/domain/node_settings.dart';
import 'package:flutter_test/flutter_test.dart';

String _mode(String path) =>
    (Process.runSync('/usr/bin/stat', [
              Platform.isMacOS ? '-f' : '-c',
              Platform.isMacOS ? '%Lp' : '%a',
              path,
            ]).stdout
            as String)
        .trim();

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('datadir_'));
  tearDown(() => temp.deleteSync(recursive: true));

  NodeSettings mainnetAt(String dir) =>
      NodeSettings(network: BitcoinNetwork.bitcoin, dataDir: dir);

  test('a new data folder is created private', () async {
    final dir = '${temp.path}/node';
    final probe = PreflightProbe(homeDir: temp.path);
    expect(await probe.restrictDataDir(mainnetAt(dir)), isTrue);
    expect(_mode(dir), '700');
  });

  test(
    "an existing florestad folder is made private, contents untouched",
    () async {
      final dir = Directory('${temp.path}/node')..createSync();
      File('${dir.path}/conf').writeAsStringSync('x');
      File('${dir.path}/db').writeAsStringSync('watch-only');
      Process.runSync('/bin/chmod', ['755', dir.path]);
      final probe = PreflightProbe(homeDir: temp.path);
      expect(await probe.restrictDataDir(mainnetAt(dir.path)), isTrue);
      expect(_mode(dir.path), '700');
      expect(File('${dir.path}/db').readAsStringSync(), 'watch-only');
    },
  );

  test('a folder with other content is left alone', () async {
    final dir = Directory('${temp.path}/shared')..createSync();
    File('${dir.path}/notes.txt').writeAsStringSync('mine');
    Process.runSync('/bin/chmod', ['755', dir.path]);
    final probe = PreflightProbe(homeDir: temp.path);
    expect(await probe.restrictDataDir(mainnetAt(dir.path)), isFalse);
    expect(_mode(dir.path), '755');
  });

  test('Windows is left to its per-user folders', () async {
    final probe = PreflightProbe(homeDir: temp.path, isWindows: true);
    expect(
      await probe.restrictDataDir(mainnetAt('${temp.path}/node')),
      isFalse,
    );
    expect(Directory('${temp.path}/node').existsSync(), isFalse);
  });
}
