import AVFoundation
import AudioToolbox
import Foundation

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
  /// Muted skips decoding entirely, not just silences output: no work happens
  /// on the audio thread until the person opts in.
  var muted = true {
    didSet { player.volume = muted ? 0 : volume }
  }
  var volume: Float = 0.7 {
    didSet { if !muted { player.volume = volume } }
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
      started = true
      do {
        try engine.start()
        if trace { traceLog("AudioPlayback: engine started") }
      } catch {
        traceLog("AudioPlayback: engine.start() failed: \(error)")
      }
      player.play()
    }
    decodedCount += 1
    if trace, decodedCount == 1 {
      traceLog("AudioPlayback: first buffer decoded, frameLength=\(output.frameLength)")
    }
    player.scheduleBuffer(output, completionHandler: nil)
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
    player.stop()
    engine.stop()
  }
}
