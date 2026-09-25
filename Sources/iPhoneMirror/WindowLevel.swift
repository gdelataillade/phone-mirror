import AppKit
import SwiftUI

/// Applies the preference to the mirror window, including before a phone connects.
struct MirrorWindowLevel: NSViewRepresentable {
  let alwaysOnTop: Bool

  func makeNSView(context: Context) -> LevelView {
    let view = LevelView()
    view.alwaysOnTop = alwaysOnTop
    return view
  }

  func updateNSView(_ view: LevelView, context: Context) {
    view.alwaysOnTop = alwaysOnTop
    view.applyLevel()
  }

  final class LevelView: NSView {
    var alwaysOnTop = false

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      applyLevel()
    }

    func applyLevel() {
      window?.level = alwaysOnTop ? .floating : .normal
    }
  }
}

/// Layout of the floating title bar above the phone, shared by the SwiftUI bar and window
/// fitting.
enum TitleBarMetrics {
  /// Transparent margin around the bar, leaving room for its shadow.
  static let margin: CGFloat = 6
  /// With the margin, fills the titlebar AppKit sizes for a unified toolbar, so the bar's
  /// center lines up with the traffic lights AppKit centers there.
  static let height: CGFloat = 40
  /// The bezel's own margin already separates it from the bar.
  static let gap: CGFloat = 0
  /// Room for the close, minimize and zoom buttons at the bar's leading edge.
  static let trafficLightsWidth: CGFloat = 80
  /// Everything above the phone area.
  static var chromeHeight: CGFloat { margin + height + gap }
}

/// Simulator-style window: no backing or system shadow, so only the title bar and the phone
/// are visible.
struct MirrorWindowChrome: NSViewRepresentable {
  func makeNSView(context: Context) -> ChromeView { ChromeView() }
  func updateNSView(_ view: ChromeView, context: Context) {}

  final class ChromeView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      window.isOpaque = false
      window.backgroundColor = .clear
      // The window shadow would outline the whole transparent rectangle; the bar and the
      // bezel draw their own.
      window.hasShadow = false
      // An empty unified toolbar makes AppKit give the titlebar the height of the bar below
      // and vertically center the traffic lights in it. AppKit lays the lights out again on
      // its own schedule, so moving them by hand does not stick.
      if window.toolbar == nil { window.toolbar = NSToolbar(identifier: "MirrorWindow") }
      window.toolbarStyle = .unified
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
    }
  }
}
