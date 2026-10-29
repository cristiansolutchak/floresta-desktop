import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // The splash screen's deep teal (SplashColors.dark), so the window does
    // not flash another colour before Flutter's first frame.
    let splash = NSColor(srgbRed: 0x0D / 255, green: 0x2D / 255, blue: 0x2E / 255, alpha: 1)
    flutterViewController.backgroundColor = splash
    self.backgroundColor = splash
    var windowFrame = self.frame
    self.contentViewController = flutterViewController
    // Content sizes (the title bar comes on top). MainMenu.xib opens at
    // 800x600, below the minimum; start at 1280x820 (the dashboard's full
    // layout), fitted to the screen and centred, never below the minimum.
    let minimum = NSSize(width: 960, height: 640)
    let content = self.contentRect(forFrameRect: windowFrame).size
    if content.width < minimum.width || content.height < minimum.height {
      let visible = (self.screen ?? NSScreen.main)?.visibleFrame
        ?? NSRect(x: 0, y: 0, width: 1280, height: 860)
      let chrome = windowFrame.height - content.height
      let size = NSSize(
        width: max(minimum.width, min(1280, visible.width)),
        height: max(minimum.height, min(820, visible.height - chrome)))
      windowFrame = self.frameRect(forContentRect: NSRect(
        x: visible.midX - size.width / 2,
        y: visible.midY - (size.height + chrome) / 2,
        width: size.width, height: size.height))
    }
    self.setFrame(windowFrame, display: true)
    self.contentMinSize = minimum
    // Kept for the Window menu, Mission Control and accessibility; not drawn.
    self.title = "Floresta"
    // No visible title bar: the native close, minimise and zoom buttons sit
    // directly on the app, with no title, separator or second shade. The
    // content runs under the transparent bar, and the app keeps its top
    // 28 px (sidebar, setup frame) free of controls, so the buttons never
    // cover anything and the strip stays draggable like a title bar.
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.titlebarSeparatorStyle = .none
    self.styleMask.insert(.fullSizeContentView)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
