import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/platform/host_platform.dart';
import 'floresta_version.dart';

/// One downloadable florestad build for a platform. The artifact is the bare
/// executable (no archive), so installation needs no extraction step.
class ReleaseArtifact extends Equatable {
  const ReleaseArtifact({
    required this.os,
    required this.arch,
    required this.url,
    required this.sha256,
    required this.size,
    this.minOs,
  });

  final HostOs os;
  final CpuArch arch;
  final Uri url;

  /// Lowercase hex SHA-256 of the executable.
  final String sha256;
  final int size;

  /// Oldest system the build runs on, as recorded by the artifact build:
  /// a macOS version (`11.0`) or a glibc version (`glibc 2.31`). Null when
  /// the manifest does not say.
  final String? minOs;

  @override
  List<Object?> get props => [os, arch, url, sha256, size, minOs];
}

/// INS-09: whether a host satisfies an artifact's [ReleaseArtifact.minOs].
///
/// [hostVersion] uses the same form (`26.3.1`, `glibc 2.35`). Returns null
/// when either side is unknown or the forms differ, so the caller can let
/// the later `--version` probe decide instead of refusing blindly.
bool? satisfiesMinOs(String? minOs, String? hostVersion) {
  if (minOs == null || hostVersion == null) return null;
  (String, List<int>)? split(String v) {
    final m = RegExp(r'^(glibc )?(\d+(?:\.\d+)*)$').firstMatch(v.trim());
    if (m == null) return null;
    return (m.group(1) ?? '', m.group(2)!.split('.').map(int.parse).toList());
  }

  final need = split(minOs);
  final have = split(hostVersion);
  if (need == null || have == null || need.$1 != have.$1) return null;
  for (var i = 0; i < need.$2.length || i < have.$2.length; i++) {
    final a = i < have.$2.length ? have.$2[i] : 0;
    final b = i < need.$2.length ? need.$2[i] : 0;
    if (a != b) return a > b;
  }
  return true;
}

/// The signed description of one Floresta release published for this app.
class ReleaseManifest extends Equatable {
  const ReleaseManifest({
    required this.serial,
    required this.issued,
    required this.expires,
    required this.version,
    required this.upstreamCommit,
    required this.artifacts,
    this.revokedKeys = const {},
    this.upstreamRef,
  });

  /// Inside the signed bytes, so a signature made for anything else can
  /// never pass as a release manifest.
  static const type = 'floresta-gui/release-manifest';
  static const schema = 2;
  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');
  static final _commit = RegExp(r'^[0-9a-f]{40}$');

  /// Increases with every published manifest. The app refuses a serial
  /// lower than one it has already accepted (replayed old manifests).
  final int serial;
  final DateTime issued;

  /// After this the manifest is refused, which bounds how long an attacker
  /// can keep serving a stale one (freeze).
  final DateTime expires;
  final FlorestaVersion version;

  /// Upstream Floresta commit the artifacts were built from.
  final String upstreamCommit;

  /// What [upstreamCommit] is: the release tag (`v0.9.1`) or
  /// `master@<commit>` for a pinned master build (UPS-01), whose
  /// `--version` still says the last version on master (0.9.0). Optional:
  /// manifests signed before 2026-11-13 do not carry it.
  final String? upstreamRef;
  final List<ReleaseArtifact> artifacts;

  /// Signing key ids this manifest revokes.
  final Set<String> revokedKeys;

