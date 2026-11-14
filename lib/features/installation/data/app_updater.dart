import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/platform/app_paths.dart';
import '../../../core/platform/host_platform.dart';
import '../domain/app_update.dart';
import '../domain/release_manifest.dart';
import 'artifact_downloader.dart';
import 'manifest_fetch.dart';
import 'release_source.dart';
import 'release_trust_store.dart';
import 'signed_manifest.dart';

/// Runs a system tool (absolute path, no shell) and returns its result.
typedef ToolRunner =
    Future<ProcessResult> Function(String executable, List<String> args);

/// Starts a process that outlives the app (the swap helper, a relaunch).
typedef DetachedStarter =
    Future<void> Function(String executable, List<String> args);

Future<ProcessResult> _runTool(String exe, List<String> args) => Process.run(
  exe,
  args,
  runInShell: false,
).timeout(const Duration(minutes: 2));

Future<void> _startDetachedProcess(String exe, List<String> args) async {
  await Process.start(
    exe,
    args,
    runInShell: false,
    mode: ProcessStartMode.detached,
  );
}

/// A verified update, unpacked and ready.
class StagedUpdate {
  const StagedUpdate({
    required this.version,
    required this.path,
    required this.format,
  });

  final AppVersion version;

  /// The new bundle (macOS `.app`, Linux bundle folder), unpacked in a
  /// hidden folder next to the installed one so the swap is a rename on
  /// the same volume; or the downloaded `.deb`.
  final String path;
  final AppPackageFormat format;
}

/// What the swap helper reported after the last update.
class SwapResult {
  const SwapResult({
    required this.ok,
    required this.version,
    this.reason,
    this.backup,
  });

  final bool ok;
  final String version;
  final String? reason;

  /// The replaced bundle, kept until the new version has started.
  final String? backup;
}

/// Updates the app itself.
///
/// 1. **Check:** fetch the app manifest, verify its Ed25519 signature with
///    the same trusted keys as florestad's, its type, expiry and serial
///    (its own anti-rollback record), and compare versions.
/// 2. **Download:** resumable, size and SHA-256 checked before use.
/// 3. **Unpack and check:** macOS: `ditto`, then the bundle id must match
///    the running app's, the version the manifest's, and `codesign
///    --verify --deep --strict` must pass. Linux tarball: `tar`, then the
///    bundle's `VERSION` file must say the manifest's version. `.deb`:
///    `dpkg-deb` must report package `floresta-desktop` at that version.
/// 4. **Swap:** a small shell script written by this app (never a
///    downloaded one) waits until the app has quit, renames the installed
///    bundle aside, renames the new one into place, and puts the old one
///    back if that fails. Settings, wallet data and chain data live
///    outside the bundle and are never touched.
class AppUpdater {
  AppUpdater({
    required this.paths,
    required this.source,
    required this.platform,
    ArtifactDownloader? downloader,
    HttpClient Function()? clientFactory,
    ToolRunner? run,
    DetachedStarter? startDetached,
    DateTime Function()? now,
  }) : verifier = SignedManifestVerifier(source.trustedKeys),
       trust = ReleaseTrustStore(paths, record: paths.appTrustRecord),
       _downloader = downloader ?? ArtifactDownloader(),
       _clientFactory = clientFactory ?? HttpClient.new,
       _run = run ?? _runTool,
       _startDetached = startDetached ?? _startDetachedProcess,
       _now = now ?? DateTime.now;

  final AppPaths paths;
  final ReleaseSource source;
  final HostPlatform platform;
  final SignedManifestVerifier verifier;
  final ReleaseTrustStore trust;
  final ArtifactDownloader _downloader;
  final HttpClient Function() _clientFactory;
  final ToolRunner _run;
  final DetachedStarter _startDetached;
  final DateTime Function() _now;

  static const bundleId = 'io.github.cristiansolutchak.florestaDesktop';
  static const _debPackage = 'floresta-desktop';

  String get _sep => Platform.pathSeparator;
  File get resultFile => File('${paths.updates.path}${_sep}result.json');
  File get _relaunchFlag =>
      File('${paths.updates.path}${_sep}relaunch-requested');
  File get _pendingFlag => File('${paths.updates.path}${_sep}swap-pending');

