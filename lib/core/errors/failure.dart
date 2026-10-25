import 'package:equatable/equatable.dart';

/// Base type for every error that crosses a layer boundary.
///
/// Repositories catch exceptions and return `Left(Failure)`; the UI renders
/// [title], [message] and [recovery] directly, so each subtype must carry text
/// a non-technical user can act on.
sealed class Failure extends Equatable {
  const Failure();

  String get title;
  String get message;

  /// What the user can do next. Null when there is nothing useful to suggest.
  String? get recovery => null;

  @override
  List<Object?> get props => [title, message];
}

final class ValidationFailure extends Failure {
  const ValidationFailure(this.message, {this.recovery});

  @override
  String get title => 'Invalid input';
  @override
  final String message;
  @override
  final String? recovery;
}

/// Raised when input looks like private key material. Kept separate from
/// [ValidationFailure] so the UI can make the warning prominent.
final class SecretMaterialRejectedFailure extends Failure {
  const SecretMaterialRejectedFailure(this.message);

  @override
  String get title => 'Private key material detected';
  @override
  final String message;
  @override
  String get recovery =>
      'Floresta only needs public information. Export a descriptor or '
      'extended public key (xpub) from your wallet instead. Never paste a '
      'seed phrase or private key into this app.';
}

final class StorageFailure extends Failure {
  const StorageFailure(this.message);

  @override
  String get title => 'Could not save settings';
  @override
  final String message;
}

/// A file the user asked to save (for example exported diagnostics) could
/// not be written.
final class FileWriteFailure extends Failure {
  const FileWriteFailure(this.path, this.detail);

  final String path;
  final String detail;

  @override
  String get title => 'Could not save the file';
  @override
  String get message => '$path: $detail';
  @override
  String get recovery => 'Choose another folder and try again.';

  @override
  List<Object?> get props => [path, detail];
}

/// INS-12: a reset or removal was refused or did not complete.
final class ResetFailure extends Failure {
  const ResetFailure(this.message, {this.recovery});

  @override
  String get title => 'Reset did not complete';
  @override
  final String message;
  @override
  final String? recovery;
}

final class ExecutableNotFoundFailure extends Failure {
  const ExecutableNotFoundFailure(this.searchedPaths);

  final List<String> searchedPaths;

  @override
  String get title => 'Floresta is not installed';
  @override
  String get message =>
      'No florestad executable was found in ${searchedPaths.length} '
      'searched locations.';
  @override
  String get recovery =>
      'Build Floresta from source, or choose an existing florestad '
      'executable in Installation.';

  @override
  List<Object?> get props => [...super.props, searchedPaths];
}

final class ExecutableInvalidFailure extends Failure {
  const ExecutableInvalidFailure(this.path, this.message, {this.recovery});

  final String path;
  @override
  String get title => 'The selected executable cannot be used';
  @override
  final String message;
  @override
  final String? recovery;

  @override
  List<Object?> get props => [...super.props, path];
}

final class ProcessStartFailure extends Failure {
  const ProcessStartFailure(this.message, {this.recovery});

  @override
  String get title => 'Floresta could not be started';
  @override
  final String message;
  @override
  final String? recovery;
}

/// A check before starting the node found a problem that would make
/// florestad fail or put data at risk.
final class PreflightFailure extends Failure {
  const PreflightFailure({
    required this.title,
    required this.message,
    this.recovery,
  });

  @override
  final String title;
  @override
  final String message;
  @override
  final String? recovery;
}

final class ProcessStateFailure extends Failure {
  const ProcessStateFailure(this.message);

  @override
  String get title => 'Action not available right now';
  @override
  final String message;
}

final class RpcUnreachableFailure extends Failure {
  const RpcUnreachableFailure(this.endpoint);

  final String endpoint;

  @override
  String get title => 'Node API not reachable';
  @override
  String get message => 'Nothing answered at $endpoint.';
  @override
  String get recovery =>
      'Start the node from Overview. If it is already running, check that '
      'the network and RPC port in Settings match the running node.';
}

final class RpcTimeoutFailure extends Failure {
  const RpcTimeoutFailure(this.method, this.timeout);

  final String method;
  final Duration timeout;

  @override
  String get title => 'The node did not respond in time';
  @override
  String get message =>
      '"$method" did not answer within ${timeout.inSeconds} seconds.';
  @override
  String get recovery =>
      'The node may be busy during initial sync. Try again shortly.';
}

/// The port answered, but not as an unauthenticated Floresta JSON-RPC
/// server. Usually Bitcoin Core is bound to the same default port (8332).
final class RpcForeignServiceFailure extends Failure {
  const RpcForeignServiceFailure(this.endpoint, this.statusCode);

