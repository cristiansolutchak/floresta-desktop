import '../../../core/electrum/electrum_client.dart';
import '../../../core/electrum/electrum_transport.dart';
import '../../settings/domain/bitcoin_network.dart';
import '../domain/node_readiness.dart';

/// Asks florestad's Electrum server (127.0.0.1, the network's default port,
/// which is what the app launches with) for its genesis hash.
class ElectrumProbe {
  const ElectrumProbe({this.timeout = const Duration(seconds: 5)});

  final Duration timeout;

  /// [port] overrides the network default (tests, custom addresses).
  Future<ElectrumCheck> check(BitcoinNetwork network, {int? port}) async {
    final transport = ElectrumTransport(
      host: '127.0.0.1',
      port: port ?? network.electrumPort,
      connectTimeout: timeout,
      requestTimeout: timeout,
    );
    try {
      await transport.connect();
      final features = await TcpElectrumClient(transport).handshake();
      return features.genesisHash == network.genesisHash
          ? ElectrumCheck.ok
          : ElectrumCheck.wrongNetwork;
    } on Object {
      return ElectrumCheck.unreachable;
    } finally {
      await transport.dispose();
    }
  }
}
