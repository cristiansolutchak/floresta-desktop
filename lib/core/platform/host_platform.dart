import 'dart:ffi' show Abi;

import 'package:equatable/equatable.dart';

enum HostOs {
  macos('macOS'),
  linux('Linux'),
  windows('Windows'),
  other('Unsupported OS');

  const HostOs(this.label);
  final String label;

  bool get isUnix => this == macos || this == linux;
}

enum CpuArch {
  arm64('arm64'),
  x64('x86_64'),
  other('unknown');

  const CpuArch(this.label);
  final String label;
}

/// How much upstream evidence exists that Floresta runs on a platform.
///
/// Source: `.github/workflows/rust.yml` cross-testing matrix
/// (ubuntu-latest, windows-latest, macos-latest). See
/// docs/research/floresta-capabilities.md §4.
enum UpstreamSupport {
  /// The upstream CI builds and tests on this OS/arch.
  ciTested,

  /// Plausible to build from source, but upstream CI does not cover it.
  untested,

  /// No known path to run florestad.
  unsupported,
}

class HostPlatform extends Equatable {
  const HostPlatform(this.os, this.arch);

  /// Derives the platform from the running Dart ABI.
  ///
  /// `Abi.current()` reports the architecture the app was compiled for, which
  /// on Apple Silicon under Rosetta is x64. That is the right answer here: it
  /// is the architecture a `florestad` binary must match to be spawned
  /// without translation surprises.
  factory HostPlatform.fromAbi(Abi abi) => switch (abi) {
    Abi.macosArm64 => const HostPlatform(HostOs.macos, CpuArch.arm64),
    Abi.macosX64 => const HostPlatform(HostOs.macos, CpuArch.x64),
    Abi.linuxArm64 => const HostPlatform(HostOs.linux, CpuArch.arm64),
    Abi.linuxX64 => const HostPlatform(HostOs.linux, CpuArch.x64),
    Abi.windowsArm64 => const HostPlatform(HostOs.windows, CpuArch.arm64),
    Abi.windowsX64 => const HostPlatform(HostOs.windows, CpuArch.x64),
    _ => const HostPlatform(HostOs.other, CpuArch.other),
  };

  factory HostPlatform.current() => HostPlatform.fromAbi(Abi.current());

  final HostOs os;
  final CpuArch arch;

  String get label => '${os.label} (${arch.label})';

  /// GitHub-hosted `macos-latest` runners are arm64 and `ubuntu-latest` /
  /// `windows-latest` are x64, so only those pairs count as CI-tested.
  UpstreamSupport get upstreamSupport => switch ((os, arch)) {
    (HostOs.macos, CpuArch.arm64) => UpstreamSupport.ciTested,
    (HostOs.linux, CpuArch.x64) => UpstreamSupport.ciTested,
    (HostOs.windows, CpuArch.x64) => UpstreamSupport.ciTested,
    (HostOs.other, _) || (_, CpuArch.other) => UpstreamSupport.unsupported,
    _ => UpstreamSupport.untested,
  };

  /// Executable file name of the daemon on this OS.
  String get florestadFileName =>
      os == HostOs.windows ? 'florestad.exe' : 'florestad';

  String get pathSeparator => os == HostOs.windows ? r'\' : '/';
  String get pathListSeparator => os == HostOs.windows ? ';' : ':';

  @override
  List<Object?> get props => [os, arch];
}
