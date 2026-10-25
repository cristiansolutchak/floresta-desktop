import 'dart:async';
import 'dart:io';

import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/security/file_hash.dart';
import '../domain/release_manifest.dart';

/// Cooperative cancellation for long downloads.
class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

bool isLoopbackUrl(Uri url) =>
    url.host == '127.0.0.1' || url.host == 'localhost' || url.host == '::1';

/// Only HTTPS, except plain HTTP to the loopback interface (local artifact
/// servers in tests and development).
bool isAllowedDownloadUrl(Uri url) =>
    url.scheme == 'https' || (url.scheme == 'http' && isLoopbackUrl(url));

/// Whether a redirect from [from] to [to] may be followed: never to a
/// weaker scheme, and only to the same host or an allowlisted HTTPS host.
bool isAllowedRedirect(Uri from, Uri to, Set<String> allowedHosts) {
  if (!isAllowedDownloadUrl(to)) return false;
  if (from.scheme == 'https' && to.scheme != 'https') return false;
  if (to.host == from.host) return true;
  return to.scheme == 'https' && allowedHosts.contains(to.host.toLowerCase());
}

class RedirectRefused implements Exception {
  const RedirectRefused(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

const maxRedirects = 3;

/// GETs [url], following at most [maxRedirects] redirects by hand so each
/// hop is checked with [isAllowedRedirect]. [prepare] runs on every hop's
/// request (e.g. to resend a Range header). Throws [RedirectRefused].
Future<HttpClientResponse> openFollowingRedirects(
  HttpClient client,
  Uri url, {
  required Duration timeout,
  Set<String> allowedHosts = const {},
  void Function(HttpClientRequest request)? prepare,
}) async {
  var current = url;
  for (var hop = 0; ; hop++) {
    final request = await client.getUrl(current);
    request.followRedirects = false;
    prepare?.call(request);
    final response = await request.close().timeout(timeout);
    if (!response.isRedirect) return response;
    final location = response.headers.value(HttpHeaders.locationHeader);
    await response.drain<void>();
    if (location == null) {
      throw const RedirectRefused('redirect without a location');
    }
    final next = current.resolve(location);
    if (hop >= maxRedirects) throw const RedirectRefused('too many redirects');
    if (!isAllowedRedirect(current, next, allowedHosts)) {
      throw RedirectRefused(
        'refused redirect to ${next.scheme}://${next.host}',
      );
    }
    current = next;
  }
}

/// Downloads one artifact into [stagingDir] as `<sha256>.part`, resuming a
/// previous partial download with an HTTP Range request. Succeeds only when
/// the file has exactly the expected size and SHA-256.
class ArtifactDownloader {
  ArtifactDownloader({
    HttpClient Function()? clientFactory,
    this.maxAttempts = 3,
    this.idleTimeout = const Duration(seconds: 30),
    this.retryDelay = const Duration(seconds: 2),
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;
  final int maxAttempts;
  final Duration idleTimeout;
  final Duration retryDelay;

  File partFile(Directory stagingDir, ReleaseArtifact a) =>
      File('${stagingDir.path}${Platform.pathSeparator}${a.sha256}.part');

  Future<Either<Failure, File>> download(
    ReleaseArtifact artifact,
    Directory stagingDir, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancel,
    Set<String> redirectHosts = const {},
  }) async {
    if (!isAllowedDownloadUrl(artifact.url)) {
      return Left(_fail('download', 'Refusing insecure URL ${artifact.url}.'));
    }
    await stagingDir.create(recursive: true);
    final part = partFile(stagingDir, artifact);
    Failure? last;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (cancel?.isCancelled ?? false) return Left(_cancelled());
      final error = await _attempt(
        artifact,
        part,
        onProgress,
        cancel,
        redirectHosts,
      );
      if (error == null) return _verify(artifact, part);
      last = error.failure;
      if (error.fatal || (cancel?.isCancelled ?? false)) {
        return Left(error.failure);
      }
      if (attempt < maxAttempts) {
        await Future<void>.delayed(retryDelay * attempt);
      }
    }
    return Left(last!);
  }

  /// Null on success; otherwise the failure and whether retrying is useless.
  Future<({Failure failure, bool fatal})?> _attempt(
    ReleaseArtifact a,
    File part,
    void Function(int, int)? onProgress,
    CancelToken? cancel,
    Set<String> redirectHosts,
  ) async {
    var have = await part.exists() ? await part.length() : 0;
    if (have > a.size) {
      await part.delete();
      have = 0;
    }
    if (have == a.size) return null;

    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 15);
    IOSink? sink;
    try {
      final response = await openFollowingRedirects(
        client,
        a.url,
        timeout: idleTimeout,
        allowedHosts: redirectHosts,
        prepare: (request) {
          if (have > 0) {
            request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
          }
        },
      );
      final append =
          response.statusCode == HttpStatus.partialContent && have > 0;
      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        await response.drain<void>();
        await part.delete();
        return (
          failure: _fail('download', 'Server rejected resume; restarting.'),
          fatal: false,
        );
      }
      if (response.statusCode != HttpStatus.ok && !append) {
        await response.drain<void>();
        final fatal =
            response.statusCode == HttpStatus.notFound ||
            response.statusCode == HttpStatus.forbidden;
        final f = _fail(
          'download',
          'Server answered HTTP ${response.statusCode}.',
        );
        return (failure: f, fatal: fatal);
      }
      var received = append ? have : 0;
      final out = part.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      sink = out;
      await for (final chunk in response.timeout(idleTimeout)) {
        if (cancel?.isCancelled ?? false) {
          return (failure: _cancelled(), fatal: true);
        }
        received += chunk.length;
        if (received > a.size) {
          await out.close();
          sink = null;
          await part.delete();
          return (
            failure: _fail('verify', 'The download is larger than expected.'),
            fatal: true,
          );
        }
        out.add(chunk);
        onProgress?.call(received, a.size);
        if (cancel?.isCancelled ?? false) {
          return (failure: _cancelled(), fatal: true);
        }
      }
      await out.close();
      sink = null;
      return received == a.size
          ? null
          : (
              failure: _fail(
                'download',
                'Connection ended early ($received of ${a.size} bytes).',
              ),
              fatal: false,
            );
    } on RedirectRefused catch (e) {
      return (
        failure: _fail(
          'download',
          'The download server sent an unsafe redirect ($e).',
          recovery:
              'Nothing was installed. The download source may be '
              'misconfigured or tampered with.',
        ),
        fatal: true,
      );
    } on TimeoutException {
      return (
        failure: _fail('download', 'The download stalled.'),
        fatal: false,
      );
    } on SocketException catch (e) {
      return (
        failure: _fail('download', 'Network error: ${e.message}.'),
        fatal: false,
      );
    } on HandshakeException catch (e) {
      return (
        failure: _fail('download', 'Secure connection failed: ${e.message}.'),
        fatal: true,
      );
    } on HttpException catch (e) {
      return (
        failure: _fail('download', 'HTTP error: ${e.message}.'),
        fatal: false,
      );
    } finally {
      await sink?.close();
      client.close(force: true);
    }
  }

  Future<Either<Failure, File>> _verify(ReleaseArtifact a, File part) async {
    final length = await part.length();
    final digest = await sha256OfFile(part.path);
    if (length != a.size || digest != a.sha256) {
      await part.delete(); // never resume from bytes that failed verification
      return Left(
        _fail(
          'verify',
          'The downloaded file does not match the published checksum.',
          recovery:
              'Nothing was installed. Try again; if this repeats, the '
              'download source may be compromised.',
        ),
      );
    }
    return Right(part);
  }

  static InstallationFailure _fail(
    String stage,
    String message, {
    String? recovery,
  }) => InstallationFailure(
    stage: stage,
    message: message,
    recovery:
        recovery ??
        'Check your internet connection and try again. '
            'The download resumes where it stopped.',
  );

  static InstallationFailure _cancelled() => const InstallationFailure(
    stage: 'download',
    message: 'The download was cancelled.',
    recovery: 'Start it again to resume.',
  );
}
