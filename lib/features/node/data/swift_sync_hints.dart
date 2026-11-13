import 'dart:async';
import 'dart:io';

import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/net/safe_http_get.dart';
import '../../settings/domain/node_settings.dart';
import '../domain/swift_sync.dart';

/// What [SwiftSyncHints.prepare] did before a start.
sealed class HintsOutcome {
  const HintsOutcome();
}

/// `<network>.hints` is in place with this stop height.
final class HintsReady extends HintsOutcome {
  const HintsReady(this.stopHeight, {required this.downloaded});
  final int stopHeight;
  final bool downloaded;
}

/// Swift Sync is off or the network has no hints; nothing is in the way.
final class HintsNotUsed extends HintsOutcome {
  const HintsNotUsed();
}

/// The data folder already holds a chain without hints, so florestad would
/// skip Swift Sync; nothing was downloaded.
final class HintsExistingChain extends HintsOutcome {
  const HintsExistingChain();
}

/// Bytes received so far; there is no total (the server sends no length).
typedef HintsProgress = void Function(int received);

/// Puts the Swift Sync hints file where florestad looks for it, or parks
/// it when Swift Sync is off. Mirrors floresta-desktop `src/node.rs`
/// `prepare_hints` / `download_hints` (2026-10-16):
/// - download only for networks with hints, and only when the file is
///   missing; into a temporary file in the same folder, then renamed, so a
///   failed download never leaves a partial `.hints`;
/// - off: rename `<network>.hints` to `<network>.hints.disabled`, and back
///   when it is turned on again; refuse when both exist.
///
/// Additions here: nothing is downloaded for a folder that already has a
/// chain (florestad would skip Swift Sync), the body must start with the
/// hints header, and its size is capped. The server publishes no checksum
/// or signature (2026-11-13), so bad hints are caught by florestad itself,
/// which then validates from scratch: slower, not unsafe.
class SwiftSyncHints {
  SwiftSyncHints({
    required this.homeDir,
    HttpClient Function()? clientFactory,
    this.idleTimeout = const Duration(seconds: 60),
    this.maxBytes = 1 << 30,
    String? separator,
  }) : _clientFactory = clientFactory ?? HttpClient.new,
       _sep = separator ?? Platform.pathSeparator;

  final String? homeDir;
  final HttpClient Function() _clientFactory;
  final Duration idleTimeout;

  /// Mainnet hints were 122.5 MB on 2026-11-13; anything near this cap is
  /// not a hints file.
  final int maxBytes;
  final String _sep;

  String _folder(NodeSettings s) =>
      s.effectiveDataDir(homeDir: homeDir, separator: _sep);

  File hintsFile(NodeSettings s) =>
      File('${_folder(s)}$_sep${hintsFileName(s.network)}');

  File parkedFile(NodeSettings s) =>
      File('${_folder(s)}$_sep${parkedHintsFileName(s.network)}');

  Future<Either<Failure, HintsOutcome>> prepare(
    NodeSettings settings, {
    HintsProgress? onProgress,
  }) async {
    try {
      return settings.syncMethod == SyncMethod.swiftSync
          ? await _use(settings, onProgress)
          : await _park(settings);
    } on FileSystemException catch (e) {
      return Left(
        SwiftSyncHintsFailure(
          'The hints file could not be written in the data folder '
          '(${e.osError?.message ?? e.message}).',
          recovery:
              'Check that the data folder is writable, or turn Swift Sync '
              'off in Settings.',
        ),
      );
    }
  }

  Future<Either<Failure, HintsOutcome>> _park(NodeSettings s) async {
    final hints = hintsFile(s);
    if (!await hints.exists()) return const Right(HintsNotUsed());
    final parked = parkedFile(s);
    if (await parked.exists()) {
      return Left(
        SwiftSyncHintsFailure(
          'Swift Sync is off, but both ${hints.path} and ${parked.path} '
          'exist, so the app cannot set the hints aside.',
          recovery:
              'Remove one of the two files, or turn Swift Sync on in '
              'Settings.',
        ),
      );
    }
    await hints.rename(parked.path);
    return const Right(HintsNotUsed());
  }

