import 'dart:async';
import 'dart:io';

import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/platform/app_paths.dart';
import '../../../core/platform/host_platform.dart';
import '../domain/installation.dart';
import '../domain/floresta_version.dart';
import '../domain/app_update.dart';
import '../domain/installer.dart';
import '../domain/release_manifest.dart';
import 'artifact_downloader.dart';
import 'managed_install_store.dart';
import 'manifest_fetch.dart';
import 'release_source.dart';
import 'release_trust_store.dart';
import 'signed_manifest.dart';
import 'version_probe.dart';

/// Marks a file executable (unix). Injected so tests and Windows can skip it.
typedef MakeExecutable = Future<bool> Function(String path);

/// The running system's version in the form artifacts record `minOs`:
/// `26.3.1` on macOS, `glibc 2.35` on Linux, `10.0.19045` on Windows. Null
/// when unknown.
typedef HostOsVersion = Future<String?> Function();

Future<String?> readHostOsVersion() async {
  if (Platform.isMacOS) {
    // "Version 26.3.1 (Build 25D771280a)".
    return RegExp(
      r'(\d+(?:\.\d+)+)',
    ).firstMatch(Platform.operatingSystemVersion)?.group(1);
  }
  if (Platform.isLinux) {
    try {
      final r = await Process.run('/usr/bin/getconf', [
        'GNU_LIBC_VERSION',
      ]).timeout(const Duration(seconds: 5));
      final out = '${r.stdout}'.trim();
      return r.exitCode == 0 && out.startsWith('glibc ') ? out : null;
    } on Object {
      return null;
    }
  }
  if (Platform.isWindows) {
    return windowsVersionFrom(Platform.operatingSystemVersion);
  }
  return null;
}

/// `"Windows 10 Pro" 10.0 (Build 19045)` (Dart's
/// `Platform.operatingSystemVersion`) as `10.0.19045`, the form Windows
/// artifacts record `minOs` in (Rust's MSVC target needs 10.0.10240).
String? windowsVersionFrom(String osVersion) {
  final m = RegExp(r'(\d+)\.(\d+) \(Build (\d+)\)').firstMatch(osVersion);
  return m == null ? null : '${m.group(1)}.${m.group(2)}.${m.group(3)}';
}

Future<bool> chmodExecutable(String path) async {
  if (Platform.isWindows) return true;
  final r = await Process.run('chmod', ['755', path]);
  return r.exitCode == 0;
}

/// Installs florestad from a signed release manifest into app-managed
/// storage. Never runs scripts, never asks for elevation, never touches the
/// chain data directory.
///
/// Order: resolve (fetch + verify manifest, pick artifact) → download
/// (resumable) → verify (size, SHA-256, `--version` equals the manifest) →
/// install (atomic move, record in `current.json`, keep previous version).
/// A crash at any point leaves the previous install usable.
class ManagedInstaller implements Installer {
  ManagedInstaller({
    required this.paths,
    required this.source,
    required this.downloader,
    required this.probe,
    required this.store,
    required this.trust,
    HttpClient Function()? clientFactory,
    MakeExecutable? makeExecutable,
    DateTime Function()? now,
    HostOsVersion? hostOsVersion,
  }) : verifier = SignedManifestVerifier(source.trustedKeys),
       _clientFactory = clientFactory ?? HttpClient.new,
       _makeExecutable = makeExecutable ?? chmodExecutable,
       _now = now ?? DateTime.now,
       _hostOsVersion = hostOsVersion ?? readHostOsVersion;

  final AppPaths paths;
  final ReleaseSource source;
  final SignedManifestVerifier verifier;
  final ArtifactDownloader downloader;
  final VersionProbe probe;
  final ManagedInstallStore store;
  final ReleaseTrustStore trust;
  final HttpClient Function() _clientFactory;
  final MakeExecutable _makeExecutable;
  final DateTime Function() _now;
  final HostOsVersion _hostOsVersion;

  Uri get manifestUrl => source.manifestUrl;

  CancelToken? _cancel;

  @override
  bool supports(HostPlatform platform) =>
      platform.upstreamSupport != UpstreamSupport.unsupported;

  /// Cancels a running install; a partial download is kept for resume.
  @override
  void cancel() => _cancel?.cancel();

