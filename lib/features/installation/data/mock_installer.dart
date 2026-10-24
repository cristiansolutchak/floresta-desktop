import '../../../core/platform/host_platform.dart';
import '../domain/installer.dart';

/// MOCK. Demonstrates the install state machine in the UI; installs nothing.
///
/// It exists so the installer screen can be built and tested behind the real
/// [Installer] interface before upstream publishes verifiable artifacts. It
/// always ends in [InstallFailed] with an explicit message, so it can never be
/// mistaken for a successful installation.
class MockInstaller implements Installer {
  const MockInstaller({this.stepDelay = const Duration(milliseconds: 400)});

  final Duration stepDelay;

  @override
  bool get isMock => true;

  @override
  bool supports(HostPlatform platform) =>
      platform.upstreamSupport != UpstreamSupport.unsupported;

  @override
  Stream<InstallProgress> install(HostPlatform platform) async* {
    yield const InstallResolving();
    await Future<void>.delayed(stepDelay);
    for (final f in const [0.25, 0.5, 0.75, 1.0]) {
      yield InstallDownloading(f);
      await Future<void>.delayed(stepDelay);
    }
    yield const InstallVerifying();
    await Future<void>.delayed(stepDelay);
    yield const InstallFailed(
      'Simulation only: nothing was downloaded or installed. Floresta does '
      'not publish signed binaries yet, so automatic installation is not '
      'available. Build from source instead.',
    );
  }
}
