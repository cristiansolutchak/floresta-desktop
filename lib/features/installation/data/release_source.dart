import 'artifact_downloader.dart';
import 'release_keys.dart';
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
    // Same define as `BuildFlavor`; read directly so this engine code does
    // not depend on Flutter.
    allowDevKey:
        const String.fromEnvironment('FLORESTA_FLAVOR') == 'development',
  );

  /// Builds a source from raw configuration values.
  ///
  /// A development key is trusted only in a development build
  /// ([allowDevKey]) and only for a loopback manifest URL, so neither a
  /// production build nor a remote manifest can ever rely on it.
  static ReleaseSource? resolve({
    required String manifestUrl,
    String redirectHosts = '',
    String devKeyHex = '',
    bool allowDevKey = true,
    List<TrustedReleaseKey> productionKeys = productionReleaseKeys,
  }) {
    final url = Uri.tryParse(manifestUrl.trim());
    if (url == null || !url.hasAuthority || !isAllowedDownloadUrl(url)) {
      return null;
    }
    final keys = [
      ...productionKeys,
      if (allowDevKey && _hex64.hasMatch(devKeyHex) && isLoopbackUrl(url))
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