  @override
  Stream<InstallProgress> install(HostPlatform platform) {
    final out = StreamController<InstallProgress>();
    final cancel = _cancel = CancelToken();
    Future<void> run() async {
      final result = await _run(platform, out.add, cancel);
      out.add(
        result.match(
          (f) => InstallFailed(
            f.message,
            recovery: f.recovery,
            stage: f is InstallationFailure
                ? InstallStage.fromName(f.stage)
                : null,
            cancelled: cancel.isCancelled,
          ),
          InstallCompleted.new,
        ),
      );
      await out.close();
    }

    unawaited(run());
    return out.stream;
  }

  Future<Either<Failure, String>> _run(
    HostPlatform platform,
    void Function(InstallProgress) emit,
    CancelToken cancel,
  ) async {
    emit(const InstallResolving());
    await recoverInterrupted();
    final resolved = await _resolve(platform);
    if (resolved case Left(:final value)) return Left(value);
    final (:release, :artifact, :seen) = resolved.getOrElse(
      (_) => throw StateError('unreachable'),
    );
    await trust.accept(
      current: seen,
      serial: release.serial,
      revokedKeys: release.revokedKeys,
    );
    final version = '${release.version}'.replaceFirst('v', '');

    // Already installed and intact: nothing to do.
    final current = (await store.read()).getOrElse((_) => null);
    if (current != null &&
        current.version == version &&
        current.sha256 == artifact.sha256 &&
        await store.isIntact(current)) {
      return Right(current.path);
    }

    emit(const InstallDownloading(0));
    final downloaded = await downloader.download(
      artifact,
      paths.staging,
      cancel: cancel,
      onProgress: (got, total) =>
          emit(InstallDownloading(got / total, received: got, total: total)),
      redirectHosts: source.redirectHosts,
    );
    if (downloaded case Left(:final value)) return Left(value);
    final part = downloaded.getOrElse((_) => throw StateError('unreachable'));

    emit(const InstallVerifying());
    final stagedDir = Directory(
      '${paths.staging.path}${Platform.pathSeparator}$version',
    );
    if (await stagedDir.exists()) await stagedDir.delete(recursive: true);
    await stagedDir.create(recursive: true);
    final staged = await part.rename(
      '${stagedDir.path}${Platform.pathSeparator}${platform.florestadFileName}',
    );
    if (!await _makeExecutable(staged.path)) {
      return const Left(
        InstallationFailure(
          stage: 'install',
          message: 'Could not mark Floresta executable.',
        ),
      );
    }
    final probed = await probe.probe(staged.path);
    if (probed case Left(:final value)) {
      return Left(
        InstallationFailure(
          stage: 'verify',
          message:
              'The downloaded Floresta does not run on this computer '
              '(${value.message}).',
          recovery: value.recovery,
        ),
      );
    }
    final runningVersion = probed.getOrElse(
      (_) => throw StateError('unreachable'),
    );
    if (runningVersion.compareTo(release.version) != 0) {
      return Left(
        InstallationFailure(
          stage: 'verify',
          message:
              'The downloaded program reports $runningVersion, '
              'expected ${release.version}.',
        ),
      );
    }

    emit(const InstallInstalling());
    // One folder per build, not per version: master builds share a version
    // (0.9.0) across commits, and an update must never replace the folder
    // of the binary that may still be running, nor the rollback copy.
    final folder = '$version-${artifact.sha256.substring(0, 12)}';
    final target = paths.versionDir(folder);
    if (await target.exists()) await target.delete(recursive: true);
    await target.parent.create(recursive: true);
    await stagedDir.rename(target.path); // same volume: atomic
    final installedPath =
        '${target.path}${Platform.pathSeparator}${platform.florestadFileName}';
    final keepPrevious = current != null && current.sha256 != artifact.sha256
        ? current
        : current?.previous;
    await store.write(
      ManagedInstall(
        version: version,
        path: installedPath,
        sha256: artifact.sha256,
        upstreamRef: release.upstreamRef,
        previous: keepPrevious == null
            ? null
            : ManagedInstall(
                version: keepPrevious.version,
                path: keepPrevious.path,
                sha256: keepPrevious.sha256,
                upstreamRef: keepPrevious.upstreamRef,
              ),
      ),
    );
    await _pruneVersions(
      keep: {folder, if (keepPrevious != null) _folderOf(keepPrevious.path)},
    );
    return Right(installedPath);
  }

