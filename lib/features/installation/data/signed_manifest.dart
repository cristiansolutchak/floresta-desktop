import 'dart:convert';

import 'package:blockchain_utils/blockchain_utils.dart'
    hide Either, Left, Right;
import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../domain/release_manifest.dart';

/// An Ed25519 public key trusted to sign release manifests.
class TrustedReleaseKey {
  const TrustedReleaseKey({required this.id, required this.publicKeyHex});
  final String id;

  /// 32-byte Ed25519 public key, hex.
  final String publicKeyHex;
}

/// Verifies the signed manifest envelope:
///
/// `{"keyId": "...", "payload": base64(JSON bytes), "signature": base64(64 bytes)}`
///
/// The signature covers the exact payload bytes, so no JSON canonicalisation
/// is involved. Ed25519 comes from blockchain_utils (verified against RFC 8032
/// vectors in tests); nothing cryptographic is implemented here.
class SignedManifestVerifier {
  SignedManifestVerifier(this.trustedKeys);

  final List<TrustedReleaseKey> trustedKeys;
  static const maxEnvelopeBytes = 64 * 1024;

  /// [revokedKeys] are key ids revoked by an earlier accepted manifest;
  /// they are treated as unknown.
  Either<Failure, ReleaseManifest> verify(
    List<int> envelopeBytes,
    Uri location, {
    Set<String> revokedKeys = const {},
  }) {
    if (envelopeBytes.length > maxEnvelopeBytes) {
      return const Left(InstallationFailure.manifest('too large'));
    }
    final Map<String, Object?> envelope;
    final List<int> payload;
    final List<int> signature;
    final String keyId;
    try {
      envelope = jsonDecode(utf8.decode(envelopeBytes)) as Map<String, Object?>;
      keyId = envelope['keyId']! as String;
      payload = base64.decode(envelope['payload']! as String);
      signature = base64.decode(envelope['signature']! as String);
    } on Object catch (e) {
      return Left(InstallationFailure.manifest('malformed envelope: $e'));
    }
    final key = trustedKeys.where((k) => k.id == keyId).firstOrNull;
    if (key == null || revokedKeys.contains(keyId)) {
      return Left(
        InstallationFailure(
          stage: 'resolve',
          message: 'The release is signed by an unknown key ($keyId).',
          recovery:
              'Nothing was installed. This app only installs releases '
              'signed by its publisher.',
        ),
      );
    }
    if (!verifySignature(
      publicKey: BytesUtils.fromHexString(key.publicKeyHex),
      message: payload,
      signature: signature,
    )) {
      return const Left(
        InstallationFailure(
          stage: 'resolve',
          message: 'The release information failed its signature check.',
          recovery:
              'Nothing was installed. The download may have been '
              'tampered with; try again later.',
        ),
      );
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(payload));
    } on Object catch (e) {
      return Left(InstallationFailure.manifest('payload is not JSON: $e'));
    }
    final parsed = ReleaseManifest.parse(json, location);
    if (parsed case Right(
      :final value,
    ) when value.revokedKeys.contains(keyId)) {
      return const Left(
        InstallationFailure.manifest('signed by a key it revokes'),
      );
    }
    return parsed;
  }

  /// Ed25519 verification of [message]; false for any malformed input.
  static bool verifySignature({
    required List<int> publicKey,
    required List<int> message,
    required List<int> signature,
  }) {
    if (publicKey.length != 32 || signature.length != 64) return false;
    try {
      return Ed25519Verifier.fromKeyBytes(publicKey).verify(message, signature);
    } on Object {
      return false;
    }
  }
}
