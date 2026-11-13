import 'dart:io';

import 'package:floresta_gui/features/installation/data/manifest_fetch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a missing local release server is not blamed on the internet',
    () async {
      // A port nothing listens on.
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final r = await fetchSignedManifest(
        HttpClient.new,
        Uri.parse('http://127.0.0.1:$port/manifest.json'),
      );
      final f = r.getLeft().toNullable()!;
      expect(f.message, contains('Nothing answers at 127.0.0.1:$port'));
      expect(f.recovery, contains('dev_release.sh'));
      expect(f.recovery, isNot(contains('internet')));
    },
  );
}
