import 'package:equatable/equatable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../domain/installer.dart';
import 'installation_providers.dart';

/// The latest install attempt. Lives in a provider, not a widget, so leaving
/// the screen neither loses progress nor allows a second concurrent install.
class InstallRun extends Equatable {
  const InstallRun({this.progress, this.running = false});

  final InstallProgress? progress;
  final bool running;

  @override
  List<Object?> get props => [progress, running];
}

class InstallController extends Notifier<InstallRun> {
  @override
  InstallRun build() => const InstallRun();

  /// Starts an install unless one is already running. On success the
  /// installation is detected again, so the next step becomes available.
  Future<void> start() async {
    final installer = ref.read(installerProvider);
    if (state.running || installer == null) return;
    final platform = ref.read(hostPlatformProvider);
    state = const InstallRun(running: true);
    InstallProgress? last;
    await for (final p in installer.install(platform)) {
      if (!ref.mounted) return;
      last = p;
      state = InstallRun(progress: p, running: true);
    }
    if (!ref.mounted) return;
    state = InstallRun(progress: last, running: false);
    if (last is InstallCompleted) ref.invalidate(installationDetectionProvider);
  }

  void cancel() {
    if (state.running) ref.read(installerProvider)?.cancel();
  }
}

final installControllerProvider =
    NotifierProvider<InstallController, InstallRun>(InstallController.new);
