import 'dart:io';

import 'host_platform.dart';

/// App-managed, per-user locations. Nothing here needs admin rights.
///
/// Chain data is deliberately NOT under this root: florestad keeps its own
/// data directory (default `~/.floresta` or the user's choice), which
/// install, upgrade and uninstall never touch.
class AppPaths {
  const AppPaths(this.root);

  /// Resolves the per-OS default, or `FLORESTA_GUI_DATA_ROOT` when set (used
  /// to isolate desktop installation tests from the real user data).
  factory AppPaths.forPlatform(
    HostPlatform platform,
    Map<String, String> environment,
  ) {
    final override = environment['FLORESTA_GUI_DATA_ROOT'];
    if (override != null && override.isNotEmpty) {
      return AppPaths(Directory(override));
    }
    final home = environment['HOME'] ?? environment['USERPROFILE'] ?? '.';
    final path = switch (platform.os) {
      HostOs.macos =>
        '$home/Library/Application Support/io.github.cristiansolutchak.florestaGui',
      HostOs.windows =>
        '${environment['LOCALAPPDATA'] ?? '$home\\AppData\\Local'}\\floresta-gui',
      HostOs.linux || HostOs.other =>
        '${environment['XDG_DATA_HOME'] ?? '$home/.local/share'}/floresta-gui',
    };
    return AppPaths(Directory(path));
  }

  final Directory root;

  String get _sep => Platform.pathSeparator;

  /// `<root>/floresta`: everything the installer owns.
  Directory get floresta => Directory('${root.path}${_sep}floresta');

  /// `<root>/floresta/versions/<version>/` holds one installed binary each.
  Directory get versions => Directory('${floresta.path}${_sep}versions');

  Directory versionDir(String version) =>
      Directory('${versions.path}$_sep$version');

  /// Downloads in progress (resumable `.part` files) and staged binaries.
  Directory get staging => Directory('${floresta.path}$_sep.staging');

  /// Pointer to the active managed install, replaced atomically.
  File get currentPointer => File('${floresta.path}${_sep}current.json');

  /// `<root>/floresta/trust.json`: highest accepted manifest serial and
  /// revoked signing keys (anti-rollback state).
  File get trustRecord => File('${floresta.path}${_sep}trust.json');

  /// `<root>/updates/`: app update packages, unpacked bundles, the swap
  /// helper and its result record.
  Directory get updates => Directory('${root.path}${_sep}updates');

  /// Anti-rollback state for app update manifests, kept apart from
  /// florestad's [trustRecord] (separate serial sequences).
  File get appTrustRecord => File('${updates.path}${_sep}trust.json');

  /// `<root>/wallet/<network>/`: the watch-only wallet's synced public chain
  /// data, one JSON file per account. Never keys.
  Directory walletStore(String network) =>
      Directory('${root.path}${_sep}wallet$_sep$network');

  /// `<root>/floresta/node.json`: identity of the florestad this app is
  /// running, so it can be found again after the app restarts.
  File get nodeRecord => File('${floresta.path}${_sep}node.json');
}
