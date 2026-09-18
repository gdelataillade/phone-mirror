import AVFoundation
import CoreImage
import XCTest

@testable import MirrorCore

final class VideoRecordingTests: XCTestCase {
  func testMovieHasVideoNoAudioAndPreservesIdleDuration() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".mov")
    defer { try? FileManager.default.removeItem(at: url) }
    let recorder = try VideoRecording(url: url, size: CGSize(width: 64, height: 96))
    recorder.append(
      image: CIImage(color: CIColor(red: 1, green: 0, blue: 0))
        .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 96)), seconds: 0)
    // No further frames arrive on a static phone screen. Ending must preserve elapsed time.
    let result: Result<URL, Error> = await withCheckedContinuation { continuation in
      recorder.finish(seconds: 2) { continuation.resume(returning: $0) }
    }
    _ = try result.get()
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    XCTAssertEqual(duration.seconds, 2, accuracy: 0.05)
    let videos = try await asset.loadTracks(withMediaType: .video)
    let audios = try await asset.loadTracks(withMediaType: .audio)
    XCTAssertEqual(videos.count, 1)
    XCTAssertTrue(audios.isEmpty)
    let size = try await videos[0].load(.naturalSize)
    XCTAssertEqual(size, CGSize(width: 64, height: 96))
    let generator = AVAssetImageGenerator(asset: asset)
    let (image, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
    XCTAssertEqual(image.width, 64)
  }

  func testLandscapeFitsPortraitCanvasWithoutStretching() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".mov")
    defer { try? FileManager.default.removeItem(at: url) }
    let recorder = try VideoRecording(url: url, size: CGSize(width: 64, height: 96))
    recorder.append(
      image: CIImage(color: CIColor(red: 1, green: 0, blue: 0))
        .cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64)), seconds: 0)
    let result: Result<URL, Error> = await withCheckedContinuation { continuation in
      recorder.finish(seconds: 1) { continuation.resume(returning: $0) }
    }
    _ = try result.get()
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    let (image, _) = try await generator.image(at: .zero)
    var bytes = [UInt8](repeating: 0, count: 64 * 96 * 4)
    bytes.withUnsafeMutableBytes { raw in
      let context = CGContext(
        data: raw.baseAddress, width: 64, height: 96, bitsPerComponent: 8,
        bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 96))
    }
    XCTAssertLessThan(bytes[(5 * 64 + 32) * 4], 15)
    // Allow H.264 and color conversion rounding; the center remains red.
    XCTAssertGreaterThan(bytes[(48 * 64 + 32) * 4], 220)
    XCTAssertLessThan(bytes[(90 * 64 + 32) * 4], 15)
  }

  func testEmptyRecordingFailsInsteadOfClaimingSaved() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".mov")
    defer { try? FileManager.default.removeItem(at: url) }
    let recorder = try VideoRecording(url: url, size: CGSize(width: 64, height: 96))
    let result: Result<URL, Error> = await withCheckedContinuation { continuation in
      recorder.finish(seconds: 1) { continuation.resume(returning: $0) }
    }
    XCTAssertThrowsError(try result.get())
  }
}