  /// A newer app release, or null when this one is current.
  Future<Either<Failure, AppUpdateOffer?>> check({
    required AppVersion current,
    required AppInstallKind kind,
  }) async {
    final url = source.appManifestUrl;
    final bytes = await fetchSignedManifest(
      _clientFactory,
      url,
      redirectHosts: source.redirectHosts,
    );
    if (bytes case Left(:final value)) return Left(value);
    final seenE = await trust.read();
    if (seenE case Left(:final value)) return Left(value);
    final seen = seenE.getOrElse((_) => ReleaseTrustStore.initial);
    final verified = verifier.verifyApp(
      bytes.getOrElse((_) => const []),
      url,
      revokedKeys: seen.revokedKeys,
    );
    if (verified case Left(:final value)) return Left(value);
    final manifest = verified.getOrElse((_) => throw StateError(''));
    final fresh = manifest.checkFreshness(
      now: _now().toUtc(),
      highestAcceptedSerial: seen.highestSerial,
    );
    if (fresh case Left(:final value)) return Left(value);
    // Verified and fresh: never accept an older one from now on.
    await trust.accept(
      current: seen,
      serial: manifest.serial,
      revokedKeys: manifest.revokedKeys,
    );
    if (!(manifest.version > current)) return const Right(null);
    final format = switch (kind) {
      SelfUpdatable(:final format) => format,
      SystemPackage() => AppPackageFormat.linuxDeb,
      NotUpdatable() => null,
    };
    final artifact = format == null
        ? null
        : manifest.artifactFor(platform, format);
    if (artifact != null &&
        !isAllowedRedirect(url, artifact.url, source.redirectHosts)) {
      return Left(
        InstallationFailure(
          stage: 'resolve',
          message:
              'The update points to a download location this app does not '
              'trust (${artifact.url.host}).',
        ),
      );
    }
    return Right(
      AppUpdateOffer(
        manifest: manifest,
        artifact: artifact,
        current: current,
        kind: kind,
      ),
    );
  }

