import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../node/domain/swift_sync.dart';
import 'bitcoin_network.dart';
import 'wallet_birthday.dart';

/// How a new node gets to the tip. Each is a set of launch options; which
/// ones a network offers depends on what upstream ships for it.
enum SyncMethod {
  /// Download a hints file, then validate blocks from the first one without
  /// Utreexo proofs up to the hints' height (`--no-assume-utreexo` plus
  /// `<network>.hints`). Needs a florestad with Swift Sync and a new data
  /// folder. See `swift_sync.dart`.
  swiftSync,

  /// Start from the Utreexo state built into Floresta (assume-utreexo).
  fastStart,

  /// Validate every block from the first one, with Utreexo proofs.
  full,
}

/// User-chosen configuration for launching and reaching florestad.
///
/// Contains no secrets by construction; it is safe to persist in plain
/// preferences.
class NodeSettings extends Equatable {
  const NodeSettings({
    this.onboardingComplete = false,
    this.executablePath,
    this.network = BitcoinNetwork.bitcoin,
    this.dataDir,
    this.rpcPort,
    this.logToFile = true,
    this.disableCompactFilters = false,
    this.walletBirthdayYear,
    this.assumeUtreexo = false,
    this.backfill = true,
    this.useExistingNode = false,
    this.swiftSync = true,
    this.hintsOrigin = defaultHintsOrigin,
  });

  final bool onboardingComplete;

  /// Explicit florestad path. Null means auto-detect.
  final String? executablePath;

  /// Mainnet by default (production builds); development builds and the
  /// advanced settings offer the test networks. See `BuildFlavor`.
  final BitcoinNetwork network;

  /// Base data directory passed as `--data-dir`. Null keeps florestad's own
  /// default (`$HOME/.floresta`). Florestad appends the network subdirectory.
  final String? dataDir;

  /// Overrides the network's default RPC port. Null uses the default.
  final int? rpcPort;

  final bool logToFile;
  final bool disableCompactFilters;

  /// Year the watched wallet was first used (mainnet). Bounds where compact
  /// filters, and so history searches, begin. Null: recent history only.
  final int? walletBirthdayYear;

  /// Start from the Utreexo state built into Floresta (on by default
  /// upstream). Off validates from genesis (`--no-assume-utreexo`). The
  /// app's default for a new node is [swiftSync] instead. Read [syncMethod], not this field:
  /// Swift Sync wins when both are set.
  final bool assumeUtreexo;

  /// Re-check the history skipped by [assumeUtreexo] in the background
  /// (`--no-backfill` turns it off). Only meaningful with [assumeUtreexo].
  final bool backfill;

  /// Connect to a florestad that runs elsewhere (Docker, a Nix service, a
  /// terminal) on `127.0.0.1:[effectiveRpcPort]` instead of running one.
  /// The app then never starts a node and needs no local executable; the
  /// launch options above do not apply.
  final bool useExistingNode;

  /// Download Swift Sync hints before a node's first start. Only
  /// on networks that have hints ([BitcoinNetwork.supportsSwiftSync]).
  final bool swiftSync;

  /// Where hints are downloaded from: `<hintsOrigin>/<network>`.
  final String hintsOrigin;

  SyncMethod get syncMethod {
    if (swiftSync && network.supportsSwiftSync) return SyncMethod.swiftSync;
    if (assumeUtreexo && network.assumeUtreexoHeight > 0) {
      return SyncMethod.fastStart;
    }
    return SyncMethod.full;
  }

  /// Settings for [method], leaving everything else as it is.
  NodeSettings withSyncMethod(SyncMethod method) => copyWith(
    swiftSync: method == SyncMethod.swiftSync,
    assumeUtreexo: method == SyncMethod.fastStart,
  );

  /// Pass assume-utreexo to florestad (otherwise `--no-assume-utreexo`).
  bool get usesAssumeUtreexo => syncMethod == SyncMethod.fastStart;

  /// Height accepted on trust at startup, or 0 when nothing is assumed.
  int get snapshotHeight => usesAssumeUtreexo ? network.assumeUtreexoHeight : 0;

  /// `--filters-start-height`, or null when filters are off or start at
  /// block 1 (see [WalletBirthday.filtersStartHeight]).
  int? get filtersStartHeight => disableCompactFilters
      ? null
      : WalletBirthday.filtersStartHeight(network, walletBirthdayYear);

  int get effectiveRpcPort => rpcPort ?? network.rpcPort;

