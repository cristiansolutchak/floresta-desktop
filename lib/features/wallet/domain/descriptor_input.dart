import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/security/sensitive_data.dart';

/// A user-supplied output descriptor that passed client-side checks.
///
/// Client-side checks are a safety net, not the authority: florestad parses
/// the descriptor with rust-miniscript as `Descriptor<DescriptorPublicKey>`
/// (`crates/floresta-watch-only/src/descriptor/mod.rs`) and rejects anything
/// invalid. The checks here exist to stop secrets from ever being sent.
class DescriptorInput {
  const DescriptorInput._(this.value);

  final String value;

  static final _slip132Key = RegExp(r'^[xyztuv]pub[1-9A-HJ-NP-Za-km-z]{100,}$');
  static final _scriptFunction = RegExp(r'^[a-z_]+\(.*\)(#[a-z0-9]{8})?$');

  static Either<Failure, DescriptorInput> parse(String raw) {
    final input = raw.trim();
    if (input.isEmpty) {
      return const Left(ValidationFailure('Paste an output descriptor.'));
    }
    final secret = SensitiveData.detectSecret(input);
    if (secret != null) return Left(SecretMaterialRejectedFailure(secret));

    if (_slip132Key.hasMatch(input)) {
      // loaddescriptor only accepts descriptors; bare xpubs are accepted by
      // florestad only at startup (--wallet-xpub / config file).
      return const Left(
        ValidationFailure(
          'This is an extended public key, not a descriptor.',
          recovery:
              'Wrap it in a descriptor, for example '
              'wpkh(xpub…/<0;1>/*) for a native SegWit wallet. Most wallets '
              '(Sparrow, Bitcoin Core) can export descriptors directly.',
        ),
      );
    }
    if (input.contains(RegExp(r'\s'))) {
      return const Left(
        ValidationFailure('A descriptor cannot contain spaces or line breaks.'),
      );
    }
    if (!_scriptFunction.hasMatch(input) || !_balanced(input)) {
      return const Left(
        ValidationFailure(
          'This does not look like an output descriptor.',
          recovery:
              'Descriptors look like wpkh(…), sh(wpkh(…)), tr(…) or '
              'wsh(multi(…)).',
        ),
      );
    }
    return Right(DescriptorInput._(input));
  }

  static bool _balanced(String s) {
    var depth = 0;
    for (final c in s.codeUnits) {
      if (c == 0x28) depth++;
      if (c == 0x29 && --depth < 0) return false;
    }
    return depth == 0;
  }
}
