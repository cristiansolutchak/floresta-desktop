import 'dart:io';

import 'package:floresta_gui/core/logging/log_buffer.dart';
import 'package:floresta_gui/features/settings/data/text_file_writer.dart';
import 'package:floresta_gui/features/settings/presentation/diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_process.dart';

void main() {
  test(
    'the exported file has the report and redacted output, no keys',
    () async {
      // Lines reach the export through LogBuffer, as in the app.
      final buffer = LogBuffer()
        ..add(LogSource.stdout, 'INFO floresta_node: watching ${FakeKeys.xpub}')
        ..add(LogSource.stdout, 'INFO floresta_wire: New peer id=3');
      final text = diagnosticsFileText(
        report: 'App version: 0.0.1\nNetwork: Mainnet',
        lines: [for (final l in buffer.lines) l.text],
        now: DateTime.utc(2026, 10, 27, 12),
      );
      expect(text, contains('App version: 0.0.1'));
      expect(text, contains('New peer id=3'));
      expect(text, contains('Daemon output (last 2 lines):'));
      expect(text, isNot(contains(FakeKeys.xpub)));

      final dir = Directory.systemTemp.createTempSync('diag_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/floresta-diagnostics.txt';
      expect((await writeTextFile(path, text)).isRight(), isTrue);
      expect(File(path).readAsStringSync(), text);
      // An unwritable place is reported, not thrown.
      expect(
        (await writeTextFile('${dir.path}/missing/x.txt', text)).isLeft(),
        isTrue,
      );
    },
  );
}
