import 'package:equatable/equatable.dart';

import '../../settings/domain/bitcoin_network.dart';

/// Single-key script types supported by the MVP (ADR-0007). Multisig is a
/// later phase; it would be a new value plus parser/deriver support.
enum ScriptType { pkh, shWpkh, wpkh, tr }

enum Keychain {
  external(0),
  internal(1);

  const Keychain(this.branch);

  /// Child index of the branch under the account key (`/0/*`, `/1/*`).
  final int branch;
}

/// One public, single-path, checksummed descriptor, e.g.
/// `wpkh([d34db33f/84h/1h/0h]tpub…/0/*)#abcdefgh`.
class WalletDescriptor extends Equatable {
  const WalletDescriptor({
    required this.value,
    required this.scriptType,
    required this.keychain,
    required this.extendedKey,
    required this.isMainnetKey,
  });

  /// Canonical text including checksum; this exact string is what florestad
  /// is given and what `listdescriptors` returns.
  final String value;
  final ScriptType scriptType;
  final Keychain keychain;

  /// Account-level extended public key (xpub/tpub).
  final String extendedKey;
  final bool isMainnetKey;

  @override
  List<Object?> get props => [value];
}

class WalletAccount extends Equatable {
  const WalletAccount({
    required this.id,
    required this.network,
    required this.external,
    required this.internal,
  });

  final String id;
  final BitcoinNetwork network;
  final WalletDescriptor external;
  final WalletDescriptor internal;

  WalletDescriptor descriptor(Keychain k) =>
      k == Keychain.external ? external : internal;

  @override
  List<Object?> get props => [id, network, external, internal];
}

class DerivedScript extends Equatable {
  const DerivedScript({
    required this.keychain,
    required this.index,
    required this.scriptPubKey,
    required this.scripthash,
  });

  final Keychain keychain;
  final int index;

  /// Lowercase hex.
  final String scriptPubKey;

  /// Electrum scripthash: sha256(scriptPubKey), byte-reversed, hex.
  final String scripthash;

  @override
  List<Object?> get props => [keychain, index, scriptPubKey];
}