  final String endpoint;
  final int statusCode;

  @override
  String get title => 'Another service is using the node port';
  @override
  String get message =>
      '$endpoint answered with HTTP $statusCode, which Floresta never sends.';
  @override
  String get recovery =>
      'Bitcoin Core uses the same default RPC port. Stop the other service '
      'or choose a different RPC port in Settings.';
}

final class RpcMalformedResponseFailure extends Failure {
  const RpcMalformedResponseFailure(this.method, this.detail);

  final String method;
  final String detail;

  @override
  String get title => 'Unexpected response from the node';
  @override
  String get message => '"$method" returned data this app cannot read.';
  @override
  String get recovery =>
      'Your Floresta version may be newer or older than this app supports. '
      'Check Settings → Diagnostics for the detected version.';

  @override
  List<Object?> get props => [...super.props, detail];
}

/// A JSON-RPC error object returned by the node.
///
/// Known Floresta codes get their own wording via [RpcErrorFailure.title]
/// and [recovery]; unknown codes fall back to the node's own message.
final class RpcErrorFailure extends Failure {
  const RpcErrorFailure({
    required this.method,
    required this.code,
    required this.nodeMessage,
    this.data,
  });

  final String method;
  final int code;
  final String nodeMessage;
  final String? data;

  @override
  String get title => switch (code) {
    -32093 => 'Node is still syncing',
    -32092 => 'Compact block filters are disabled',
    -32096 => 'No wallet addresses to rescan',
    -32602 => 'The node rejected the input',
    -32601 => 'Not supported by this Floresta version',
    _ => 'The node returned an error',
  };

  @override
  String get message => data == null ? nodeMessage : '$nodeMessage: $data';

  @override
  String? get recovery => switch (code) {
    -32093 => 'Wait for initial block download to finish, then try again.',
    -32092 =>
      'Wallet rescans need compact block filters. Restart the node without '
          'the "disable compact block filters" option.',
    -32096 => 'Import a descriptor first.',
    -32601 => 'Update Floresta to a newer version.',
    _ => null,
  };

  @override
  List<Object?> get props => [method, code, nodeMessage, data];
}

final class ElectrumUnavailableFailure extends Failure {
  const ElectrumUnavailableFailure(this.endpoint, this.detail);

  final String endpoint;
  final String detail;

  @override
  String get title => 'Wallet server not reachable';
  @override
  String get message => 'Could not talk to the Electrum server at $endpoint.';
  @override
  String get recovery =>
      'Make sure the node is running. Balances shown may be out of date.';

  @override
  List<Object?> get props => [...super.props, detail];
}

final class ElectrumProtocolFailure extends Failure {
  const ElectrumProtocolFailure(this.method, this.detail);

  final String method;
  final String detail;

  @override
  String get title => 'Unexpected wallet server response';
  @override
  String get message => '"$method" returned data this app cannot use.';

  @override
  List<Object?> get props => [...super.props, detail];
}

/// The Electrum server answered a request with an error object.
final class ElectrumServerErrorFailure extends Failure {
  const ElectrumServerErrorFailure(this.method, this.code, this.serverMessage);

  final String method;
  final int code;
  final String serverMessage;

  @override
  String get title => 'The Electrum server returned an error';
  @override
  String get message => serverMessage;

  @override
  List<Object?> get props => [method, code, serverMessage];
}

/// The server or node is on a different chain than the wallet expects.
/// Syncing is refused so data from two chains is never mixed.
final class ChainMismatchFailure extends Failure {
  const ChainMismatchFailure(this.detail);

  final String detail;

  @override
  String get title => 'Wrong network';
  @override
  String get message => detail;
  @override
  String get recovery =>
      'Check that the node and the wallet use the same network in Settings.';
}

/// A managed-installation step failed. [stage] is one of resolve, download,
/// verify, install, recover.
final class InstallationFailure extends Failure {
  const InstallationFailure({
    required this.stage,
    required this.message,
    this.recovery,
  });

  const InstallationFailure.manifest(String detail)
    : stage = 'resolve',
      message = 'The release information is invalid ($detail).',
      recovery = 'Nothing was installed. Try again later.';

  final String stage;
  @override
  String get title => switch (stage) {
    'resolve' => 'Could not find a Floresta release',
    'download' => 'Download failed',
    'verify' => 'Download could not be verified',
    'install' => 'Installation failed',
    _ => 'Installation problem',
  };
  @override
  final String message;
  @override
  final String? recovery;

  @override
  List<Object?> get props => [stage, message];
}
