import 'dart:io';

import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/core/platform/host_platform.dart';
import 'package:floresta_gui/core/processes/process_starter.dart';
import 'package:floresta_gui/features/installation/data/executable_locator.dart';
import 'package:floresta_gui/features/installation/data/installation_repository_impl.dart';
import 'package:floresta_gui/features/installation/data/version_probe.dart';
import 'package:floresta_gui/features/installation/domain/floresta_version.dart';
import 'package:floresta_gui/features/installation/domain/installation.dart';
import 'package:floresta_gui/features/installation/domain/next_action.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';

import '../../helpers/fake_process.dart';

const _mac = HostPlatform(HostOs.macos, CpuArch.arm64);
const _win = HostPlatform(HostOs.windows, CpuArch.x64);

/// A starter whose process prints [stdout] and exits with [code].
ProcessStarter _printing(String stdout, {int code = 0}) => (exe, args) async {
  final p = FakeProcess();
  Future(() async {
    p.emitStdout(stdout);
    await p.exit(code);
  });
  return p;
};

void main() {
  group('FlorestaVersion', () {
    test('parses clap output for a release build', () {
      final v = FlorestaVersion.tryParse('florestad v0.9.1\n')!;
      expect(v, const FlorestaVersion(0, 9, 1));
      expect(v.isReleaseBuild, isTrue);
      expect(v.toString(), 'v0.9.1');
    });

    test('parses git-describe development builds', () {
      final v = FlorestaVersion.tryParse('florestad v0.9.1-14-g3a47993-dirty')!;
      expect(v.commitsSinceTag, 14);
      expect(v.commit, '3a47993');
      expect(v.dirty, isTrue);
      expect(v.isReleaseBuild, isFalse);
    });

    test('returns null when there is no version', () {
      expect(FlorestaVersion.tryParse('florestad'), isNull);
    });

    test('orders versions', () {
      const a = FlorestaVersion(0, 8, 1);
      const b = FlorestaVersion(0, 9, 0);
      const c = FlorestaVersion(0, 9, 0, commitsSinceTag: 3);
      const d = FlorestaVersion(1, 0, 0);
      expect([d, c, a, b]..sort(), [a, b, c, d]);
      expect(a < b, isTrue);
      expect(a.isSupported, isFalse);
      expect(b.isSupported, isTrue);
    });
  });

  group('ExecutableLocator', () {
    test('searches PATH first, then well-known macOS locations', () {
      final locator = ExecutableLocator(
        platform: _mac,
        environment: const {'PATH': '/usr/bin:/bin/', 'HOME': '/Users/a'},
      );
      expect(locator.candidates().map((c) => c.path), [
        '/usr/bin/florestad',
        '/bin/florestad',
        '/Users/a/.cargo/bin/florestad',
        '/opt/homebrew/bin/florestad',
        '/usr/local/bin/florestad',
      ]);
    });

    test('uses Windows names, separators and USERPROFILE', () {
      final locator = ExecutableLocator(
        platform: _win,
        environment: const {
          'Path': r'C:\tools;C:\bin\',
          'USERPROFILE': r'C:\Users\a',
        },
      );
      expect(locator.candidates().map((c) => c.path), [
        r'C:\tools\florestad.exe',
        r'C:\bin\florestad.exe',
        r'C:\Users\a\.cargo\bin\florestad.exe',
      ]);
    });

    test('deduplicates and finds the first executable', () async {
      final locator = ExecutableLocator(
        platform: _mac,
        environment: const {
          'PATH': '/Users/a/.cargo/bin:/usr/bin',
          'HOME': '/Users/a',
        },
        isExecutable: (p) async => p == '/Users/a/.cargo/bin/florestad',
      );
      final paths = locator.candidates().map((c) => c.path).toList();
      expect(paths.toSet().length, paths.length);
      final found = await locator.find();
      expect(found?.path, '/Users/a/.cargo/bin/florestad');
      expect(found?.source, ExecutableSource.path);
    });
  });

  group('VersionProbe', () {
    test('returns the parsed version', () async {
      final probe = VersionProbe(startProcess: _printing('florestad v0.9.1'));
      expect(
        await probe.probe('/x/florestad'),
        const Right(FlorestaVersion(0, 9, 1)),
      );
    });

    test('rejects programs that are not florestad', () async {
      final probe = VersionProbe(startProcess: _printing('floresta-cli 0.9.1'));
      final r = await probe.probe('/x/floresta-cli');
      expect(r.getLeft().toNullable(), isA<ExecutableInvalidFailure>());
    });

    test('reports non-zero exit codes', () async {
      final probe = VersionProbe(
        startProcess: _printing('florestad v0.9.1', code: 2),
      );
      final f = (await probe.probe('/x/florestad')).getLeft().toNullable();
      expect(f?.message, contains('code 2'));
    });

    test('maps permission errors with a recovery hint', () async {
      final probe = VersionProbe(
        startProcess: (exe, args) async =>
            throw const ProcessException('florestad', [], 'denied', 13),
      );
      final f = (await probe.probe('/x/florestad')).getLeft().toNullable();
      expect(f?.recovery, contains('chmod +x'));
    });

    test('kills a program that hangs', () async {
      final process = FakeProcess(onSignal: (_) => -9);
      final probe = VersionProbe(
        startProcess: (exe, args) async => process,
        timeout: const Duration(milliseconds: 20),
      );
      final f = (await probe.probe('/x/sleep')).getLeft().toNullable();
      expect(f?.message, contains('did not answer'));
      expect(process.signals, [ProcessSignal.sigkill]);
    });
  });

  group('InstallationRepositoryImpl', () {
    InstallationRepositoryImpl repo({
      required Set<String> executables,
      ProcessStarter? starter,
    }) => InstallationRepositoryImpl(
      locator: ExecutableLocator(
        platform: _mac,
        environment: const {'PATH': '/usr/bin', 'HOME': '/Users/a'},
        isExecutable: (p) async => executables.contains(p),
      ),
      probe: VersionProbe(
        startProcess: starter ?? _printing('florestad v0.9.1'),
      ),
    );

    test('reports every searched path when nothing is found', () async {
      final r = await repo(executables: {}).detect();
      final f = r.getLeft().toNullable();
      expect(f, isA<ExecutableNotFoundFailure>());
      expect(
        (f! as ExecutableNotFoundFailure).searchedPaths,
        contains('/Users/a/.cargo/bin/florestad'),
      );
    });

    test('detects and probes a discovered executable', () async {
      final r = await repo(
        executables: {'/Users/a/.cargo/bin/florestad'},
      ).detect();
      final install = r.toNullable()!;
      expect(install.executablePath, '/Users/a/.cargo/bin/florestad');
      expect(install.source, ExecutableSource.wellKnown);
      expect(install.version, const FlorestaVersion(0, 9, 1));
    });

    test('never falls back when a configured path is unusable', () async {
      final r = await repo(
        executables: {'/usr/bin/florestad'},
      ).detect(configuredPath: '/opt/missing/florestad');
      expect(r.getLeft().toNullable(), isA<ExecutableInvalidFailure>());
    });

    test('uses a configured path when it works', () async {
      final r = await repo(
        executables: {'/opt/f/florestad'},
      ).detect(configuredPath: '/opt/f/florestad');
      expect(r.toNullable()?.source, ExecutableSource.configured);
    });
  });

  group('NextAction.resolve', () {
    const install = FlorestaInstallation(
      executablePath: '/x/florestad',
      source: ExecutableSource.path,
      version: FlorestaVersion(0, 9, 1),
    );

    test('asks to install when nothing was found', () {
      expect(
        NextAction.resolve(
          const Left(ExecutableNotFoundFailure([])),
          onboardingComplete: false,
        ),
        isA<InstallFloresta>(),
      );
    });

    test('asks to fix an invalid executable', () {
      expect(
        NextAction.resolve(
          const Left(ExecutableInvalidFailure('/x', 'bad')),
          onboardingComplete: true,
        ),
        isA<FixInstallation>(),
      );
    });

    test('asks to configure before onboarding, then opens the node', () {
      expect(
        NextAction.resolve(const Right(install), onboardingComplete: false),
        isA<ConfigureNode>(),
      );
      expect(
        NextAction.resolve(const Right(install), onboardingComplete: true),
        isA<OpenNodeManagement>(),
      );
    });

    test('recommends an update for old versions', () {
      const old = FlorestaInstallation(
        executablePath: '/x',
        source: ExecutableSource.path,
        version: FlorestaVersion(0, 8, 1),
      );
      expect(
        NextAction.resolve(const Right(old), onboardingComplete: true),
        isA<UpdateFloresta>(),
      );
    });
  });
}
