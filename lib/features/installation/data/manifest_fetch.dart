import 'dart:async';
import 'dart:io';

import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/net/safe_http_get.dart';
import 'signed_manifest.dart';

/// Downloads a signed manifest envelope (florestad's or the app's): https
/// (or loopback http), checked redirects, bounded size and time. The bytes
/// are verified by [SignedManifestVerifier] afterwards.
Future<Either<Failure, List<int>>> fetchSignedManifest(
  HttpClient Function() clientFactory,
  Uri manifestUrl, {
  Set<String> redirectHosts = const {},
}) async {
  if (!isAllowedDownloadUrl(manifestUrl)) {
    return Left(
      InstallationFailure(
        stage: 'resolve',
        message: 'Refusing insecure release URL $manifestUrl.',
      ),
    );
  }
  final client = clientFactory()
    ..connectionTimeout = const Duration(seconds: 15);
  try {
    final response = await openFollowingRedirects(
      client,
      manifestUrl,
      timeout: const Duration(seconds: 20),
      allowedHosts: redirectHosts,
    );
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return Left(
        InstallationFailure(
          stage: 'resolve',
          message: 'The release server answered HTTP ${response.statusCode}.',
          recovery: 'Try again later.',
        ),
      );
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 20))) {
      bytes.addAll(chunk);
      if (bytes.length > SignedManifestVerifier.maxEnvelopeBytes) {
        return const Left(InstallationFailure.manifest('too large'));
      }
    }
    return Right(bytes);
  } on RedirectRefused catch (e) {
    return Left(
      InstallationFailure(
        stage: 'resolve',
        message: 'The release server sent an unsafe redirect ($e).',
        recovery: 'Nothing was installed.',
      ),
    );
  } on Object catch (e) {
    return Left(
      InstallationFailure(
        stage: 'resolve',
        message: 'Could not reach the release server ($e).',
        recovery: 'Check your internet connection and try again.',
      ),
    );
  } finally {
    client.close(force: true);
  }
}
