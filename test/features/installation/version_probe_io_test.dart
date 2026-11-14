@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:floresta_gui/features/installation/data/executable_locator.dart';
import 'package:floresta_gui/features/installation/data/version_probe.dart';
import 'package:floresta_gui/features/installation/domain/floresta_version.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';

/// Exercises the real `dart:io` process path with a stand-in script that
/// prints what florestad prints. The real-florestad tests are in
/// `test/integration`.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('floresta_probe_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<String> script(String name, String body, {bool exec = true}) async {
    final file = File('${dir.path}/$name')..writeAsStringSync(body);
    if (exec) await Process.run('chmod', ['+x', file.path]);
    return file.path;
  }

  test('probes a real executable', () async {
    final path = await script(
      'florestad',
      '#!/bin/sh\necho "florestad v0.9.1"\n',
    );
    expect(await isExecutableFile(path), isTrue);
    expect(
      await VersionProbe().probe(path),
      const Right(FlorestaVersion(0, 9, 1)),
    );
  });

  test('detects non-executable files', () async {
    final path = await script('florestad', 'not a program', exec: false);
    expect(await isExecutableFile(path), isFalse);
    expect(await isExecutableFile('${dir.path}/missing'), isFalse);
    expect(await isExecutableFile(dir.path), isFalse);
  });

  test('times out and kills a hanging executable', () async {
    final path = await script('florestad', '#!/bin/sh\nsleep 30\n');
    final r = await VersionProbe(
      timeout: const Duration(milliseconds: 300),
    ).probe(path);
    expect(r.getLeft().toNullable()?.message, contains('did not answer'));
  });
}
