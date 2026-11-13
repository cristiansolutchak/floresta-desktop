import 'dart:async';
import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/app_version.dart';
import '../../../core/build_flavor.dart';
import '../../../core/errors/failure.dart';
import '../../../core/providers.dart';
import '../../node/domain/node_process_state.dart';
import '../../node/presentation/node_controller.dart';
import '../data/app_updater.dart';
import '../data/artifact_downloader.dart';
import '../data/release_source.dart';
import '../data/update_preferences_store.dart';
import '../domain/app_update.dart';
import '../domain/installer.dart';
import 'install_controller.dart';
import 'installation_providers.dart';

/// Where an app update is.
enum AppUpdatePhase {
  idle,
  downloading,

  /// Downloaded, verified and unpacked; the swap waits for the app to quit
  /// (automatic updates) or is about to run ("Update now").
  ready,

  /// The `.deb` was handed to the system's installer.
  handedToSystem,

  /// Quitting to swap.
  restarting,
}

class UpdateCenter extends Equatable {
  const UpdateCenter({
    this.preferences = const UpdatePreferences(),
    this.kind = const NotUpdatable(''),
    this.checking = false,
    this.lastChecked,
    this.app,
    this.florestad,
    this.phase = AppUpdatePhase.idle,
    this.received,
    this.total,
    this.failure,
    this.updated,
    this.nodeRestartNeeded = false,
  });

  final UpdatePreferences preferences;
  final AppInstallKind kind;
  final bool checking;
  final DateTime? lastChecked;
  final AppUpdateOffer? app;
  final FlorestadUpdateOffer? florestad;
  final AppUpdatePhase phase;
  final int? received;
  final int? total;

  /// The last check or update failure, shown until the next attempt.
  final Failure? failure;

  /// Set once after an update: what the swap helper reported.
  final SwapResult? updated;

  /// A new florestad is installed while the old one still runs.
  final bool nodeRestartNeeded;

  /// Whether the notice should show now ("Later" hides an offer).
  bool visibleAt(DateTime now) =>
      updated != null ||
      nodeRestartNeeded ||
      phase != AppUpdatePhase.idle ||
      ((app != null || florestad != null) && !preferences.postponedAt(now));

  UpdateCenter copyWith({
    UpdatePreferences? preferences,
    AppInstallKind? kind,
    bool? checking,
    DateTime? lastChecked,
    Option<AppUpdateOffer>? app,
    Option<FlorestadUpdateOffer>? florestad,
    AppUpdatePhase? phase,
    Option<(int, int)>? progress,
    Option<Failure>? failure,
    Option<SwapResult>? updated,
    bool? nodeRestartNeeded,
  }) => UpdateCenter(
    preferences: preferences ?? this.preferences,
    kind: kind ?? this.kind,
    checking: checking ?? this.checking,
    lastChecked: lastChecked ?? this.lastChecked,
    app: app == null ? this.app : app.toNullable(),
    florestad: florestad == null ? this.florestad : florestad.toNullable(),
    phase: phase ?? this.phase,
    received: progress == null ? received : progress.toNullable()?.$1,
    total: progress == null ? total : progress.toNullable()?.$2,
    failure: failure == null ? this.failure : failure.toNullable(),
    updated: updated == null ? this.updated : updated.toNullable(),
    nodeRestartNeeded: nodeRestartNeeded ?? this.nodeRestartNeeded,
  );

  @override
  List<Object?> get props => [
    preferences,
    kind,
    checking,
    lastChecked,
    app,
    florestad,
    phase,
    received,
    total,
    failure,
    updated,
    nodeRestartNeeded,
  ];
}

/// The app updater for this build, or null without a release source.
final appUpdaterProvider = Provider<AppUpdater?>((ref) {
  final source = ref.watch(releaseSourceProvider);
  if (source == null) return null;
  return AppUpdater(
    paths: ref.watch(appPathsProvider),
    source: source,
    platform: ref.watch(hostPlatformProvider),
  );
});

final updatePreferencesStoreProvider = Provider<UpdatePreferencesStore>(
  (ref) => UpdatePreferencesStore(ref.watch(sharedPreferencesProvider)),
);

/// How this copy of the app can be updated.
final appInstallKindProvider = Provider<AppInstallKind>((ref) {
  final platform = ref.watch(hostPlatformProvider);
  return classifyAppInstall(
    os: platform.os,
    resolvedExecutable: Platform.resolvedExecutable,
    isWritable: _isWritable,
    releaseBuild: kReleaseMode,
    updatesEnabled:
        ref.watch(buildFlavorProvider) == BuildFlavor.production ||
        (ref
                .watch(releaseSourceProvider)
                ?.trustedKeys
                .any((k) => k.id == ReleaseSource.developmentKeyId) ??
            false),
  );
});

