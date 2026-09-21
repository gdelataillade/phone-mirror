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

/// Lets the window's material blend with the desktop behind it instead of an opaque backing,
/// matching the translucent "Liquid Glass" look of native windows like Simulator.
struct WindowGlassBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> GlassView { GlassView() }
  func updateNSView(_ view: GlassView, context: Context) {}

  final class GlassView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window?.isOpaque = false
      window?.backgroundColor = .clear
    }
  }
}
