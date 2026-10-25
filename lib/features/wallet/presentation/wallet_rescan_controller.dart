import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../node/domain/node_readiness.dart';
import '../../node/presentation/node_controller.dart';
import '../data/rescan_owed_store.dart';
import '../domain/rescan_gate.dart';
import 'wallet_controller.dart';

/// What the user sees about scheduled rescans.
class RescanSchedule extends Equatable {
  const RescanSchedule({
    this.owed = false,
    this.from,
    this.startedAt,
    this.gaveUp,
  });

  /// A rescan waits for the node to be synced.
  final bool owed;
  final int? from;

  /// When the node last accepted a rescan (it then runs in the background;
  /// florestad 0.9.1 reports neither progress nor completion).
  final DateTime? startedAt;

  /// Why the app stopped retrying, if it did.
  final String? gaveUp;

  @override
  List<Object?> get props => [owed, from, startedAt, gaveUp];
}

final rescanOwedStoreProvider = Provider<RescanOwedStore>(
  (ref) => RescanOwedStore(ref.watch(sharedPreferencesProvider)),
);

/// Monotonic time source for the gate; overridable in tests.
final rescanClockProvider = Provider<Duration Function()>((ref) {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
});

/// Sends owed rescans only once the node is synced (WAL-06): never during
/// sync (florestad refuses it), never twice at once, never forever.
class WalletRescanController extends Notifier<RescanSchedule> {
  static const tickEvery = Duration(seconds: 10);

  late RescanGate _gate;
  bool _inFlight = false;

  RescanOwedStore get _store => ref.read(rescanOwedStoreProvider);

  @override
  RescanSchedule build() {
    _gate = RescanGate(clock: ref.watch(rescanClockProvider));
    final timer = Timer.periodic(tickEvery, (_) => unawaited(tick()));
    ref.onDispose(timer.cancel);
    final owed = _store.read();
    return RescanSchedule(owed: owed != null, from: owed?.from);
  }

  /// Owes a rescan from [from] (null: from the start of the filters). It
  /// runs on a later [tick] once the node has been synced for a while.
  Future<void> request({int? from}) async {
    await _store.owe(from: from);
    state = RescanSchedule(owed: true, from: from);
  }

  Future<void> cancel() async {
    await _store.clear();
    state = const RescanSchedule();
  }

  /// One step of the schedule; called by the timer.
  Future<void> tick() async {
    final synced =
        ref.read(nodeReadinessProvider).stage == ReadinessStage.ready;
    final go = _gate.shouldTrigger(chainSynced: synced);
    if (!go || !state.owed || _inFlight) return;
    _inFlight = true;
    try {
      final result = await ref
          .read(walletRepositoryProvider)
          .rescan(fromHeight: state.from);
      if (!ref.mounted) return;
      await result.match(
        (failure) async {
          if (_gate.onFailed()) {
            await _store.clear();
            state = RescanSchedule(
              gaveUp:
                  '${failure.message} The app stopped retrying after '
                  '${_gate.maxAttempts} attempts.',
            );
          }
        },
        (_) async {
          _gate.onTriggered();
          await _store.clear();
          state = RescanSchedule(startedAt: DateTime.now());
        },
      );
    } finally {
      _inFlight = false;
    }
  }
}

final walletRescanProvider =
    NotifierProvider<WalletRescanController, RescanSchedule>(
      WalletRescanController.new,
    );
