import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/security/sensitive_data.dart';
import 'wallet_account.dart';

/// What the app knows about a watched wallet beyond florestad: its name, and
/// whether the user removed it from this app.
///
/// florestad v0.9.1 has no way to name or forget a descriptor (its RPC has
/// only `loaddescriptor` and `listdescriptors`), so both live in the app,
/// keyed by the account id ([WalletAccount.id], a hash of the receive
/// descriptor: no key material).
class WalletLabel extends Equatable {
  const WalletLabel({this.name, this.hidden = false});

  final String? name;

  /// Removed from this app: not shown with the others and not synced. The
  /// node still watches it.
  final bool hidden;

  WalletLabel copyWith({Option<String>? name, bool? hidden}) => WalletLabel(
    name: name == null ? this.name : name.toNullable(),
    hidden: hidden ?? this.hidden,
  );

  Map<String, Object?> toJson() => {'name': ?name, if (hidden) 'hidden': true};

  static WalletLabel fromJson(Object? json) {
    if (json is! Map) return const WalletLabel();
    final name = json['name'];
    return WalletLabel(
      name: name is String && name.isNotEmpty ? name : null,
      hidden: json['hidden'] == true,
    );
  }

  @override
  List<Object?> get props => [name, hidden];
}

abstract final class WalletName {
  static const maxLength = 40;

  /// The start of an extended key, public or private, even cut short.
  static final _keyFragment = RegExp(
    r'(?:[xyztuvYZUV](?:pub|prv))[1-9A-HJ-NP-Za-km-z]{8,}',
  );

  /// A name for a wallet, or why it cannot be one. Names are stored in plain
  /// preferences, so key material of any kind, public or private, and
  /// pasted descriptors are refused.
  static Either<Failure, String> parse(String raw) {
    final name = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (name.isEmpty) {
      return const Left(ValidationFailure('Give the wallet a name.'));
    }
    if (SensitiveData.detectSecret(raw) case final reason?) {
      return Left(SecretMaterialRejectedFailure(reason));
    }
    if (SensitiveData.containsExtendedKey(raw) ||
        _keyFragment.hasMatch(raw) ||
        name.contains('(')) {
      return const Left(
        ValidationFailure(
          'A name cannot contain a key or a descriptor.',
          recovery: 'Use a short label such as "Savings" or "Sparrow".',
        ),
      );
    }
    if (name.length > maxLength) {
      return const Left(
        ValidationFailure('Use at most $maxLength characters for the name.'),
      );
    }
    return Right(name);
  }

  /// What the wallet is called on screen: its name, or "Wallet n" (its place
  /// among the accounts) with the script type.
  static String display(
    WalletAccount account, {
    required int index,
    required Map<String, WalletLabel> labels,
    required String scriptLabel,
  }) => labels[account.id]?.name ?? 'Wallet ${index + 1} · $scriptLabel';
}
