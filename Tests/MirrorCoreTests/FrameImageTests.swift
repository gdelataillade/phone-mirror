import CoreImage
import CoreVideo
import ImageIO
import XCTest

@testable import MirrorCore

final class FrameImageTests: XCTestCase {
  private func buffer(width: Int = 2, height: Int = 3) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        nil, width, height, kCVPixelFormatType_32BGRA,
        nil, &buffer), kCVReturnSuccess)
    let result = buffer!
    CVPixelBufferLockBaseAddress(result, [])
    let bytes = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(result)
    for y in 0..<height {
      for x in 0..<width {
        let i = y * stride + x * 4
        bytes[i] = 0
        bytes[i + 1] = 0
        bytes[i + 2] = UInt8((20 + (y * width + x) * 20) % 256)
        bytes[i + 3] = 255
      }
    }
    CVPixelBufferUnlockBaseAddress(result, [])
    return result
  }

  private func pixels(_ data: Data) throws -> (Int, Int, [UInt8]) {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let w = image.width
    let h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    bytes.withUnsafeMutableBytes { memory in
      let context = CGContext(
        data: memory.baseAddress, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (w, h, stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] })
  }

  func testPNGAllOrientationsActuallyRotatePixels() throws {
    let buffer = buffer()
    let expected: [[UInt8]] = [
      [20, 40, 60, 80, 100, 120],
      [120, 100, 80, 60, 40, 20],
      [40, 80, 120, 20, 60, 100],
      [100, 60, 20, 120, 80, 40],
    ]
    for raw in UInt32(0)...3 {
      let data = try XCTUnwrap(
        FrameImage.png(
          pixelBuffer: buffer,
          encoded: CGSize(width: 2, height: 3), rawOrientation: raw))
      let (w, h, values) = try pixels(data)
      XCTAssertEqual(w, raw >= 2 ? 3 : 2)
      XCTAssertEqual(h, raw >= 2 ? 2 : 3)
      XCTAssertEqual(values, expected[Int(raw)])
    }
  }

  func testAlreadyLandscapeIsNotRotatedAgain() throws {
    let buffer = buffer(width: 3, height: 2)
    for raw in UInt32(2)...3 {
      let data = try XCTUnwrap(
        FrameImage.png(
          pixelBuffer: buffer,
          encoded: CGSize(width: 3, height: 2), rawOrientation: raw))
      let (w, h, values) = try pixels(data)
      XCTAssertEqual(w, 3)
      XCTAssertEqual(h, 2)
      XCTAssertEqual(values, [20, 40, 60, 80, 100, 120])
    }
    XCTAssertNil(
      FrameImage.png(
        pixelBuffer: buffer,
        encoded: CGSize(width: 3, height: 2), rawOrientation: 0))
    XCTAssertNil(
      FrameImage.png(
        pixelBuffer: buffer,
        encoded: CGSize(width: 3, height: 2), rawOrientation: 99))
  }

  func testCleanApertureRemovesEncoderPadding() throws {
    let buffer = buffer(width: 4, height: 6)
    CVBufferSetAttachment(
      buffer, kCVImageBufferCleanApertureKey,
      [
        kCVImageBufferCleanApertureWidthKey: 2,
        kCVImageBufferCleanApertureHeightKey: 4,
        kCVImageBufferCleanApertureHorizontalOffsetKey: 0,
        kCVImageBufferCleanApertureVerticalOffsetKey: 0,
      ] as CFDictionary, .shouldPropagate)
    let data = try XCTUnwrap(
      FrameImage.png(
        pixelBuffer: buffer,
        encoded: CGSize(width: 2, height: 4), rawOrientation: 3))
    let (w, h, _) = try pixels(data)
    XCTAssertEqual(w, 4)
    XCTAssertEqual(h, 2)
  }
}