bool _isWritable(String folder) {
  try {
    final probe = File(
      '$folder${Platform.pathSeparator}.floresta-write-test-$pid',
    );
    probe.writeAsStringSync('');
    probe.deleteSync();
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Whether this build looks for app updates: release builds only, since a
/// debug run (`flutter run`) is updated from source. Overridden in tests.
final appUpdateChecksProvider = Provider<bool>((ref) => kReleaseMode);

/// Ends the process after an update is armed. Overridden in tests.
final appExitProvider = Provider<void Function()>(
  (ref) =>
      () => exit(0),
);

/// This process's id, which the swap helper waits on.
final processIdProvider = Provider<int>((ref) => pid);

final updateControllerProvider =
    NotifierProvider<UpdateController, UpdateCenter>(UpdateController.new);

/// Checks for updates of the app and of florestad when the app starts and
/// every [checkEvery] after, shows them, and installs them (ADR-0012).
class UpdateController extends Notifier<UpdateCenter> {
  static const startDelay = Duration(seconds: 8);
  static const checkEvery = Duration(hours: 12);
  static const postponeFor = Duration(hours: 24);

  CancelToken? _cancel;

  UpdatePreferencesStore get _store => ref.read(updatePreferencesStoreProvider);

  @override
  UpdateCenter build() {
    final first = Timer(startDelay, () => unawaited(check()));
    final periodic = Timer.periodic(checkEvery, (_) => unawaited(check()));
    ref.onDispose(() {
      first.cancel();
      periodic.cancel();
      _cancel?.cancel();
    });
    unawaited(Future.microtask(_afterRestart));
    return UpdateCenter(
      preferences: _store.load(),
      kind: ref.read(appInstallKindProvider),
    );
  }

  /// Reports the last swap and starts the node again if the update stopped
  /// it.
  Future<void> _afterRestart() async {
    final updater = ref.read(appUpdaterProvider);
    final result = await updater?.lastResult();
    if (!ref.mounted) return;
    if (result != null) {
      // The backup is deleted only once this version is the one running.
      final runningIt = result.version == appVersionText;
      if (runningIt || !result.ok) await updater!.finish(result);
      if (!ref.mounted) return;
      state = state.copyWith(updated: Some(result));
    }
    if (_store.resumeNode) {
      await _store.setResumeNode(false);
      if (!ref.mounted) return;
      final node = ref.read(nodeControllerProvider.notifier);
      if (ref.read(nodeControllerProvider).canStart) await node.start();
    }
  }

  /// Looks for updates now. Never installs anything unless automatic
  /// updates are on.
  Future<void> check() async {
    if (!ref.mounted || state.checking) return;
    state = state.copyWith(checking: true, failure: const None());
    final platform = ref.read(hostPlatformProvider);
    Failure? failure;

    AppUpdateOffer? app;
    final updater = ref.read(appUpdaterProvider);
    final kind = state.kind;
    if (updater != null && ref.read(appUpdateChecksProvider)) {
      final r = await updater.check(
        current: AppVersion.tryParse(appVersionText)!,
        kind: kind,
      );
      r.match((f) => failure = f, (offer) => app = offer);
    }

    FlorestadUpdateOffer? florestad;
    final Installer? installer = ref.read(installerProvider);
    if (installer != null) {
      final r = await installer.checkForUpdate(platform);
      r.match((f) => failure ??= f, (offer) => florestad = offer);
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      checking: false,
      lastChecked: DateTime.now(),
      app: Option.fromNullable(app),
      florestad: Option.fromNullable(florestad),
      failure: Option.fromNullable(failure),
    );
    if (state.preferences.autoInstall) await _installAutomatically();
  }

  /// Automatic mode: florestad is installed at once (the running node keeps
  /// its binary until it restarts); the app is downloaded, verified and
  /// swapped in when the user quits.
  Future<void> _installAutomatically() async {
    if (state.florestad != null) await installFlorestad();
    final kind = state.kind;
    if (state.app?.artifact != null &&
        kind is SelfUpdatable &&
        state.phase == AppUpdatePhase.idle &&
        !(ref.read(appUpdaterProvider)?.swapPending ?? true)) {
      await _downloadAndArm(relaunch: false);
    }
  }

  /// "Update now": downloads, verifies, then restarts into the new version
  /// (self-updating installs) or opens the system installer (`.deb`).
  Future<void> updateAppNow() async {
    final offer = state.app;
    final updater = ref.read(appUpdaterProvider);
    if (offer == null || updater == null) return;
    if (state.phase == AppUpdatePhase.ready && updater.swapPending) {
      await updater.requestRelaunch();
      await _quitForUpdate();
      return;
    }
    if (state.kind is SystemPackage) {
      final staged = await _download(offer, updater);
      if (staged == null) return;
      final opened = await updater.openSystemInstaller(staged);
      if (!ref.mounted) return;
      state = opened.match(
        (f) => state.copyWith(phase: AppUpdatePhase.idle, failure: Some(f)),
        (_) => state.copyWith(phase: AppUpdatePhase.handedToSystem),
      );
      return;
    }
    if (await _downloadAndArm(relaunch: true)) await _quitForUpdate();
  }

  Future<StagedUpdate?> _download(
    AppUpdateOffer offer,
    AppUpdater updater,
  ) async {
    final cancel = _cancel = CancelToken();
    state = state.copyWith(
      phase: AppUpdatePhase.downloading,
      progress: const Some((0, 0)),
      failure: const None(),
    );
    var shownAt = DateTime.now();
    final staged = await updater.download(
      offer,
      cancel: cancel,
      onProgress: (got, total) {
        final now = DateTime.now();
        if (!ref.mounted ||
            now.difference(shownAt) < const Duration(milliseconds: 200)) {
          return;
        }
        shownAt = now;
        state = state.copyWith(progress: Some((got, total)));
      },
    );
    if (!ref.mounted) return null;
    return staged.match((f) {
      state = state.copyWith(
        phase: AppUpdatePhase.idle,
        progress: const None(),
        failure: Some(f),
      );
      return null;
    }, (s) => s);
  }

  Future<bool> _downloadAndArm({required bool relaunch}) async {
    final offer = state.app;
    final updater = ref.read(appUpdaterProvider);
    final kind = state.kind;
    if (offer == null || updater == null || kind is! SelfUpdatable) {
      return false;
    }
    final staged = await _download(offer, updater);
    if (staged == null || !ref.mounted) return false;
    final armed = await updater.armSwap(
      staged,
      kind,
      pid: ref.read(processIdProvider),
      relaunch: relaunch,
    );
    if (!ref.mounted) return false;
    return armed.match(
      (f) {
        state = state.copyWith(phase: AppUpdatePhase.idle, failure: Some(f));
        return false;
      },
      (_) {
        state = state.copyWith(phase: AppUpdatePhase.ready);
        return true;
      },
    );
  }

  /// Stops our node cleanly (remembering to start it again), then quits so
  /// the armed helper can swap the app.
  Future<void> _quitForUpdate() async {
    state = state.copyWith(phase: AppUpdatePhase.restarting);
    final node = ref.read(nodeControllerProvider);
    final ours =
        node.process is ProcessRunning || node.process is ProcessAdopted;
    if (ours) {
      await _store.setResumeNode(true);
      await ref.read(nodeControllerProvider.notifier).stop();
    }
    ref.read(appExitProvider)();
  }

  void cancelDownload() => _cancel?.cancel();

  /// "Later": hides the offer for a day (it shows again at the next start
  /// after that, or from Settings at any time).
  Future<void> postpone() async {
    final next = UpdatePreferences(
      autoInstall: state.preferences.autoInstall,
      postponedUntil: DateTime.now().add(postponeFor),
    );
    await _store.save(next);
    if (ref.mounted) state = state.copyWith(preferences: next);
  }

  Future<void> setAutoInstall(bool value) async {
    final next = UpdatePreferences(
      autoInstall: value,
      postponedUntil: state.preferences.postponedUntil,
    );
    await _store.save(next);
    if (!ref.mounted) return;
    state = state.copyWith(preferences: next);
    if (value) await _installAutomatically();
  }

  /// Installs the newer florestad next to the running one. The node keeps
  /// its binary until it restarts, so nothing stops here.
  Future<void> installFlorestad() async {
    final install = ref.read(installControllerProvider.notifier);
    await install.start();
    if (!ref.mounted) return;
    final done = ref.read(installControllerProvider).progress;
    if (done is InstallCompleted) {
      final node = ref.read(nodeControllerProvider);
      state = state.copyWith(
        florestad: const None(),
        nodeRestartNeeded:
            node.process is ProcessRunning || node.process is ProcessAdopted,
      );
    } else if (done is InstallFailed) {
      state = state.copyWith(
        failure: Some(
          InstallationFailure(
            stage: 'install',
            message: done.reason,
            recovery: done.recovery,
          ),
        ),
      );
    }
  }

  /// Restarts the node on the newly installed florestad.
  Future<void> restartNode() async {
    final r = await ref.read(nodeControllerProvider.notifier).restart();
    if (!ref.mounted) return;
    state = r.match(
      (f) => state.copyWith(failure: Some(f)),
      (_) => state.copyWith(nodeRestartNeeded: false),
    );
  }

  /// Hides the "updated" note.
  void dismissUpdated() => state = state.copyWith(updated: const None());
}