  /// Downloads, verifies and unpacks [offer]'s package.
  Future<Either<Failure, StagedUpdate>> download(
    AppUpdateOffer offer, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancel,
  }) async {
    final artifact = offer.artifact;
    if (artifact == null) {
      return Left(
        InstallationFailure(
          stage: 'resolve',
          message:
              'Version ${offer.version} is not published for this kind of '
              'installation.',
        ),
      );
    }
    final downloads = Directory('${paths.updates.path}${_sep}downloads');
    final file = await _downloader.download(
      ReleaseArtifact(
        os: artifact.os,
        arch: artifact.arch ?? platform.arch,
        url: artifact.url,
        sha256: artifact.sha256,
        size: artifact.size,
        minOs: artifact.minOs,
      ),
      downloads,
      onProgress: onProgress,
      cancel: cancel,
      redirectHosts: source.redirectHosts,
    );
    if (file case Left(:final value)) return Left(value);
    final package = file.getOrElse((_) => throw StateError(''));
    try {
      return switch (offer.kind) {
        SelfUpdatable(:final bundlePath, :final format) => await _unpack(
          package,
          format,
          bundlePath,
          offer.version,
        ),
        SystemPackage() => await _checkDeb(package, offer.version),
        NotUpdatable(:final reason) => Left(
          InstallationFailure(stage: 'install', message: reason),
        ),
      };
    } on Object catch (e) {
      return Left(
        InstallationFailure(
          stage: 'verify',
          message: 'The update could not be unpacked ($e).',
          recovery: 'Nothing was changed. Try again later.',
        ),
      );
    }
  }

  Future<Either<Failure, StagedUpdate>> _unpack(
    File package,
    AppPackageFormat format,
    String bundlePath,
    AppVersion version,
  ) async {
    final parent = bundlePath.substring(0, bundlePath.lastIndexOf(_sep));
    final staging = Directory('$parent$_sep.floresta-update-$version');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create();
    Failure bad(String why) => InstallationFailure(
      stage: 'verify',
      message: 'The downloaded update failed its checks ($why).',
      recovery: 'Nothing was changed. Try again later.',
    );
    Future<Either<Failure, StagedUpdate>> fail(String why) async {
      await staging.delete(recursive: true);
      return Left(bad(why));
    }

    switch (format) {
      case AppPackageFormat.macosAppZip:
        final unzip = await _run('/usr/bin/ditto', [
          '-x',
          '-k',
          package.path,
          staging.path,
        ]);
        if (unzip.exitCode != 0) return fail('unzip: ${unzip.stderr}');
        final apps = staging
            .listSync()
            .whereType<Directory>()
            .where((d) => d.path.endsWith('.app'))
            .toList();
        if (apps.length != 1) return fail('expected one app bundle');
        final app = apps.single.path;
        final plist = '$app/Contents/Info.plist';
        final id = await _plist(plist, 'CFBundleIdentifier');
        final shortVersion = await _plist(plist, 'CFBundleShortVersionString');
        if (id != bundleId) return fail('bundle id $id');
        if (shortVersion != '$version') {
          return fail('it says version $shortVersion');
        }
        final sig = await _run('/usr/bin/codesign', [
          '--verify',
          '--deep',
          '--strict',
          app,
        ]);
        if (sig.exitCode != 0) return fail('code signature: ${sig.stderr}');
        return Right(StagedUpdate(version: version, path: app, format: format));
      case AppPackageFormat.linuxTarGz:
        final tar = File('/usr/bin/tar').existsSync()
            ? '/usr/bin/tar'
            : '/bin/tar';
        final untar = await _run(tar, [
          '-xzf',
          package.path,
          '-C',
          staging.path,
          '--no-same-owner',
        ]);
        if (untar.exitCode != 0) return fail('untar: ${untar.stderr}');
        final dirs = staging.listSync().whereType<Directory>().toList();
        if (dirs.length != 1) return fail('expected one bundle folder');
        final bundle = dirs.single.path;
        final exe = File('$bundle${_sep}floresta_desktop');
        final versionFile = File('$bundle${_sep}VERSION');
        if (!exe.existsSync() || !versionFile.existsSync()) {
          return fail('not a Floresta Desktop bundle');
        }
        final said = versionFile.readAsStringSync().trim();
        if (said != '$version') return fail('it says version $said');
        return Right(
          StagedUpdate(version: version, path: bundle, format: format),
        );
      case AppPackageFormat.linuxDeb:
        return fail('a .deb is installed by the system');
    }
  }

  Future<String?> _plist(String plist, String key) async {
    final r = await _run('/usr/bin/plutil', [
      '-extract',
      key,
      'raw',
      '-o',
      '-',
      plist,
    ]);
    return r.exitCode == 0 ? '${r.stdout}'.trim() : null;
  }

  Future<Either<Failure, StagedUpdate>> _checkDeb(
    File deb,
    AppVersion version,
  ) async {
    final r = await _run('/usr/bin/dpkg-deb', [
      '--field',
      deb.path,
      'Package',
      'Version',
    ]);
    final fields = {
      for (final line in '${r.stdout}'.split('\n'))
        if (line.contains(':'))
          line.substring(0, line.indexOf(':')).trim(): line
              .substring(line.indexOf(':') + 1)
              .trim(),
    };
    if (r.exitCode != 0 ||
        fields['Package'] != _debPackage ||
        !(fields['Version'] ?? '').startsWith('$version')) {
      return Left(
        InstallationFailure(
          stage: 'verify',
          message:
              'The downloaded package is not Floresta Desktop $version '
              '(${fields['Package']} ${fields['Version']}).',
        ),
      );
    }
    return Right(
      StagedUpdate(
        version: version,
        path: deb.path,
        format: AppPackageFormat.linuxDeb,
      ),
    );
  }

  /// Hands a verified `.deb` to the desktop's package installer, which
  /// asks for the password itself; this app never requests elevation.
  Future<Either<Failure, Unit>> openSystemInstaller(StagedUpdate deb) async {
    const opener = '/usr/bin/xdg-open';
    if (!File(opener).existsSync()) {
      return Left(
        InstallationFailure(
          stage: 'install',
          message:
              'No package installer could be opened. The verified package '
              'is at ${deb.path}.',
          recovery: 'Install it with your package manager.',
        ),
      );
    }
    await _startDetached(opener, [deb.path]);
    return const Right(unit);
  }

  /// True while a swap is armed (an update waits for the app to quit).
  bool get swapPending => _pendingFlag.existsSync();

  /// Arms the swap helper: once this process ([pid]) has exited, it
  /// replaces [kind]'s bundle with [staged]. With [relaunch] the new
  /// version starts right away; otherwise on the user's next launch (or
  /// at once if [requestRelaunch] is called before quitting).
  Future<Either<Failure, Unit>> armSwap(
    StagedUpdate staged,
    SelfUpdatable kind, {
    required int pid,
    required bool relaunch,
  }) async {
    try {
      await paths.updates.create(recursive: true);
      final script = File('${paths.updates.path}${_sep}swap.sh');
      await script.writeAsString(swapScript, flush: true);
      final chmod = await _run('/bin/chmod', ['700', script.path]);
      if (chmod.exitCode != 0) throw StateError('chmod: ${chmod.stderr}');
      if (await resultFile.exists()) await resultFile.delete();
      if (relaunch) {
        await _relaunchFlag.create();
      } else if (await _relaunchFlag.exists()) {
        await _relaunchFlag.delete();
      }
      await _pendingFlag.writeAsString('${staged.version}');
      await _startDetached('/bin/sh', [
        script.path,
        '$pid',
        staged.path,
        kind.bundlePath,
        kind.executable,
        _relaunchFlag.path,
        resultFile.path,
        '${staged.version}',
        platform.os == HostOs.macos ? 'macos' : 'linux',
        _pendingFlag.path,
      ]);
      return const Right(unit);
    } on Object catch (e) {
      return Left(
        InstallationFailure(
          stage: 'install',
          message: 'The update could not be prepared ($e).',
          recovery: 'Nothing was changed. Try again.',
        ),
      );
    }
  }

  /// Asks an armed swap to start the new version once the app has quit.
  Future<void> requestRelaunch() => _relaunchFlag.create(recursive: true);

  /// The last swap's outcome, if one finished since it was last cleared.
  Future<SwapResult?> lastResult() async {
    try {
      if (!await resultFile.exists()) return null;
      final m =
          jsonDecode(await resultFile.readAsString()) as Map<String, Object?>;
      return SwapResult(
        ok: m['ok'] == true,
        version: '${m['version']}',
        reason: m['reason'] as String?,
        backup: m['backup'] as String?,
      );
    } on Object {
      return null;
    }
  }

  /// After the new version has started: deletes the replaced bundle and
  /// the downloads, and forgets the result.
  Future<void> finish(SwapResult result) async {
    final backup = result.backup;
    if (result.ok && backup != null && backup.contains('.floresta-previous-')) {
      final dir = Directory(backup);
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    final downloads = Directory('${paths.updates.path}${_sep}downloads');
    if (await downloads.exists()) await downloads.delete(recursive: true);
    if (await resultFile.exists()) await resultFile.delete();
  }

  /// The helper, as data. POSIX sh; arguments, not interpolation, carry
  /// every path. It only renames inside the folder that holds the app.
  static const swapScript = r'''#!/bin/sh
# Written by Floresta Desktop to replace itself after it quits.
# Moves only the app bundle; settings, wallet and chain data live elsewhere.
pid="$1"; new="$2"; target="$3"; exe="$4"; relaunch_flag="$5"
result="$6"; version="$7"; os="$8"; pending="$9"
parent=$(dirname "$target")
backup="$parent/.floresta-previous-$(basename "$target")"

report() { # ok reason
  printf '{"ok":%s,"version":"%s","reason":"%s","backup":"%s"}\n' \
    "$1" "$version" "$2" "$backup" > "$result.tmp" && mv "$result.tmp" "$result"
}
launch() {
  [ -f "$relaunch_flag" ] || return 0
  rm -f "$relaunch_flag"
  if [ "$os" = macos ]; then /usr/bin/open "$target"
  else nohup "$exe" >/dev/null 2>&1 &
  fi
}

while kill -0 "$pid" 2>/dev/null; do sleep 1; done
rm -f "$pending"

if [ ! -d "$new" ]; then report false "the new version is missing"; launch; exit 1; fi
rm -rf "$backup"
if ! mv "$target" "$backup"; then
  report false "the installed app could not be moved"; launch; exit 1
fi
if ! mv "$new" "$target"; then
  mv "$backup" "$target"
  report false "the new version could not be moved into place"; launch; exit 1
fi
rmdir "$(dirname "$new")" 2>/dev/null
report true ""
launch
''';
}
