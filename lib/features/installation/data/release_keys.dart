import 'signed_manifest.dart';

/// Ed25519 public keys trusted to sign production release manifests
/// (SEC-05). Empty until the owner holds a production key: a build without
/// one offers no automatic installation, whatever URL it is given.
///
/// Adding a key: generate it offline (`release_tool.dart keygen` on an
/// offline machine, or a hardware key), then add its public half here in a
/// reviewed change, with a backup key, e.g.
/// `TrustedReleaseKey(id: 'prod-2026a', publicKeyHex: '<64 hex>')`.
/// Never put a private key or seed in this repository.
const productionReleaseKeys = <TrustedReleaseKey>[];
