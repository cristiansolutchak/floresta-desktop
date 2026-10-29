import 'package:flutter/material.dart';

/// Room the native window buttons take at the top-left of the window.
///
/// On macOS the title bar is transparent and the content runs underneath it
/// (`macos/Runner/MainFlutterWindow.swift`), so the close, minimise and zoom
/// buttons sit over the app: the top 28 px of the left edge stay free of
/// controls, and the buttons span about 72 px from the left. Elsewhere the
/// title bar is native and takes no room inside the app.
abstract final class WindowChrome {
  static double topInset(BuildContext context) =>
      Theme.of(context).platform == TargetPlatform.macOS ? 28 : 0;

  /// Width the macOS buttons need, so a compact sidebar never cuts them.
  static double controlsWidth(BuildContext context) =>
      Theme.of(context).platform == TargetPlatform.macOS ? 80 : 0;
}
