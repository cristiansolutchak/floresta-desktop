import 'dart:ffi' show Abi;

import 'package:floresta_desktop/core/logging/log_buffer.dart';
import 'package:floresta_desktop/core/platform/host_platform.dart';
import 'package:floresta_desktop/core/security/sensitive_data.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_process.dart';

void main() {
  group('HostPlatform.fromAbi', () {
    test('maps desktop ABIs to OS and architecture', () {
      expect(
        HostPlatform.fromAbi(Abi.macosArm64),
        const HostPlatform(HostOs.macos, CpuArch.arm64),
      );
      expect(
        HostPlatform.fromAbi(Abi.linuxX64),
        const HostPlatform(HostOs.linux, CpuArch.x64),
      );
      expect(
        HostPlatform.fromAbi(Abi.windowsX64),
        const HostPlatform(HostOs.windows, CpuArch.x64),
      );
    });

    test('maps non-desktop ABIs to unsupported', () {
      final p = HostPlatform.fromAbi(Abi.androidArm64);
      expect(p.os, HostOs.other);
      expect(p.upstreamSupport, UpstreamSupport.unsupported);
    });

    test('only upstream CI runner pairs count as tested', () {
      expect(
        const HostPlatform(HostOs.macos, CpuArch.arm64).upstreamSupport,
        UpstreamSupport.ciTested,
      );
      expect(
        const HostPlatform(HostOs.macos, CpuArch.x64).upstreamSupport,
        UpstreamSupport.untested,
      );
      expect(
        const HostPlatform(HostOs.linux, CpuArch.arm64).upstreamSupport,
        UpstreamSupport.untested,
      );
    });

    test('uses platform executable names and separators', () {
      const win = HostPlatform(HostOs.windows, CpuArch.x64);
      expect(win.florestadFileName, 'florestad.exe');
      expect(win.pathListSeparator, ';');
      const mac = HostPlatform(HostOs.macos, CpuArch.arm64);
      expect(mac.florestadFileName, 'florestad');
      expect(mac.pathListSeparator, ':');
    });
  });

  group('SensitiveData.detectSecret', () {
    test('rejects extended private keys, alone or inside a descriptor', () {
      expect(SensitiveData.detectSecret(FakeKeys.xprv), isNotNull);
      expect(SensitiveData.detectSecret(FakeKeys.tprv), isNotNull);
      expect(
        SensitiveData.detectSecret('wpkh(${FakeKeys.xprv}/0/*)'),
        isNotNull,
      );
    });

    test('rejects WIF keys', () {
      expect(SensitiveData.detectSecret(FakeKeys.wifCompressed), isNotNull);
      expect(
        SensitiveData.detectSecret('wpkh(${FakeKeys.wifUncompressed})'),
        isNotNull,
      );
    });

    test('rejects seed-phrase shaped input', () {
      const words =
          'abandon ability able about above absent absorb abstract '
          'absurd abuse access accident';
      expect(SensitiveData.detectSecret(words), isNotNull);
    });

    test('accepts public descriptors', () {
      expect(
        SensitiveData.detectSecret(
          'wpkh([d34db33f/84h/0h/0h]${FakeKeys.xpub}/<0;1>/*)#abcdefgh',
        ),
        isNull,
      );
      expect(
        SensitiveData.detectSecret(
          'addr(bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq)',
        ),
        isNull,
      );
    });
  });

  group('SensitiveData.redact', () {
    test('masks extended public and private keys', () {
      final out = SensitiveData.redact(
        'Descriptor pushed: wpkh(${FakeKeys.xpub}/0/*) and ${FakeKeys.xprv}',
      );
      expect(out, isNot(contains(FakeKeys.xpub)));
      expect(out, isNot(contains(FakeKeys.xprv)));
      expect(out, contains('xpub…[redacted]'));
      expect(out, contains('Descriptor pushed: wpkh('));
    });

    test('leaves ordinary log text untouched', () {
      const line = 'INFO New tip height=12345 peers=8';
      expect(SensitiveData.redact(line), line);
    });
  });

  group('LogBuffer', () {
    test('drops the oldest lines beyond capacity', () {
      final buffer = LogBuffer(capacity: 3);
      for (var i = 0; i < 5; i++) {
        buffer.add(LogSource.stdout, 'line $i');
      }
      expect(buffer.lines.map((l) => l.text), ['line 2', 'line 3', 'line 4']);
    });

    test('redacts on insert', () {
      final buffer = LogBuffer();
      buffer.add(LogSource.stdout, FakeKeys.zpub);
      expect(buffer.lines.single.text, 'zpub…[redacted]');
    });
  });
}
