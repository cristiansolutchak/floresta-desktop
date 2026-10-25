/// Decides when an owed wallet rescan may be sent (WAL-06).
///
/// Adapted from Mandacaru's `WalletRescanGate` (MIT, © João Victor Sena):
/// wait [grace] after the chain is synced, back off geometrically on
/// failures (capped at [maxBackoff]), and give up after [maxAttempts] so an
/// unfixable failure cannot pin the wallet to "rescan pending" forever.
///
/// Differences forced by florestad v0.9.1: it exposes neither filter-sync
/// progress nor "rescan in progress" (Mandacaru reads fork-only RPC fields),
/// so the gate keys only on chain readiness, and a successful
/// `rescanblockchain` is final (the node runs it in the background and
/// returns at once). [clock] must be monotonic (e.g. a Stopwatch), so a
/// wall-clock change cannot fire or block the backoff.
class RescanGate {
  RescanGate({
    required Duration Function() clock,
    this.grace = const Duration(seconds: 60),
    this.maxAttempts = 10,
    this.maxBackoff = const Duration(minutes: 30),
  }) : _clock = clock;

  final Duration Function() _clock;
  final Duration grace;
  final int maxAttempts;
  final Duration maxBackoff;

  Duration? _syncedSince;
  Duration? _lastAttempt;
  int _failures = 0;

  int get failures => _failures;

  /// Call on every tick, also while nothing is owed, so the time spent
  /// synced keeps being tracked.
  bool shouldTrigger({required bool chainSynced}) {
    if (!chainSynced) {
      _syncedSince = null;
      return false;
    }
    final now = _clock();
    final since = _syncedSince ??= now;
    if (now - since < grace) return false;
    final last = _lastAttempt;
    if (last == null) return true;
    return now - last >= _backoff();
  }

  /// The node accepted the rescan; the attempt budget resets.
  void onTriggered() {
    _lastAttempt = _clock();
    _failures = 0;
  }

  /// The rescan was refused. True once the budget is spent: the caller
  /// should stop owing the rescan and tell the user.
  bool onFailed() {
    _lastAttempt = _clock();
    _failures++;
    return _failures >= maxAttempts;
  }

  Duration _backoff() {
    if (_failures <= 0) return grace;
    final doublings = _failures > 20 ? 20 : _failures;
    final scaled = grace * (1 << doublings);
    return scaled > maxBackoff ? maxBackoff : scaled;
  }
}
