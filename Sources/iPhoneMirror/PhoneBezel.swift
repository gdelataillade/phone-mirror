import MirrorCore
import SwiftUI

/// The phone floating in the transparent window: its screen aspect-fitted to the available
/// space, optionally inside a decorative hardware frame. The stream already contains the
/// camera cutout.
struct PhoneFrame<Screen: View>: View {
  let screenSize: CGSize
  let showBezel: Bool
  /// Builds the screen contents, given its corner radius and the total space (both sides
  /// combined) the bezel reserves around it.
  @ViewBuilder let screen: (_ cornerRadius: CGFloat, _ bezelInset: CGFloat) -> Screen

  var body: some View {
    GeometryReader { proxy in
      let inset: CGFloat = showBezel ? 24 : 0
      let available = CGSize(
        width: max(1, proxy.size.width - inset * 2),
        height: max(1, proxy.size.height - inset * 2))
      let size = MirrorGeometry.contentRect(view: available, screen: screenSize).size
      let radius = min(size.width, size.height) * 0.12
      screen(radius, inset * 2)
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .background {
          if showBezel {
            RoundedRectangle(cornerRadius: radius + 9, style: .continuous)
              .fill(Color(white: 0.045))
              .overlay {
                RoundedRectangle(cornerRadius: radius + 9, style: .continuous)
                  .strokeBorder(
                    LinearGradient(
                      colors: [Color(white: 0.65), Color(white: 0.18), Color(white: 0.42)],
                      startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2)
              }
              .padding(-9)
              .shadow(color: .black.opacity(0.5), radius: 7, y: 4)
              // Like Simulator, the hardware frame is a handle for moving the window.
              .gesture(WindowDragGesture())
              .allowsWindowActivationEvents(true)
          }
        }
        // Hug the title bar, like Simulator; spare height stays below, out of sight.
        .position(x: proxy.size.width / 2, y: inset + size.height / 2)
    }
  }
}
