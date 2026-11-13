import 'dart:io';

import 'package:floresta_gui/core/app_version.dart';
import 'package:floresta_gui/features/installation/domain/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the version in code matches pubspec.yaml', () {
    final line = File(
      'pubspec.yaml',
    ).readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    final pubspec = line.split(':').last.trim().split('+').first;
    expect(appVersionText, pubspec);
    expect(AppVersion.tryParse(appVersionText), isNotNull);
  });
}
