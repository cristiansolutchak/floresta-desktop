import 'dart:io';

import 'package:floresta_desktop/features/settings/presentation/diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('diagnostics report the version the builds are stamped with', () {
    // pubspec's version becomes CFBundleShortVersionString on macOS and the
    // .deb version on Linux (tool/package_linux.sh).
    final line = File(
      'pubspec.yaml',
    ).readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    final version = line.split(':').last.trim().split('+').first;
    expect(appVersion, version);
  });
}