  /// Parses the (already signature-verified) payload. [base] resolves
  /// relative artifact URLs against the manifest location.
  static Either<Failure, ReleaseManifest> parse(Object? json, Uri base) {
    try {
      final m = json! as Map<String, Object?>;
      if (m['type'] != type) {
        return const Left(InstallationFailure.manifest('not a manifest'));
      }
      if (m['schema'] != schema) {
        return Left(
          InstallationFailure.manifest('unsupported schema ${m['schema']}'),
        );
      }
      final version = FlorestaVersion.tryParse('v${m['version']}');
      final commit = m['upstreamCommit'] as String;
      if (version == null ||
          !_commit.hasMatch(commit) ||
          m['upstreamTag'] != 'v${m['version']}') {
        return const Left(
          InstallationFailure.manifest('bad version, tag or commit'),
        );
      }
      final ref = m['upstreamRef'] as String?;
      if (ref != null && ref != 'v${m['version']}' && ref != 'master@$commit') {
        return const Left(InstallationFailure.manifest('bad upstream ref'));
      }
      final serial = m['serial'] as int;
      final issued = DateTime.parse(m['issued'] as String).toUtc();
      final expires = DateTime.parse(m['expires'] as String).toUtc();
      if (serial < 1 || !expires.isAfter(issued)) {
        return const Left(
          InstallationFailure.manifest('bad serial or validity period'),
        );
      }
      final artifacts = <ReleaseArtifact>[];
      for (final raw in m['artifacts']! as List) {
        final a = raw as Map<String, Object?>;
        final os = HostOs.values.where((o) => o.name == a['os']).firstOrNull;
        final arch = CpuArch.values
            .where((c) => c.name == a['arch'])
            .firstOrNull;
        final sha = (a['sha256'] as String).toLowerCase();
        final size = a['size'] as int;
        final minOs = a['minOs'] as String?;
        if (os == null || arch == null || !_hex64.hasMatch(sha) || size <= 0) {
          return const Left(InstallationFailure.manifest('bad artifact entry'));
        }
        artifacts.add(
          ReleaseArtifact(
            os: os,
            arch: arch,
            url: base.resolve(a['url'] as String),
            sha256: sha,
            size: size,
            minOs: minOs,
          ),
        );
      }
      return Right(
        ReleaseManifest(
          serial: serial,
          issued: issued,
          expires: expires,
          version: version,
          upstreamCommit: commit,
          upstreamRef: ref,
          artifacts: artifacts,
          revokedKeys: {
            for (final k in (m['revokedKeys'] as List?) ?? const [])
              k as String,
          },
        ),
      );
    } on Object catch (e) {
      return Left(InstallationFailure.manifest('malformed manifest: $e'));
    }
  }

  Either<Failure, ReleaseArtifact> artifactFor(HostPlatform platform) {
    final match = artifacts
        .where((a) => a.os == platform.os && a.arch == platform.arch)
        .firstOrNull;
    return match == null
        ? Left(
            InstallationFailure(
              stage: 'resolve',
              message:
                  'Floresta $version is not published for ${platform.label}.',
              recovery: 'Choose an existing florestad executable instead.',
            ),
          )
        : Right(match);
  }

  /// Freshness policy, checked after the signature: not expired, not
  /// issued in the future (beyond clock skew), and not older than the
  /// newest manifest already accepted on this computer.
  Either<Failure, Unit> checkFreshness({
    required DateTime now,
    required int highestAcceptedSerial,
    Duration clockSkew = const Duration(hours: 24),
  }) {
    if (!now.isBefore(expires)) {
      return const Left(
        InstallationFailure(
          stage: 'resolve',
          message: 'The release information has expired.',
          recovery:
              'Nothing was installed. Check that your computer clock is '
              'correct, or try again later.',
        ),
      );
    }
    if (issued.isAfter(now.add(clockSkew))) {
      return const Left(
        InstallationFailure(
          stage: 'resolve',
          message: 'The release information is dated in the future.',
          recovery:
              'Nothing was installed. Check that your computer clock is '
              'correct.',
        ),
      );
    }
    if (serial < highestAcceptedSerial) {
      return const Left(
        InstallationFailure(
          stage: 'resolve',
          message:
              'The release server offered older release information '
              'than this computer has already seen.',
          recovery:
              'Nothing was installed. The download source may be stale or '
              'tampered with; try again later.',
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
    upstreamCommit,
    artifacts,
    revokedKeys,
  ];
}
