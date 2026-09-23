import AVFoundation
import CoreImage
import Foundation

/// All writer operations run on one queue; a single pending frame bounds memory.
public final class VideoRecording: @unchecked Sendable {
  private let queue = DispatchQueue(label: "iPhoneMirror.recording", qos: .userInitiated)
  private let slot = DispatchSemaphore(value: 1)
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private let context = CIContext(options: [.cacheIntermediates: false])
  private let bounds: CGRect
  private var lastTime: Double = -1
  private let onFailure: ((Error) -> Void)?
  private var failure: Error? {
    didSet { if oldValue == nil, let failure { onFailure?(failure) } }
  }
  private var finished = false
  public let url: URL

  public init(url: URL, size: CGSize, onFailure: ((Error) -> Void)? = nil) throws {
    self.onFailure = onFailure
    self.url = url
    let width = max(2, Int(size.width) / 2 * 2)
    let height = max(2, Int(size.height) / 2 * 2)
    bounds = CGRect(x: 0, y: 0, width: width, height: height)
    writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: 8_000_000,
          AVVideoExpectedSourceFrameRateKey: 30, AVVideoMaxKeyFrameIntervalKey: 60,
        ],
      ])
    input.expectsMediaDataInRealTime = true
    adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ])
    guard writer.canAdd(input) else { throw Self.error("Video encoding is unavailable.") }
    writer.add(input)
    guard writer.startWriting() else {
      throw writer.error ?? Self.error("Could not start recording.")
    }
    writer.startSession(atSourceTime: .zero)
  }

  public func append(image: CIImage, seconds: Double) {
    guard seconds.isFinite, seconds >= 0, slot.wait(timeout: .now()) == .success else { return }
    queue.async { [self] in
      defer { slot.signal() }
      guard !finished, failure == nil, seconds > lastTime else { return }
      guard writer.status == .writing else {
        failure = writer.error ?? Self.error("Video encoding stopped.")
        return
      }
      guard input.isReadyForMoreMediaData else { return }
      autoreleasepool {
        var pixel: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
          CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess,
          let pixel
        else {
          failure = Self.error("Could not allocate a recording frame.")
          return
        }
        let scale = min(bounds.width / image.extent.width, bounds.height / image.extent.height)
        let fitted = image.transformed(
          by: CGAffineTransform(
            translationX: -image.extent.minX,
            y: -image.extent.minY)
        ).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
          .transformed(
            by: CGAffineTransform(
              translationX: (bounds.width - image.extent.width * scale) / 2,
              y: (bounds.height - image.extent.height * scale) / 2))
        let background = CIImage(color: .black).cropped(to: bounds)
        context.render(
          fitted.composited(over: background), to: pixel, bounds: bounds,
          colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        if adaptor.append(
          pixel, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600))
        {
          lastTime = seconds
        } else {
          failure = writer.error ?? Self.error("Could not encode a recording frame.")
        }
      }
    }
  }

  public func finish(seconds: Double, completion: @escaping (Result<URL, Error>) -> Void) {
    queue.async { [self] in
      guard !finished else { return }
      finished = true
      if let failure {
        writer.cancelWriting()
        completion(.failure(failure))
        return
      }
      guard lastTime >= 0 else {
        writer.cancelWriting()
        completion(.failure(Self.error("No video frames were recorded.")))
        return
      }
      writer.endSession(
        atSourceTime: CMTime(seconds: max(seconds, lastTime + 1.0 / 30), preferredTimescale: 600))
      input.markAsFinished()
      writer.finishWriting { [self] in
        completion(
          writer.status == .completed
            ? .success(url)
            : .failure(writer.error ?? Self.error("Could not finish recording.")))
      }
    }
  }

  private static func error(_ text: String) -> NSError {
    NSError(domain: "iPhoneMirror.Recording", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
  }
}
