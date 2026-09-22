import CoreImage
import CoreVideo
import Foundation

/// The clean, upright stream image shared by presentation and screenshot export.
public enum FrameImage {
  /// The device's HEVC screen-capture encoder pads its coded picture to CTU-aligned
  /// dimensions but does not signal this via the standard HEVC conformance window
  /// (SPS conformance_window_flag=0), so neither VideoToolbox nor clean-rect metadata
  /// reflects it. Confirmed empirically against a real device: a solid-black band of
  /// exactly this many pixels is baked into the decoded picture's right and bottom
  /// edges, in the natural-portrait buffer (before any rotation is applied).
  private static let encoderPaddingRight: CGFloat = 10
  private static let encoderPaddingBottom: CGFloat = 32

  /// The true content size for a raw encoded (pre-rotation, pre-crop) picture size,
  /// with the encoder's CTU padding removed. Callers that report the stream's pixel
  /// dimensions (for display scaling and touch-coordinate mapping) should use this
  /// instead of the raw SPS-derived size, to stay consistent with `oriented(...)`.
  public static func trueEncodedSize(_ encoded: CGSize) -> CGSize {
    let width = encoded.width - encoderPaddingRight
    let height = encoded.height - encoderPaddingBottom
    guard width > 0, height > 0 else { return encoded }
    return CGSize(width: width, height: height)
  }

  public static func oriented(pixelBuffer: CVPixelBuffer, quarterTurns: Int) -> CIImage {
    var image = CIImage(cvPixelBuffer: pixelBuffer)
    let clean = CVImageBufferGetCleanRect(pixelBuffer)
    if clean.width > 0 && clean.height > 0 {
      image = image.cropped(to: clean).transformed(
        by: CGAffineTransform(translationX: -clean.minX, y: -clean.minY))
    }
    let trueWidth = image.extent.width - encoderPaddingRight
    let trueHeight = image.extent.height - encoderPaddingBottom
    if trueWidth > 0 && trueHeight > 0 {
      let trimmed = CGRect(
        x: image.extent.minX, y: image.extent.minY + encoderPaddingBottom, width: trueWidth,
        height: trueHeight)
      image = image.cropped(to: trimmed).transformed(
        by: CGAffineTransform(translationX: -trimmed.minX, y: -trimmed.minY))
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
