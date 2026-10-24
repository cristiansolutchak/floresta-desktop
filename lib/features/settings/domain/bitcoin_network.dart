/// Networks accepted by `florestad --network` (parsed by `bitcoin::Network`).
///
/// Ports and data subdirectories mirror upstream exactly; see
/// docs/research/upstream-sources.md. Note regtest RPC is 18442 in Floresta,
/// not Bitcoin Core's 18443.
enum BitcoinNetwork {
  bitcoin(
    cliValue: 'bitcoin',
    label: 'Mainnet',
    rpcPort: 8332,
    electrumPort: 50001,
    dataSubdir: null,
    chainNames: {'main', 'bitcoin'},
  ),
  signet(
    cliValue: 'signet',
    label: 'Signet',
    rpcPort: 38332,
    electrumPort: 60001,
    dataSubdir: 'signet',
    chainNames: {'signet'},
  ),
  testnet4(
    cliValue: 'testnet4',
    label: 'Testnet4',
    rpcPort: 48332,
    electrumPort: 40001,
    dataSubdir: 'testnet4',
    chainNames: {'testnet4'},
  ),
  regtest(
    cliValue: 'regtest',
    label: 'Regtest',
    rpcPort: 18442,
    electrumPort: 20001,
    dataSubdir: 'regtest',
    chainNames: {'regtest'},
  );

  const BitcoinNetwork({
    required this.cliValue,
    required this.label,
    required this.rpcPort,
    required this.electrumPort,
    required this.dataSubdir,
    required this.chainNames,
  });

  final String cliValue;
  final String label;
  final int rpcPort;

  /// Plain-TCP Electrum port; TLS is `electrumPort + 1` upstream.
  final int electrumPort;
  final String? dataSubdir;

  /// Values `getblockchaininfo.chain` may report. The code returns "main"
  /// while upstream docs show "bitcoin", so both are accepted.
  final Set<String> chainNames;

  bool get isMainnet => this == bitcoin;

  String get description => switch (this) {
    bitcoin => 'The real Bitcoin network. Coins have real value.',
    signet =>
      'A public test network with worthless coins. Good for trying '
          'things out.',
    testnet4 => 'The current public test network.',
    regtest => 'A private local network for development.',
  };

  static BitcoinNetwork? fromCliValue(String value) {
    for (final n in values) {
      if (n.cliValue == value) return n;
    }
    return null;
  }

  static BitcoinNetwork? fromChainName(String chain) {
    for (final n in values) {
      if (n.chainNames.contains(chain)) return n;
    }
    return null;
  }
}
