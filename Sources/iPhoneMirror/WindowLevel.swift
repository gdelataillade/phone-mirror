import AppKit
import MirrorCore
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
  let screenSize: CGSize
  let showBezel: Bool
  func makeNSView(context: Context) -> ChromeView { ChromeView() }
  func updateNSView(_ view: ChromeView, context: Context) {
    view.screenSize = screenSize
    view.showBezel = showBezel
    view.fitWindow()
  }

  final class ChromeView: NSView {
    var screenSize = CGSize.zero
    var showBezel = true
    private var fittedScreen = CGSize.zero
    private var fittedBezel: Bool?

    func fitWindow() {
      guard let window, screenSize.width > 0, screenSize.height > 0,
        fittedScreen != screenSize || fittedBezel != showBezel,
        !window.styleMask.contains(.fullScreen)
      else { return }
      let current = window.contentView?.bounds.size ?? bounds.size
      guard current.width > 0, current.height > TitleBarMetrics.chromeHeight else { return }
      fittedScreen = screenSize
      fittedBezel = showBezel
      let inset: CGFloat = showBezel ? 48 : 0
      let fitted = MirrorGeometry.phoneFrameSize(
        view: CGSize(width: current.width, height: current.height - TitleBarMetrics.chromeHeight),
        screen: screenSize, inset: inset / 2)
      let minimumHeight: CGFloat = screenSize.width > screenSize.height ? 360 : 580
      let scale = max(
        (fitted.width - inset) / screenSize.width,
        (360 - inset) / screenSize.width,
        (minimumHeight - TitleBarMetrics.chromeHeight - inset) / screenSize.height)
      let size = CGSize(
        width: screenSize.width * scale + inset,
        height: screenSize.height * scale + inset + TitleBarMetrics.chromeHeight)
      // Constrain the actual window, keeping its resize edges beside the visible
      // phone. Apply only when device geometry/bezel changes, never per layout pass.
      window.contentAspectRatio = size
      window.setContentSize(size)
    }

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
      fitWindow()
    }
  }
}
