import 'package:blockchain_utils/blockchain_utils.dart'
    hide Either, Left, Right;
import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/security/sensitive_data.dart';
import '../../settings/domain/bitcoin_network.dart';
import '../domain/wallet_account.dart';
import '../domain/wallet_sync_ports.dart';
import 'descriptor_checksum.dart';

/// Parser for the single-key descriptor subset of ADR-0007.
///
/// Rejects before anything reaches florestad: private keys, `addr()`/`raw()`,
/// multisig, hardened steps after the key (florestad v0.9.1 panics on
/// `/*h`), and keys from the wrong network (florestad v0.9.1 accepts mainnet
/// keys on test networks). Multipath `<0;1>` is split client-side because
/// florestad v0.9.1 keeps only the external branch of a multipath import.
class SingleSigDescriptorParser implements DescriptorParser {
  const SingleSigDescriptorParser();

  static final _keyExpr = RegExp(
    r"^(?<origin>\[[0-9a-fA-F]{8}(?:/[0-9]+['h]?)*\])?"
    r'(?<key>[xt]pub[1-9A-HJ-NP-Za-km-z]+)'
    r'/(?<branch><0;1>|0|1)/\*$',
  );

  @override
  Either<Failure, ({WalletDescriptor external, WalletDescriptor internal})>
  parseAccount(String input, BitcoinNetwork network) {
    final text = input.trim();
    final secret = SensitiveData.detectSecret(text);
    if (secret != null) return Left(SecretMaterialRejectedFailure(secret));

    final hash = text.indexOf('#');
    final body = hash < 0 ? text : text.substring(0, hash);
    if (hash >= 0) {
      final given = text.substring(hash + 1);
      if (given != DescriptorChecksum.compute(body)) {
        return const Left(
          ValidationFailure(
            'The descriptor checksum is wrong.',
            recovery: 'Copy the descriptor again from your wallet.',
          ),
        );
      }
    }

    final (type, inner) = switch (body) {
      _ when body.startsWith('sh(wpkh(') && body.endsWith('))') => (
        ScriptType.shWpkh,
        body.substring(8, body.length - 2),
      ),
      _ when body.startsWith('wpkh(') && body.endsWith(')') => (
        ScriptType.wpkh,
        body.substring(5, body.length - 1),
      ),
      _ when body.startsWith('pkh(') && body.endsWith(')') => (
        ScriptType.pkh,
        body.substring(4, body.length - 1),
      ),
      _ when body.startsWith('tr(') && body.endsWith(')') => (
        ScriptType.tr,
        body.substring(3, body.length - 1),
      ),
      _ => (null, ''),
    };
    if (type == null || inner.contains('(') || inner.contains(',')) {
      return const Left(
        ValidationFailure(
          'Only single-key wpkh, sh(wpkh), pkh and tr descriptors are '
          'supported.',
          recovery:
              'Multisig, addr() and script descriptors are not '
              'supported yet.',
        ),
      );
    }
    if (RegExp(r"\*['h]|/[0-9]+['h](?=[^\]]*$)").hasMatch(inner)) {
      return const Left(
        ValidationFailure(
          'Hardened derivation after the extended key cannot be watched.',
          recovery:
              'Use the account-level xpub with unhardened /0/* and '
              '/1/* branches.',
        ),
      );
    }
    final m = _keyExpr.firstMatch(inner);
    if (m == null) {
      return const Left(
        ValidationFailure(
          'The key must be an account xpub/tpub followed by /<0;1>/*, /0/* '
          'or /1/*.',
        ),
      );
    }
    final key = m.namedGroup('key')!;
    final isMainnet = key.startsWith('xpub');
    try {
      Bip32Slip10Secp256k1.fromExtendedKey(
        key,
        isMainnet
            ? Bip32Const.mainNetKeyNetVersions
            : Bip32Const.testNetKeyNetVersions,
      );
    } catch (_) {
      return const Left(
        ValidationFailure('The extended public key is invalid.'),
      );
    }
    if (isMainnet != network.isMainnet) {
      return Left(
        ValidationFailure(
          isMainnet
              ? 'This is a mainnet key, but the wallet uses ${network.label}.'
              : 'This is a test-network key, but the wallet uses mainnet.',
          recovery: 'Export the key for the right network.',
        ),
      );
    }
    final branch = m.namedGroup('branch')!;
    if (branch == '1') {
      return const Left(
        ValidationFailure(
          'This is a change (/1/*) descriptor.',
          recovery:
              'Provide the receive (/0/*) or multipath (/<0;1>/*) '
              'descriptor.',
        ),
      );
    }

    WalletDescriptor make(Keychain k) {
      final single = body.replaceFirst(
        branch == '<0;1>' ? '/<0;1>/*' : '/0/*',
        '/${k.branch}/*',
      );
      return WalletDescriptor(
        value: '$single#${DescriptorChecksum.compute(single)}',
        scriptType: type,
        keychain: k,
        extendedKey: key,
        isMainnetKey: isMainnet,
      );
    }

    return Right((
      external: make(Keychain.external),
      internal: make(Keychain.internal),
    ));
  }
}
