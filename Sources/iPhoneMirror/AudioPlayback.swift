import AVFoundation
import AudioToolbox
import Foundation
import MirrorCore

// print() is stdout-buffered and can sit unflushed for a while when stdout isn't a
// terminal; stderr is not, so debug tracing goes through here instead.
func traceLog(_ message: @autoclosure () -> String) {
  FileHandle.standardError.write((message() + "\n").data(using: .utf8)!)
}

/// Decodes the device's system-audio RTP payloads and plays them live. The format
/// (AAC-ELD, 48kHz, stereo, 480-sample frames) isn't negotiated in the offer/answer;
/// it was confirmed by capturing and decoding a live stream, not derived from the protocol.
final class AudioPlayback {
  private static let sampleRate = 48000.0
  private static let channels: AVAudioChannelCount = 2
  private static let framesPerPacket: UInt32 = 480
  /// Below this, a packet is the device's silence/DTX placeholder, not real audio.
  private static let minimumRealPayload = 8

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let converter: AVAudioConverter
  private let outputFormat: AVAudioFormat
  private var started = false
  private let trace = ProcessInfo.processInfo.environment["PM_TRACE"] != nil
  private var decodedCount = 0
  // All engine/converter/player operations belong to NativeSession's audio loop.
  // Notification and completion callbacks only touch the synchronized budget.
  private let budget = AudioPlaybackBudget(limit: 9600)  // 200 ms at 48 kHz
  private var configurationObserver: NSObjectProtocol?
  private var muted = true

  func update(muted: Bool, volume: Float) {
    let configurationChanged = budget.takeInvalidation()
    if configurationChanged || (muted && !self.muted) { stop() }
    self.muted = muted
    player.volume = muted ? 0 : min(1, max(0, volume))
  }

  init?() {
    guard let inputFormat = Self.makeInputFormat() else {
      traceLog("AudioPlayback: could not build the AAC-ELD input format")
      return nil
    }
    guard
      let outputFormat = AVAudioFormat(
        standardFormatWithSampleRate: Self.sampleRate, channels: Self.channels)
    else {
      traceLog("AudioPlayback: could not build the PCM output format")
      return nil
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      traceLog("AudioPlayback: AVAudioConverter init failed for \(inputFormat) -> \(outputFormat)")
      return nil
    }
    self.outputFormat = outputFormat
    self.converter = converter
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [budget] _ in budget.invalidate() }
    if trace { traceLog("AudioPlayback: initialized, output=\(outputFormat)") }
  }

  private static func makeInputFormat() -> AVAudioFormat? {
    var description = AudioStreamBasicDescription(
      mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC_ELD, mFormatFlags: 0,
      mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0,
      mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
    return AVAudioFormat(streamDescription: &description)
  }

  /// One RTP payload, i.e. one complete AAC-ELD access unit — no reassembly needed.
  func decode(_ payload: Data) {
    guard !muted, payload.count >= Self.minimumRealPayload else { return }
    guard let compressed = try? makeCompressedBuffer(payload) else {
      if trace { traceLog("AudioPlayback: makeCompressedBuffer failed, \(payload.count) bytes") }
      return
    }
    guard
      let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: Self.framesPerPacket)
    else {
      if trace { traceLog("AudioPlayback: PCM buffer allocation failed") }
      return
    }
    var consumed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      guard !consumed else {
        status.pointee = .noDataNow
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return compressed
    }
    guard error == nil, output.frameLength > 0 else {
      if trace { traceLog("AudioPlayback: convert failed, error=\(String(describing: error))") }
      return
    }
    if !started {
      do {
        try engine.start()
        started = true
        if trace { traceLog("AudioPlayback: engine started") }
      } catch {
        traceLog("AudioPlayback: engine.start() failed: \(error)")
        return
      }
      player.play()
    }
    decodedCount += 1
    if trace, decodedCount == 1 {
      traceLog("AudioPlayback: first buffer decoded, frameLength=\(output.frameLength)")
    }
    let frames = output.frameLength
    guard let generation = budget.reserve(frames) else {
      // Prefer fresh audio to an accumulating delay after an output stall.
      stop()
      return
    }
    player.scheduleBuffer(output, completionCallbackType: .dataPlayedBack) { [budget] _ in
      budget.complete(frames, generation: generation)
    }
  }

  private func makeCompressedBuffer(_ payload: Data) throws -> AVAudioCompressedBuffer {
    guard let format = Self.makeInputFormat() else {
      throw DecodeFailure(operation: "Audio format", status: -1)
    }
    let buffer = AVAudioCompressedBuffer(
      format: format, packetCapacity: 1, maximumPacketSize: payload.count)
    payload.withUnsafeBytes { raw in
      buffer.data.copyMemory(from: raw.baseAddress!, byteCount: payload.count)
    }
    buffer.packetCount = 1
    buffer.byteLength = UInt32(payload.count)
    buffer.packetDescriptions?[0] = AudioStreamPacketDescription(
      mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(payload.count))
    return buffer
  }

  func stop() {
    budget.reset()
    player.stop()
    engine.stop()
    converter.reset()
    started = false
  }

  deinit {
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
  }
}
