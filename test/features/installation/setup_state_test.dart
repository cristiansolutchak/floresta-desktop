import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/features/installation/domain/floresta_version.dart';
import 'package:floresta_gui/features/installation/domain/installation.dart';
import 'package:floresta_gui/features/installation/domain/installer.dart';
import 'package:floresta_gui/features/installation/domain/setup_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';

const _found = FlorestaInstallation(
  executablePath: '/data/floresta/versions/0.9.1/florestad',
  source: ExecutableSource.managed,
  version: FlorestaVersion(0, 9, 1),
);

const Either<Failure, FlorestaInstallation> _missing = Left(
  ExecutableNotFoundFailure(['/usr/bin/florestad']),
);

SetupState _resolve({
  Either<Failure, FlorestaInstallation>? detection = _missing,
  bool installing = false,
  InstallProgress? lastInstall,
  bool automaticInstall = true,
  bool onboardingComplete = false,
  bool useExistingNode = false,
  bool nodeActive = false,
  bool nodeAnswering = false,
}) => SetupState.resolve(
  detection: detection,
  installing: installing,
  lastInstall: lastInstall,
  automaticInstall: automaticInstall,
  onboardingComplete: onboardingComplete,
  useExistingNode: useExistingNode,
  nodeActive: nodeActive,
  nodeAnswering: nodeAnswering,
);

void main() {
  group('SetupState.resolve', () {
    test('detection running: checking, not "not installed"', () {
      expect(_resolve(detection: null), isA<SetupChecking>());
    });

    test('nothing found: install offered only when the build can', () {
      expect(_resolve(), const TypeMatcher<NotInstalled>());
      expect((_resolve() as NotInstalled).automaticInstall, isTrue);
      expect(
        (_resolve(automaticInstall: false) as NotInstalled).automaticInstall,
        isFalse,
      );
    });

    test('an install in progress wins over the last detection', () {
      final s = _resolve(
        installing: true,
        lastInstall: const InstallDownloading(0.4),
        detection: const Right(_found),
      );
      expect(s, isA<Installing>());
      expect((s as Installing).progress, const InstallDownloading(0.4));
    });

    test('a failed install shows only while nothing usable is found', () {
      const failed = InstallFailed('Signature check failed.');
      expect(_resolve(lastInstall: failed), isA<InstallFailedState>());
      // A florestad found elsewhere (PATH) makes the old failure moot.
      expect(
        _resolve(lastInstall: failed, detection: const Right(_found)),
        isA<ConfigurationRequired>(),
      );
    });

    // The bug of 2026-10-28: installed, but the install panel (which only
    // knew this session's run) still offered an install.
    test('installed after a restart (no run): never "not installed"', () {
      final s = _resolve(detection: const Right(_found));
      expect(s, isA<ConfigurationRequired>());
      expect(s.usable, isTrue);
      expect(s.installation, _found);
    });

    test('installed and set up: ready to start, then running', () {
      expect(
        _resolve(detection: const Right(_found), onboardingComplete: true),
        isA<ReadyToStart>(),
      );
      expect(
        _resolve(
          detection: const Right(_found),
          onboardingComplete: true,
          nodeActive: true,
        ),
        isA<Running>(),
      );
      expect(
        _resolve(
          detection: const Right(_found),
          onboardingComplete: true,
          nodeAnswering: true,
        ),
        isA<Running>(),
      );
    });

    test('a broken executable is unusable, not missing', () {
      final s = _resolve(
        detection: const Left(
          ExecutableInvalidFailure('/x/florestad', 'Exited with code 1.'),
        ),
      );
      expect(s, isA<Unusable>());
      expect(s.usable, isFalse);
    });

    test('a node elsewhere needs no executable', () {
      final s = _resolve(useExistingNode: true, onboardingComplete: true);
      expect(s, isA<ExistingNode>());
      expect(s.usable, isTrue);
      expect(
        _resolve(
          useExistingNode: true,
          onboardingComplete: true,
          nodeAnswering: true,
        ).label,
        'Connected to your node',
      );
      expect(s.label, 'Your node is not answering');
    });

    test('labels are distinct and "ready" never means synced', () {
      final labels = {
        _resolve(detection: null).label,
        _resolve().label,
        _resolve(installing: true).label,
        _resolve(detection: const Right(_found)).label,
        _resolve(
          detection: const Right(_found),
          onboardingComplete: true,
        ).label,
        _resolve(
          detection: const Right(_found),
          onboardingComplete: true,
          nodeActive: true,
        ).label,
      };
      expect(labels, hasLength(6));
      expect(labels.any((l) => l.toLowerCase().contains('synced')), isFalse);
    });
  });
}
