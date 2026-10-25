/// Networks accepted by `florestad --network` (parsed by `bitcoin::Network`).
///
/// Ports and data subdirectories mirror upstream exactly; see
/// docs/research/upstream-sources.md. Note regtest RPC is 18442 in Floresta,
/// not Bitcoin Core's 18443.
enum BitcoinNetwork {
  bitcoin(
    cliValue: 'bitcoin',
    assumeUtreexoHeight: 939969,
    assumeValidHeight: 939969,
    genesisHash:
        '000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f',
    label: 'Mainnet',
    rpcPort: 8332,
    p2pPort: 8333,
    electrumPort: 50001,
    dataSubdir: null,
    chainNames: {'main', 'bitcoin'},
  ),
  signet(
    cliValue: 'signet',
    assumeUtreexoHeight: 296870,
    assumeValidHeight: 296870,
    genesisHash:
        '00000008819873e925422c1ff0f99f7cc9bbb232af63a077a480a3633bee1ef6',
    label: 'Signet',
    rpcPort: 38332,
    p2pPort: 38333,
    electrumPort: 60001,
    dataSubdir: 'signet',
    chainNames: {'signet'},
  ),
  testnet4(
    cliValue: 'testnet4',
    assumeUtreexoHeight: 0,
    assumeValidHeight: 126514,
    genesisHash:
        '00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043',
    label: 'Testnet4',
    rpcPort: 48332,
    p2pPort: 48333,
    electrumPort: 40001,
    dataSubdir: 'testnet4',
    chainNames: {'testnet4'},
  ),
  regtest(
    cliValue: 'regtest',
    assumeUtreexoHeight: 0,
    assumeValidHeight: 0,
    genesisHash:
        '0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206',
    label: 'Regtest',
    rpcPort: 18442,
    p2pPort: 18444,
    electrumPort: 20001,
    dataSubdir: 'regtest',
    chainNames: {'regtest'},
  );

  const BitcoinNetwork({
    required this.cliValue,
    required this.assumeUtreexoHeight,
    required this.assumeValidHeight,
    required this.genesisHash,
    required this.label,
    required this.rpcPort,
    required this.p2pPort,
    required this.electrumPort,
    required this.dataSubdir,
    required this.chainNames,
  });

  final String cliValue;

  /// Height of the Utreexo state hard-coded in florestad v0.9.1 and accepted
  /// without validation when assume-utreexo is on (the default, and the app
  /// never disables it). 0 = none. `floresta-chain` `chainparams.rs`
  /// `get_assume_utreexo` at v0.9.1. Re-check on every upstream upgrade.
  final int assumeUtreexoHeight;

  /// Script checks are skipped up to this height (assume-valid, like Bitcoin
  /// Core). `chainparams.rs` `get_assume_valid` (hard-coded) at v0.9.1.
  final int assumeValidHeight;

  /// Block 0 hash; taken from Bitcoin Core 30.0 `getblockhash 0` per chain.
  final String genesisHash;
  final String label;
  final int rpcPort;

  /// Default P2P port, as florestad's `addnode` assumes when none is given
  /// (`floresta-node` `json_rpc/network.rs` `add_node`, v0.9.1).
  final int p2pPort;

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