  /// The Electrum server's port. Always the network's default: the app
  /// launches florestad without `--electrum-address`, so florestad listens
  /// on its own default, `127.0.0.1:<network port>` (`florestad.rs` at
  /// v0.9.1), and loopback only, by the security rules. Every screen reads
  /// it here, so an override (planned for v0.0.2, for nodes that run
  /// elsewhere on another port) changes one place.
  int get electrumPort => network.electrumPort;

  /// `127.0.0.1:<port>`, as wallets are told to connect.
  String get electrumAddress => '127.0.0.1:$electrumPort';

  Uri get rpcEndpoint => Uri.parse('http://127.0.0.1:$effectiveRpcPort/');

  /// The directory florestad actually writes to, mirroring upstream
  /// `datadir_path` in `bin/florestad/src/main.rs`.
  String effectiveDataDir({required String? homeDir, String separator = '/'}) {
    final base = dataDir ?? '${homeDir ?? '.'}$separator.floresta';
    final sub = network.dataSubdir;
    return sub == null ? base : '$base$separator$sub';
  }

  /// Validates user-editable fields before they are saved.
  Either<Failure, NodeSettings> validate() {
    final port = rpcPort;
    if (port != null && (port < 1024 || port > 65535)) {
      return const Left(
        ValidationFailure(
          'The RPC port must be between 1024 and 65535.',
          recovery: 'Leave it empty to use the network default.',
        ),
      );
    }
    final dir = dataDir;
    if (dir != null && !_isAbsolute(dir)) {
      // Upstream: "The passed value should be an absolute path."
      return const Left(
        ValidationFailure(
          'The data directory must be an absolute path.',
          recovery:
              'Choose a folder with the folder picker, or leave it '
              'empty to use the default.',
        ),
      );
    }
    final year = walletBirthdayYear;
    if (year != null &&
        (year < WalletBirthday.firstYear ||
            year > WalletBirthday.lastKnownYear)) {
      return const Left(
        ValidationFailure('The wallet start year is out of range.'),
      );
    }
    if (hintsOriginProblem(hintsOrigin) case final problem?) {
      return Left(
        ValidationFailure(
          'The Swift Sync hints address is not valid. $problem',
          recovery: 'Use the default, $defaultHintsOrigin.',
        ),
      );
    }
    final exe = executablePath;
    if (exe != null && !_isAbsolute(exe)) {
      return const Left(
        ValidationFailure('The executable path must be an absolute path.'),
      );
    }
    return Right(this);
  }

  static bool _isAbsolute(String path) =>
      path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

  NodeSettings copyWith({
    bool? onboardingComplete,
    Option<String>? executablePath,
    BitcoinNetwork? network,
    Option<String>? dataDir,
    Option<int>? rpcPort,
    bool? logToFile,
    bool? disableCompactFilters,
    Option<int>? walletBirthdayYear,
    bool? assumeUtreexo,
    bool? backfill,
    bool? useExistingNode,
    bool? swiftSync,
    String? hintsOrigin,
  }) {
    return NodeSettings(
      onboardingComplete: onboardingComplete ?? this.onboardingComplete,
      executablePath: executablePath == null
          ? this.executablePath
          : executablePath.toNullable(),
      network: network ?? this.network,
      dataDir: dataDir == null ? this.dataDir : dataDir.toNullable(),
      rpcPort: rpcPort == null ? this.rpcPort : rpcPort.toNullable(),
      logToFile: logToFile ?? this.logToFile,
      disableCompactFilters:
          disableCompactFilters ?? this.disableCompactFilters,
      walletBirthdayYear: walletBirthdayYear == null
          ? this.walletBirthdayYear
          : walletBirthdayYear.toNullable(),
      assumeUtreexo: assumeUtreexo ?? this.assumeUtreexo,
      backfill: backfill ?? this.backfill,
      useExistingNode: useExistingNode ?? this.useExistingNode,
      swiftSync: swiftSync ?? this.swiftSync,
      hintsOrigin: hintsOrigin ?? this.hintsOrigin,
    );
  }

  @override
  List<Object?> get props => [
    onboardingComplete,
    executablePath,
    network,
    dataDir,
    rpcPort,
    logToFile,
    disableCompactFilters,
    walletBirthdayYear,
    assumeUtreexo,
    backfill,
    useExistingNode,
    swiftSync,
    hintsOrigin,
  ];
}
