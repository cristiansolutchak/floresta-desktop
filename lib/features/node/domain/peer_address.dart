import 'package:fpdart/fpdart.dart';

/// Checks what florestad v0.9.1 `addnode` accepts (`json_rpc/network.rs`
/// `add_node`): an IP with a port (`1.2.3.4:8333`, `[2001:db8::1]:8333`) or a
/// bare IP, which gets the network's default P2P port. Host names are
/// refused upstream, so they are refused here too, with a reason.
Either<String, String> validatePeerAddress(String input) {
  final s = input.trim();
  if (s.isEmpty) return const Left('Enter an IP address and port.');

  bool isV4(String v) {
    try {
      Uri.parseIPv4Address(v);
      return true;
    } on FormatException {
      return false;
    }
  }

  bool isV6(String v) {
    try {
      Uri.parseIPv6Address(v);
      return true;
    } on FormatException {
      return false;
    }
  }

  bool isPort(String p) {
    final n = int.tryParse(p);
    return n != null && n > 0 && n <= 65535 && p == '$n';
  }

  // [v6]:port
  final bracket = RegExp(r'^\[([0-9A-Fa-f:.]+)\]:(\d+)$').firstMatch(s);
  if (bracket != null) {
    return isV6(bracket.group(1)!) && isPort(bracket.group(2)!)
        ? Right(s)
        : const Left('That IPv6 address or port is not valid.');
  }
  if (isV6(s) && s.contains(':')) return Right(s);
  final parts = s.split(':');
  if (parts.length == 2 && isV4(parts[0])) {
    return isPort(parts[1])
        ? Right(s)
        : const Left('The port must be a number from 1 to 65535.');
  }
  if (parts.length == 1 && isV4(s)) return Right(s);
  return const Left(
    'Floresta 0.9.1 connects to IP addresses only, for example '
    '1.2.3.4:8333. Host names are not supported.',
  );
}
