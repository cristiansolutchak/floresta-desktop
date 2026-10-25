import 'artifact_downloader.dart';
import 'signed_manifest.dart';

/// Where releases come from and whom to trust. Hosting is configuration:
/// the verification logic is identical for every source.
class ReleaseSource {
  const ReleaseSource({
    required this.manifestUrl,
    required this.trustedKeys,
    this.redirectHosts = const {},
  });

  final Uri manifestUrl;
  final List<TrustedReleaseKey> trustedKeys;

  /// Extra hosts a download may be redirected to (https only), besides the
  /// host it started on.
  final Set<String> redirectHosts;

  static const _manifestUrl = String.fromEnvironment(
    'FLORESTA_RELEASE_MANIFEST_URL',
  );
  static const _redirectHosts = String.fromEnvironment(
    'FLORESTA_RELEASE_REDIRECT_HOSTS',
  );
  static const _devKey = String.fromEnvironment('FLORESTA_DEV_RELEASE_KEY');

  /// The source compiled into this build, or null when none is configured
  /// (the default: nothing is published yet).
  static ReleaseSource? fromEnvironment() => resolve(
    manifestUrl: _manifestUrl,
    redirectHosts: _redirectHosts,
    devKeyHex: _devKey,
  );

  /// Builds a source from raw configuration values.
  ///
  /// A development key is trusted only for a loopback manifest URL, so a
  /// build carrying one can never accept a remote manifest signed with it.
  static ReleaseSource? resolve({
    required String manifestUrl,
    String redirectHosts = '',
    String devKeyHex = '',
    List<TrustedReleaseKey> productionKeys = productionReleaseKeys,
  }) {
    final url = Uri.tryParse(manifestUrl.trim());
    if (url == null || !url.hasAuthority || !isAllowedDownloadUrl(url)) {
      return null;
    }
    final keys = [
      ...productionKeys,
      if (_hex64.hasMatch(devKeyHex) && isLoopbackUrl(url))
        TrustedReleaseKey(id: developmentKeyId, publicKeyHex: devKeyHex),
    ];
    if (keys.isEmpty) return null;
    return ReleaseSource(
      manifestUrl: url,
      trustedKeys: keys,
      redirectHosts: {
        for (final h in redirectHosts.split(','))
          if (h.trim().isNotEmpty) h.trim().toLowerCase(),
      },
    );
  }

  static const developmentKeyId = 'dev';
  static final _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');
}
