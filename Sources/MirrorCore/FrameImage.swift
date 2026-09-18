import CoreImage
import CoreVideo
import Foundation

/// The clean, upright stream image shared by presentation and screenshot export.
public enum FrameImage {
  public static func oriented(pixelBuffer: CVPixelBuffer, quarterTurns: Int) -> CIImage {
    var image = CIImage(cvPixelBuffer: pixelBuffer)
    let clean = CVImageBufferGetCleanRect(pixelBuffer)
    if clean.width > 0 && clean.height > 0 {
      image = image.cropped(to: clean).transformed(
        by: CGAffineTransform(translationX: -clean.minX, y: -clean.minY))
    }
    switch quarterTurns {
    case 1: return image.oriented(.right)
    case 2: return image.oriented(.down)
    case 3: return image.oriented(.left)
    default: return image
    }
  }

  public static func png(pixelBuffer: CVPixelBuffer, encoded: CGSize, rawOrientation: UInt32)
    -> Data?
  {
    guard let presentation = ScreenPresentation(encoded: encoded, rawOrientation: rawOrientation)
    else { return nil }
    let image = oriented(pixelBuffer: pixelBuffer, quarterTurns: presentation.clockwiseQuarterTurns)
    return CIContext(options: [.cacheIntermediates: false]).pngRepresentation(
      of: image, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
  }
}
