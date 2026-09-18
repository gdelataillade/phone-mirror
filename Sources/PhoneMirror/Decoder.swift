import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct VideoFrame {
  let pixelBuffer: CVPixelBuffer
  let size: CGSize
  let receivedAt: TimeInterval
  let ordinal: UInt64
  let orientation: UInt32
}

/// Capacity-one decoded mailbox; the renderer never accumulates old pictures.
final class FrameMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var frame: VideoFrame?
  private var count: UInt64 = 0
  func put(_ pixelBuffer: CVPixelBuffer, size: CGSize, orientation: UInt32) {
    lock.lock()
    defer { lock.unlock() }
    count &+= 1
    frame = VideoFrame(
      pixelBuffer: pixelBuffer, size: size, receivedAt: ProcessInfo.processInfo.systemUptime,
      ordinal: count, orientation: orientation)
  }
  func latest() -> VideoFrame? {
    lock.lock()
    defer { lock.unlock() }
    return frame
  }
  func clear() {
    lock.lock()
    frame = nil
    lock.unlock()
  }
}

/// Confined to the backend pump queue. Decoder completion finishes before the next event is accepted.
final class HEVCDecoder {
  private var session: VTDecompressionSession?
  private var format: CMVideoFormatDescription?
  private var parameterSets: [Data] = []
  private let mailbox: FrameMailbox
  private var sequence: Int64 = 0
  init(mailbox: FrameMailbox) { self.mailbox = mailbox }
  deinit { stop() }
  func stop() {
    if let session {
      VTDecompressionSessionWaitForAsynchronousFrames(session)
      VTDecompressionSessionInvalidate(session)
    }
    session = nil
    format = nil
    parameterSets = []
  }
  @discardableResult
  func decode(bytes: Data, sets: [Data], size: CGSize, sync: Bool, orientation: UInt32 = 0) throws
    -> Bool
  {
    if sets != parameterSets {
      // A new decoder cannot use queued predicted pictures after a reset.
      guard sync else { return false }
      stop()
      var description: CMVideoFormatDescription?
      let result = sets[0].withUnsafeBytes { vps in
        sets[1].withUnsafeBytes { sps in
          sets[2].withUnsafeBytes { pps in
            let pointers = [
              vps.bindMemory(to: UInt8.self).baseAddress!,
              sps.bindMemory(to: UInt8.self).baseAddress!,
              pps.bindMemory(to: UInt8.self).baseAddress!,
            ]
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
              allocator: kCFAllocatorDefault, parameterSetCount: 3,
              parameterSetPointers: pointers, parameterSetSizes: sets.map(\.count),
              nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
          }
        }
      }
      try check(result, "HEVC configuration")
      guard let description else {
        throw DecodeFailure(operation: "Missing HEVC configuration", status: -1)
      }
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
      ]
      try check(
        VTDecompressionSessionCreate(
          allocator: kCFAllocatorDefault, formatDescription: description,
          decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
          decompressionSessionOut: &session), "Create decoder")
      if let session {
        try check(
          VTSessionSetProperty(
            session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue),
          "Configure decoder")
      }
      format = description
      parameterSets = sets
    }
    guard let format, let session else { return false }
    var block: CMBlockBuffer?
    try check(
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: bytes.count, flags: 0, blockBufferOut: &block), "Allocate sample")
    guard let block else { return false }
    try bytes.withUnsafeBytes { raw in
      try check(
        CMBlockBufferReplaceDataBytes(
          with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
          dataLength: bytes.count), "Copy sample")
    }
    sequence += 1
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: CMTime(value: sequence, timescale: 60),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    var length = bytes.count
    try check(
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &length, sampleBufferOut: &sample),
      "Create sample")
    guard let sample else { return false }
    let output = DecodeOutput()
    var flags = VTDecodeInfoFlags()
    let status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sample, flags: [], infoFlagsOut: &flags
    ) { status, _, image, _, _ in
      output.lock.lock()
      defer { output.lock.unlock() }
      output.status = status
      output.image = image
    }
    try check(status, "Decode frame")
    try check(VTDecompressionSessionWaitForAsynchronousFrames(session), "Finish frame")
    output.lock.lock()
    let image = output.image
    let result = output.status
    output.lock.unlock()
    try check(result, "Decode output")
    if let image { mailbox.put(image, size: size, orientation: orientation) }
    return image != nil
  }
  private func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw DecodeFailure(operation: operation, status: status) }
  }
}
private final class DecodeOutput: @unchecked Sendable {
  let lock = NSLock()
  var image: CVPixelBuffer?
  var status: OSStatus = 0
}
struct DecodeFailure: LocalizedError {
  let operation: String
  let status: OSStatus
  var errorDescription: String? { "\(operation) failed (\(status)). Reconnect to restart video." }
}
