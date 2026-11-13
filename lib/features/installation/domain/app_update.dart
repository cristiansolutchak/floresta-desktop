import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/platform/host_platform.dart';

/// Updates of this app itself (ADR-0012). Same trust model as florestad
/// installs (ADR-0009): an Ed25519-signed manifest, anti-rollback serial,
/// expiry, then each package's size and SHA-256 before anything is unpacked.

/// The app's own version (`pubspec.yaml` `version`, without the build
/// number).
class AppVersion extends Equatable implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static final _pattern = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$');

  static AppVersion? tryParse(String text) {
    final m = _pattern.firstMatch(text.trim());
    if (m == null) return null;
    return AppVersion(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  @override
  int compareTo(AppVersion other) {
    for (final (a, b) in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      if (a != b) return a.compareTo(b);
    }
    return 0;
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  String toString() => '$major.$minor.$patch';

  @override
  List<Object?> get props => [major, minor, patch];
}

/// How the app was installed, which decides how it can be updated.
enum AppPackageFormat {
  /// `Floresta.app` zipped with `ditto`; replaced in place (macOS).
  macosAppZip('macos-app-zip'),

  /// The Linux bundle as a `.tar.gz`, unpacked into a folder the user owns;
  /// replaced in place.
  linuxTarGz('linux-tar-gz'),

  /// The `.deb` package. `/opt` belongs to root and the app never asks for
  /// elevation, so the system's package installer installs it.
  linuxDeb('linux-deb');

  const AppPackageFormat(this.id);
  final String id;

  static AppPackageFormat? fromId(String? id) =>
      values.where((f) => f.id == id).firstOrNull;
}

/// One downloadable package of the app.
class AppArtifact extends Equatable {
  const AppArtifact({
    required this.os,
    required this.arch,
    required this.format,
    required this.url,
    required this.sha256,
    required this.size,
    this.minOs,
  });

  final HostOs os;

  /// Null for a universal build (macOS arm64 + x86_64).
  final CpuArch? arch;
  final AppPackageFormat format;
  final Uri url;
  final String sha256;
  final int size;
  final String? minOs;

  @override
  List<Object?> get props => [os, arch, format, url, sha256, size, minOs];
}

/// The signed description of one app release.
class AppReleaseManifest extends Equatable {
  const AppReleaseManifest({
    required this.serial,
    required this.issued,
    required this.expires,
    required this.version,
    required this.artifacts,
    this.notes = '',
    this.revokedKeys = const {},
  });

  /// Differs from the florestad manifest's type, so a signature made for
  /// one can never pass as the other.
  static const type = 'floresta-gui/app-manifest';
  static const schema = 1;
  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');

  final int serial;
  final DateTime issued;
  final DateTime expires;
  final AppVersion version;

  /// Short plain-text release notes shown with the offer.
  final String notes;
  final List<AppArtifact> artifacts;
  final Set<String> revokedKeys;

  static Either<Failure, AppReleaseManifest> parse(Object? json, Uri base) {
    Failure bad(String why) => InstallationFailure(
      stage: 'resolve',
      message: 'Invalid update ($why).',
    );
    try {
      final m = json! as Map<String, Object?>;
      if (m['type'] != type) return Left(bad('not an app manifest'));
      if (m['schema'] != schema) {
        return Left(bad('unsupported schema ${m['schema']}'));
      }
      final version = AppVersion.tryParse(m['version']! as String);
      final serial = m['serial']! as int;
      final issued = DateTime.parse(m['issued']! as String).toUtc();
      final expires = DateTime.parse(m['expires']! as String).toUtc();
      if (version == null || serial < 1 || !expires.isAfter(issued)) {
        return Left(bad('bad version, serial or validity period'));
      }
      final notes = (m['notes'] as String?) ?? '';
      if (notes.length > 2000) return Left(bad('notes too long'));
      final artifacts = <AppArtifact>[];
      for (final raw in m['artifacts']! as List) {
        final a = raw as Map<String, Object?>;
        final os = HostOs.values.where((o) => o.name == a['os']).firstOrNull;
        final archName = a['arch'] as String?;
        final arch = archName == null || archName == 'universal'
            ? null
            : CpuArch.values.where((c) => c.name == archName).firstOrNull;
        final format = AppPackageFormat.fromId(a['format'] as String?);
        final sha = (a['sha256']! as String).toLowerCase();
        final size = a['size']! as int;
        if (os == null ||
            format == null ||
            (archName != null && archName != 'universal' && arch == null) ||
            !_hex64.hasMatch(sha) ||
            size <= 0) {
          return Left(bad('bad package entry'));
        }
        artifacts.add(
          AppArtifact(
            os: os,
            arch: arch,
            format: format,
            url: base.resolve(a['url']! as String),
            sha256: sha,
            size: size,
            minOs: a['minOs'] as String?,
          ),
        );
      }
      return Right(
        AppReleaseManifest(
          serial: serial,
          issued: issued,
          expires: expires,
          version: version,
          notes: notes,
          artifacts: artifacts,
          revokedKeys: {
            for (final k in (m['revokedKeys'] as List?) ?? const [])
              k as String,
          },
        ),
      );
    } on Object catch (e) {
      return Left(bad('malformed: $e'));
    }
  }

  /// The package for this computer and install format, if published.
  AppArtifact? artifactFor(HostPlatform platform, AppPackageFormat format) =>
      artifacts
          .where(
            (a) =>
                a.os == platform.os &&
                a.format == format &&
                (a.arch == null || a.arch == platform.arch),
          )
          .firstOrNull;

  /// Same policy as florestad manifests: not expired, not from the future,
  /// not older than one already accepted here.
  Either<Failure, Unit> checkFreshness({
    required DateTime now,
    required int highestAcceptedSerial,
    Duration clockSkew = const Duration(hours: 24),
  }) {
    if (!now.isBefore(expires)) {
      return const Left(
        InstallationFailure(
          stage: 'resolve',
          message: 'The update information has expired.',
          recovery: 'Check that your computer clock is correct.',
        ),
      );
    }
    if (issued.isAfter(now.add(clockSkew))) {
      return const Left(
        InstallationFailure(
          stage: 'resolve',
          message: 'The update information is dated in the future.',
          recovery: 'Check that your computer clock is correct.',
        ),
      );
    }
    if (serial < highestAcceptedSerial) {
      return const Left(
        InstallationFailure(
          stage: 'resolve',
          message:
              'The update server offered older update information than '
              'this computer has already seen.',
          recovery: 'The source may be stale or tampered with.',
        ),
      );
    }
    return const Right(unit);
  }

  @override
  List<Object?> get props => [
    serial,
    issued,
    expires,
    version,
    notes,
    artifacts,
    revokedKeys,
  ];
}

/// How the running app can be updated, decided from where it runs.
sealed class AppInstallKind extends Equatable {
  const AppInstallKind();

  @override
  List<Object?> get props => [];
}

/// The app replaces itself: [bundlePath] (`…/Floresta.app` on macOS, the
/// bundle folder on Linux) is in a folder the user can write.
final class SelfUpdatable extends AppInstallKind {
  const SelfUpdatable(this.format, this.bundlePath, {required this.executable});
  final AppPackageFormat format;
  final String bundlePath;

  /// What to start after the swap.
  final String executable;

  @override
  List<Object?> get props => [format, bundlePath, executable];
}

/// Installed by the `.deb`: the app downloads and verifies the package,
/// then the system's installer installs it (it asks for the password).
final class SystemPackage extends AppInstallKind {
  const SystemPackage();
}

/// Updates are offered as a notice only; [reason] says why the app cannot
/// install them itself.
final class NotUpdatable extends AppInstallKind {
  const NotUpdatable(this.reason);
  final String reason;

  @override
  List<Object?> get props => [reason];
}

/// Pure: classifies the running app.
///
/// [resolvedExecutable] is `Platform.resolvedExecutable`; [isWritable]
/// says whether the folder that holds the bundle can be written by this
/// user (the swap renames inside it). [updatesEnabled]: a production build,
/// or a development build fed by a loopback development release server
/// (`tool/release/dev_release.sh`), which a production build never trusts.
AppInstallKind classifyAppInstall({
  required HostOs os,
  required String resolvedExecutable,
  required bool Function(String folder) isWritable,
  required bool releaseBuild,
  required bool updatesEnabled,
}) {
  if (!releaseBuild || !updatesEnabled) {
    return const NotUpdatable(
      'This is a development build; it is updated from source.',
    );
  }
  String parent(String p) => p.substring(0, p.lastIndexOf('/'));
  switch (os) {
    case HostOs.macos:
      final marker = resolvedExecutable.lastIndexOf('.app/Contents/MacOS/');
      if (marker < 0) {
        return const NotUpdatable('The app is not running from an app bundle.');
      }
      final bundle = resolvedExecutable.substring(0, marker + 4);
      if (bundle.startsWith('/Volumes/')) {
        return const NotUpdatable(
          'The app runs from the disk image. Drag it to Applications first.',
        );
      }
      if (bundle.contains('/AppTranslocation/')) {
        return const NotUpdatable(
          'macOS runs this copy from a temporary location. Move it to '
          'Applications and open it from there.',
        );
      }
      return isWritable(parent(bundle))
          ? SelfUpdatable(
              AppPackageFormat.macosAppZip,
              bundle,
              executable: bundle,
            )
          : NotUpdatable(
              'This user cannot write to ${parent(bundle)}, where the app '
              'is installed.',
            );
    case HostOs.linux:
      final bundle = parent(resolvedExecutable);
      if (bundle.startsWith('/opt/floresta-gui') ||
          bundle.startsWith('/usr/')) {
        return const SystemPackage();
      }
      return isWritable(parent(bundle))
          ? SelfUpdatable(
              AppPackageFormat.linuxTarGz,
              bundle,
              executable: resolvedExecutable,
            )
          : NotUpdatable(
              'This user cannot write to ${parent(bundle)}, where the app '
              'is installed.',
            );
    case HostOs.windows || HostOs.other:
      return const NotUpdatable(
        'Updates are not available on this system yet.',
      );
  }
}

/// An update the app found.
sealed class UpdateOffer extends Equatable {
  const UpdateOffer();
}

final class AppUpdateOffer extends UpdateOffer {
  const AppUpdateOffer({
    required this.manifest,
    required this.artifact,
    required this.current,
    required this.kind,
  });
  final AppReleaseManifest manifest;

  /// Null when nothing is published for this install format.
  final AppArtifact? artifact;
  final AppVersion current;
  final AppInstallKind kind;

  AppVersion get version => manifest.version;

  @override
  List<Object?> get props => [manifest, artifact, current, kind];
}

final class FlorestadUpdateOffer extends UpdateOffer {
  const FlorestadUpdateOffer({
    required this.label,
    required this.currentLabel,
    required this.sha256,
  });

  /// "v0.9.0 (master 3a47993)".
  final String label;
  final String currentLabel;
  final String sha256;

  @override
  List<Object?> get props => [label, currentLabel, sha256];
}

/// The user's update preferences.
class UpdatePreferences extends Equatable {
  const UpdatePreferences({this.autoInstall = false, this.postponedUntil});

  /// Install without asking. Off by default (owner's choice, 2026-11-13):
  /// the app checks and downloads, then asks.
  final bool autoInstall;

  /// "Later" hides the notice until then (the next launch at the latest).
  final DateTime? postponedUntil;

  bool postponedAt(DateTime now) =>
      postponedUntil != null && now.isBefore(postponedUntil!);

  @override
  List<Object?> get props => [autoInstall, postponedUntil];
}
