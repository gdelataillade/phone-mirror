import MirrorCore
import SwiftUI

/// Decorative hardware frame. The stream already contains the camera cutout.
struct FramedMirror: View {
  @ObservedObject var model: MirrorModel
  let showBezel: Bool

  var body: some View {
    GeometryReader { proxy in
      let inset: CGFloat = showBezel ? 24 : 0
      let available = CGSize(
        width: max(1, proxy.size.width - inset * 2),
        height: max(1, proxy.size.height - inset * 2))
      let fitted = MirrorGeometry.contentRect(view: available, screen: model.screenSize).size
      let size = showBezel ? fitted : proxy.size
      let radius = showBezel ? min(size.width, size.height) * 0.12 : 0
      MirrorSurface(model: model, cornerRadius: radius, bezelInset: inset * 2)
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
          }
        }
        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
    }
  }
}
