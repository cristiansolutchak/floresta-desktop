import 'signed_manifest.dart';

/// Ed25519 public keys trusted to sign production release manifests.
/// Created with `release_tool.dart keygen`; the seeds never enter this
/// repository and are backed up offline. `prod-2026a` signs releases; `prod-2026b` is the
/// backup, used only if the first is lost or compromised (then remove the
/// old key here in a reviewed change).
/// Never put a private key or seed in this repository.
const productionReleaseKeys = <TrustedReleaseKey>[
  TrustedReleaseKey(
    id: 'prod-2026a',
    publicKeyHex:
        '3f0fcbf73c0e4fe3e31d22d2d16c77631abf73d193e1db4d78d758d5ee1aa2f0',
  ),
  TrustedReleaseKey(
    id: 'prod-2026b',
    publicKeyHex:
        '6599cea56f7c2efb4f2bbec8a8b66455a8e24c4dd44f72746daf53e216f30706',
  ),
];
