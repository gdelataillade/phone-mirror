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