  /// Fetches and checks the signed manifest and picks this platform's
  /// build: signature, freshness, supported version, trusted download host
  /// and minimum OS. Records nothing.
  Future<
    Either<
      Failure,
      ({ReleaseManifest release, ReleaseArtifact artifact, ReleaseTrust seen})
    >
  >
  _resolve(HostPlatform platform) async {
    final manifestBytes = await _fetchManifest();
    if (manifestBytes case Left(:final value)) return Left(value);
    final trusted = await trust.read();
    if (trusted case Left(:final value)) return Left(value);
    final seen = trusted.getOrElse((_) => ReleaseTrustStore.initial);
    final manifest = verifier.verify(
      manifestBytes.getOrElse((_) => const []),
      manifestUrl,
      revokedKeys: seen.revokedKeys,
    );
    if (manifest case Left(:final value)) return Left(value);
    final release = manifest.getOrElse((_) => throw StateError('unreachable'));
    final fresh = release.checkFreshness(
      now: _now().toUtc(),
      highestAcceptedSerial: seen.highestSerial,
    );
    if (fresh case Left(:final value)) return Left(value);
    if (!release.version.isSupported) {
      return Left(
        InstallationFailure(
          stage: 'resolve',
          message:
              'The published Floresta ${release.version} is older than '
              'this app supports.',
        ),
      );
    }
    final artifactE = release.artifactFor(platform);
    if (artifactE case Left(:final value)) return Left(value);
    final artifact = artifactE.getOrElse(
      (_) => throw StateError('unreachable'),
    );
    // INS-09: a relative URL resolves against the manifest; either way the
    // artifact must come from the manifest's host or an allowlisted one.
    if (!isAllowedRedirect(manifestUrl, artifact.url, source.redirectHosts)) {
      return Left(
        InstallationFailure(
          stage: 'resolve',
          message:
              'The release information points to a download location this '
              'app does not trust (${artifact.url.host}).',
          recovery: 'Nothing was installed. Try again later.',
        ),
      );
    }
    final host = await _hostOsVersion();
    if (satisfiesMinOs(artifact.minOs, host) == false) {
      return Left(
        InstallationFailure(
          stage: 'resolve',
          message:
              'Floresta ${release.version} needs '
              '${platform.os.label} ${artifact.minOs} or newer; this '
              'computer has $host.',
          recovery:
              'Nothing was installed. Update your system, or choose an '
              'existing florestad executable built for it.',
        ),
      );
    }
    return Right((release: release, artifact: artifact, seen: seen));
  }

  @override
  Future<Either<Failure, FlorestadUpdateOffer?>> checkForUpdate(
    HostPlatform platform,
  ) async {
    final current = (await store.read()).getOrElse((_) => null);
    if (current == null) return const Right(null);
    final resolved = await _resolve(platform);
    return resolved.map((r) {
      if (r.artifact.sha256 == current.sha256) return null;
      final running = FlorestaVersion.tryParse('v${current.version}');
      return FlorestadUpdateOffer(
        label: florestaVersionLabel(r.release.version, r.release.upstreamRef),
        currentLabel: running == null
            ? current.version
            : florestaVersionLabel(running, current.upstreamRef),
        sha256: r.artifact.sha256,
      );
    });
  }

  Future<Either<Failure, List<int>>> _fetchManifest() => fetchSignedManifest(
    _clientFactory,
    manifestUrl,
    redirectHosts: source.redirectHosts,
  );

  /// Cleans leftovers of an interrupted install. Resumable `.part`
  /// downloads are kept; staged directories and temp records are removed.
  Future<void> recoverInterrupted() async {
    final staging = paths.staging;
    if (await staging.exists()) {
      await for (final e in staging.list()) {
        if (e is Directory) await e.delete(recursive: true);
      }
    }
    final tmp = File('${paths.currentPointer.path}.tmp');
    if (await tmp.exists()) await tmp.delete();
  }

  /// The `versions/<folder>` an installed binary lives in. Installs made
  /// before 2026-11-13 use the bare version as the folder name.
  String _folderOf(String binaryPath) =>
      File(binaryPath).parent.uri.pathSegments.where((s) => s.isNotEmpty).last;

  Future<void> _pruneVersions({required Set<String> keep}) async {
    if (!await paths.versions.exists()) return;
    await for (final e in paths.versions.list()) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (e is Directory && !keep.contains(name)) {
        await e.delete(recursive: true);
      }
    }
  }
}
