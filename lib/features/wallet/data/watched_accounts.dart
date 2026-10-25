import 'package:blockchain_utils/blockchain_utils.dart';

import '../../settings/domain/bitcoin_network.dart';
import '../domain/wallet_account.dart';
import '../domain/wallet_sync_ports.dart';
import 'single_sig_descriptor_parser.dart';

/// The node's watched descriptors, grouped into accounts the app can sync.
///
/// florestad keeps one descriptor per branch (`/0/*` and `/1/*`; the app
/// imports them separately because v0.9.1 drops the internal branch of a
/// multipath import), so `listdescriptors` returns them unpaired.
class WatchedAccounts {
  const WatchedAccounts({
    this.accounts = const [],
    this.receiveOnly = const [],
    this.unsupported = const [],
  });

  /// Both branches watched: balances and history can be complete.
  final List<WalletAccount> accounts;

  /// A receive branch without its change branch: change outputs are
  /// invisible to the node, so a balance would be wrong. Shown, not synced.
  final List<String> receiveOnly;

  /// Descriptors this app cannot sync (other script types, change branches
  /// without a receive branch, multipath text kept by the node).
  final List<String> unsupported;

  bool get isEmpty =>
      accounts.isEmpty && receiveOnly.isEmpty && unsupported.isEmpty;

  /// Groups [listed] for [network].
  factory WatchedAccounts.fromListed(
    List<String> listed,
    BitcoinNetwork network, {
    DescriptorParser parser = const SingleSigDescriptorParser(),
  }) {
    final set = listed.toSet();
    final accounts = <WalletAccount>[];
    final receiveOnly = <String>[];
    final used = <String>{};
    for (final d in listed) {
      final parsed = parser.parseAccount(d, network).toNullable();
      if (parsed == null || parsed.external.value != d) continue;
      used.add(d);
      if (set.contains(parsed.internal.value)) {
        used.add(parsed.internal.value);
        accounts.add(
          WalletAccount(
            id: accountIdFor(parsed.external),
            network: network,
            external: parsed.external,
            internal: parsed.internal,
          ),
        );
      } else {
        receiveOnly.add(d);
      }
    }
    return WatchedAccounts(
      accounts: accounts,
      receiveOnly: receiveOnly,
      unsupported: [
        for (final d in listed)
          if (!used.contains(d)) d,
      ],
    );
  }

  /// A stable, file-name-safe id: the first 16 hex chars of the SHA-256 of
  /// the receive descriptor. It does not reveal the key.
  static String accountIdFor(WalletDescriptor external) =>
      'a${BytesUtils.toHexString(QuickCrypto.sha256Hash(external.value.codeUnits)).substring(0, 16)}';
}