  Future<Either<Failure, HintsOutcome>> _use(
    NodeSettings s,
    HintsProgress? onProgress,
  ) async {
    final hints = hintsFile(s);
    final parked = parkedFile(s);
    if (!await hints.exists() && await parked.exists()) {
      await parked.rename(hints.path);
    }
    if (await hints.exists()) {
      final stop = await _stopHeightOf(hints);
      if (stop == null) {
        return Left(
          SwiftSyncHintsFailure(
            '${hints.path} is not a Swift Sync hints file.',
            recovery:
                'Remove the file so the app downloads it again, or turn '
                'Swift Sync off in Settings.',
          ),
        );
      }
      return Right(HintsReady(stop, downloaded: false));
    }
    if (await Directory('${_folder(s)}${_sep}chaindata').exists()) {
      return const Right(HintsExistingChain());
    }
    final url = hintsUrl(s.hintsOrigin, s.network);
    if (url == null) return const Right(HintsNotUsed());
    return _download(url, hints, onProgress);
  }

  Future<int?> _stopHeightOf(File f) async {
    final raf = await f.open();
    try {
      return HintsHeader.stopHeight(await raf.read(HintsHeader.length));
    } finally {
      await raf.close();
    }
  }

  Future<Either<Failure, HintsOutcome>> _download(
    Uri url,
    File target,
    HintsProgress? onProgress,
  ) async {
    if (!isAllowedDownloadUrl(url)) {
      return Left(
        SwiftSyncHintsFailure(
          'Refusing to download hints from $url: only https is allowed.',
          recovery: 'Use the default address, $defaultHintsOrigin.',
        ),
      );
    }
    await target.parent.create(recursive: true);
    final part = File('${target.path}.part');
    if (await part.exists()) await part.delete();
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 15);
    IOSink? sink;
    try {
      final response = await openFollowingRedirects(
        client,
        url,
        timeout: idleTimeout,
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return Left(
          _downloadFailure(
            url,
            'the server answered HTTP '
            '${response.statusCode}',
          ),
        );
      }
      final head = <int>[];
      var received = 0;
      final out = sink = part.openWrite();
      await for (final chunk in response.timeout(idleTimeout)) {
        received += chunk.length;
        if (head.length < HintsHeader.length) {
          head.addAll(chunk.take(HintsHeader.length - head.length));
          if (!HintsHeader.plausiblePrefix(head)) {
            return Left(_notHints(url));
          }
        }
        if (received > maxBytes) {
          return Left(_downloadFailure(url, 'the file is far too large'));
        }
        out.add(chunk);
        onProgress?.call(received);
      }
      await out.close();
      sink = null;
      final stop = HintsHeader.stopHeight(head);
      if (stop == null || stop == 0) return Left(_notHints(url));
      await part.rename(target.path);
      return Right(HintsReady(stop, downloaded: true));
    } on RedirectRefused catch (e) {
      return Left(_downloadFailure(url, 'unsafe redirect ($e)'));
    } on TimeoutException {
      return Left(_downloadFailure(url, 'the download stalled'));
    } on SocketException catch (e) {
      return Left(_downloadFailure(url, 'network error: ${e.message}'));
    } on HandshakeException catch (e) {
      return Left(
        _downloadFailure(url, 'secure connection failed: ${e.message}'),
      );
    } on HttpException catch (e) {
      return Left(_downloadFailure(url, 'HTTP error: ${e.message}'));
    } finally {
      await sink?.close();
      client.close(force: true);
      if (await part.exists()) await part.delete();
    }
  }

  Failure _notHints(Uri url) => SwiftSyncHintsFailure(
    '$url did not send a Swift Sync hints file.',
    recovery:
        'Check the hints address in Settings, or turn Swift Sync off. The '
        'node was not started.',
  );

  Failure _downloadFailure(Uri url, String why) => SwiftSyncHintsFailure(
    'Could not download the Swift Sync hints from $url: $why.',
    recovery:
        'Start again to retry, or turn Swift Sync off in Settings to sync '
        'another way. The node was not started.',
  );
}
