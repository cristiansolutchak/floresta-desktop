import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/processes/process_starter.dart';
import '../domain/floresta_version.dart';

/// Runs `<executable> --version` and parses the result.
///
/// Uses `Process.start` instead of `Process.run` so a binary that hangs (for
/// example a wrong file that waits on stdin) can be killed after [timeout].
class VersionProbe {
  VersionProbe({
    ProcessStarter? startProcess,
    this.timeout = const Duration(seconds: 5),
  }) : _start = startProcess ?? startSystemProcess;

  final ProcessStarter _start;
  final Duration timeout;

  Future<Either<Failure, FlorestaVersion>> probe(String executable) async {
    final Process process;
    try {
      process = await _start(executable, const ['--version']);
    } on ProcessException catch (e) {
      return Left(
        ExecutableInvalidFailure(
          executable,
          'The file could not be executed: ${e.message}',
          recovery: _recoveryFor(e),
        ),
      );
    }

    // Close stdin so a program that reads it cannot block forever.
    unawaited(process.stdin.close().catchError((_) {}));
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();

    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      return Left(
        ExecutableInvalidFailure(
          executable,
          'The program did not answer "--version" within '
          '${timeout.inSeconds} seconds.',
          recovery: 'Make sure this file is florestad and not another program.',
        ),
      );
    }

    final out = await stdout;
    final err = await stderr;
    if (exitCode != 0) {
      return Left(
        ExecutableInvalidFailure(
          executable,
          'Running "--version" exited with code $exitCode. ${err.trim()}'
              .trim(),
        ),
      );
    }
    if (!out.contains('florestad')) {
      return Left(
        ExecutableInvalidFailure(
          executable,
          'This program does not identify itself as florestad.',
          recovery:
              'Choose the florestad executable, not floresta-cli or '
              'another tool.',
        ),
      );
    }
    final version = FlorestaVersion.tryParse(out);
    if (version == null) {
      return Left(
        ExecutableInvalidFailure(
          executable,
          'Could not read a version from: "${out.trim()}"',
        ),
      );
    }
    return Right(version);
  }

  String? _recoveryFor(ProcessException e) {
    // macOS Gatekeeper and missing execute bits both surface as errno 13.
    if (e.errorCode == 13) {
      return 'The file is not executable. If you built it yourself, run '
          '"chmod +x" on it; on macOS also check System Settings → Privacy '
          '& Security.';
    }
    return 'Check that the file exists and was built for this computer.';
  }
}
