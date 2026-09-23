import CMirror
import Foundation
import MirrorCore

struct PhoneDevice: Codable, Identifiable, Hashable {
  let id: String
  let name: String
  let version: String
  let transport: String
}
struct DeviceList: Codable {
  let devices: [PhoneDevice]
  let error: String?
}
// Matches pm_paste_image's `format` parameter (PhoneMirror.h) exactly.
enum ImageFormat: UInt32 {
  case png = 0
  case jpeg = 1
}

/// Main-actor owner; polling never waits for USB or device services.
final class USBPresenceMonitor {
  private var handle: OpaquePointer?
  init(device: String) { handle = device.withCString { pm_presence_start($0) } }
  func poll() -> Int32 { handle.map { pm_presence_poll($0) } ?? 0 }
  deinit { if let handle { pm_presence_close(handle) } }
}

/// A single-generation session. Only the pump owns destruction; send/cancel share a lock.
final class NativeSession: @unchecked Sendable {
  let mailbox = FrameMailbox()
  private let lock = NSLock()
  private var handle: OpaquePointer?
  private var cancelled = false
  private var health = SessionHealth()
  private var lastOutput: TimeInterval?
  private let queue = DispatchQueue(label: "iPhoneMirror.native", qos: .userInteractive)
  private let audioQueue = DispatchQueue(label: "iPhoneMirror.audio", qos: .userInteractive)
  // The video pump and the audio loop poll the same native handle independently and
  // on separate queues. pm_close frees it, so the pump must not call pm_close while
  // the audio loop might still be inside pm_poll_audio — entered/left around
  // startAudioLoop's whole body, and waited on before pm_close below.
  private let audioLoopFinished = DispatchGroup()
  private let beforeDecode: (() -> Void)?
  var event: ((UInt32, String) -> Void)?
  // Protected by `lock`: startAudioLoop assigns it once AudioPlayback exists, and
  // applies whatever was last requested here, whichever order those two happen in.
  private var audioPlayback: AudioPlayback?
  private var desiredAudioMuted = true
  private var desiredAudioVolume: Float = 0.7
  // The local diagnostic injects a slow consumer here; the app uses no hook.
  init(beforeDecode: (() -> Void)? = nil) { self.beforeDecode = beforeDecode }
  func setAudioMuted(_ muted: Bool) {
    lock.lock()
    desiredAudioMuted = muted
    audioPlayback?.muted = muted
    lock.unlock()
  }
  func setAudioVolume(_ volume: Float) {
    lock.lock()
    desiredAudioVolume = volume
    audioPlayback?.volume = volume
    lock.unlock()
  }
  func start(device: String) {
    queue.async { [self] in
      lock.lock()
      if cancelled {
        lock.unlock()
        event?(4, "Disconnected")
        return
      }
      handle = device.withCString { pm_start($0) }
      let session = handle
      lock.unlock()
      guard let session else {
        event?(3, "Could not create a native session.")
        event?(4, "Disconnected")
        return
      }
      startAudioLoop(session: session)
      let decoder = HEVCDecoder(mailbox: mailbox)
      var decodeFailures = 0
      var ended = false
      while !ended {
        lock.lock()
        let shouldStop = cancelled
        lock.unlock()
        if shouldStop { break }
        guard let item = pm_poll(session, 100) else { continue }
        let kind = pm_event_kind(item)
        if kind == 2 {
          beforeDecode?()
          let decodeStarted = ProcessInfo.processInfo.systemUptime
          let data = (0..<4).map { part -> Data in
            var length = 0
            guard let bytes = pm_event_data(item, UInt32(part), &length) else { return Data() }
            return Data(bytes: bytes, count: length)
          }
          do {
            guard data.dropFirst().allSatisfy({ !$0.isEmpty }) else {
              throw DecodeFailure(operation: "Missing codec data", status: -1)
            }
            let produced = try decoder.decode(
              bytes: data[0], sets: Array(data.dropFirst()),
              size: FrameImage.trueEncodedSize(
                CGSize(
                  width: Int(pm_event_value(item, 0)), height: Int(pm_event_value(item, 1)))),
              sync: pm_event_value(item, 2) == 1, orientation: pm_event_value(item, 4))
            if produced { decodeFailures = 0 }
            recordDecode(started: decodeStarted, produced: produced, failed: false)
          } catch {
            recordDecode(started: decodeStarted, produced: false, failed: true)
            decodeFailures += 1
            decoder.stop()
            mailbox.clear()
            _ = pm_command(session, 7, 0, 0)
            if decodeFailures >= 3 {
              event?(3, error.localizedDescription)
              ended = true
            }
          }
        } else {
          var length = 0
          let bytes = pm_event_data(item, 0, &length)
          let message =
            bytes.map {
              String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
            } ?? ""
          if kind != 4 { event?(kind, message) }
          if kind == 4 { ended = true }
        }
        pm_event_free(item)
      }
      lock.lock()
      readNativeHealth()
      handle = nil
      // Ended because the device disconnected, not because cancel() was called:
      // force the audio loop's own shouldStop check too, so it can't be left
      // waiting on its own terminal event while this thread frees the handle.
      cancelled = true
      lock.unlock()
      audioLoopFinished.wait()
      pm_close(session)
      decoder.stop()
      mailbox.clear()
      event?(4, "Disconnected")
    }
  }
  // Runs on its own queue against its own native poll: never waits on video decode.
  // Never calls pm_close — start(device:)'s video loop owns session teardown, and
  // waits on audioLoopFinished before calling it, so this loop must always be the
  // last thing touching `session` before that happens.
  private func startAudioLoop(session: OpaquePointer) {
    let trace = ProcessInfo.processInfo.environment["PM_TRACE"] != nil
    audioLoopFinished.enter()
    audioQueue.async {
      defer { self.audioLoopFinished.leave() }
      let playback = AudioPlayback()
      if playback == nil { traceLog("audio loop: AudioPlayback() returned nil") }
      self.lock.lock()
      playback?.muted = self.desiredAudioMuted
      playback?.volume = self.desiredAudioVolume
      self.audioPlayback = playback
      self.lock.unlock()
      var ended = false
      var received = 0
      while !ended {
        self.lock.lock()
        let shouldStop = self.cancelled
        self.lock.unlock()
        if shouldStop { break }
        guard let item = pm_poll_audio(session, 100) else { continue }
        let kind = pm_event_kind(item)
        if kind == 7 {
          received += 1
          if trace, received == 1 { traceLog("audio loop: first kind=7 event received") }
          var length = 0
          if let bytes = pm_event_data(item, 0, &length), length > 0 {
            playback?.decode(Data(bytes: bytes, count: length))
          }
        } else if kind == 4 {
          ended = true
        }
        pm_event_free(item)
      }
      if trace { traceLog("audio loop: ended, received \(received) kind=7 events") }
      playback?.stop()
      self.lock.lock()
      self.audioPlayback = nil
      self.lock.unlock()
    }
  }
  private func recordDecode(started: TimeInterval, produced: Bool, failed: Bool) {
    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    defer { lock.unlock() }
    health.maxDecodeMs = max(health.maxDecodeMs, UInt64(max(0, now - started) * 1000))
    if failed { health.decoderErrors += 1 } else if !produced { health.skippedFrames += 1 }
    if produced {
      health.decodedFrames += 1
      if let lastOutput {
        health.maxOutputGapMs = max(health.maxOutputGapMs, UInt64(max(0, now - lastOutput) * 1000))
      }
      lastOutput = now
    }
  }
  // Called with lock held; shares the handle lifetime with send/cancel/close.
  private func readNativeHealth() {
    guard let handle, let text = pm_health(handle) else { return }
    defer { pm_string_free(text) }
    if let native = try? JSONDecoder().decode(
      NativeHealth.self, from: Data(String(cString: text).utf8))
    {
      health.native = native
    }
  }
  func healthSnapshot() -> SessionHealth {
    lock.lock()
    defer { lock.unlock() }
    readNativeHealth()
    return health
  }
  @discardableResult func send(_ kind: UInt32, _ a: UInt32 = 0, _ b: UInt32 = 0) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled, let handle else { return false }
    return pm_command(handle, kind, a, b) == 1
  }
  func cancel() {
    lock.lock()
    cancelled = true
    if let handle { pm_cancel(handle) }
    lock.unlock()
  }
  func paste(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    guard !bytes.isEmpty, bytes.count <= 65536 else { return false }
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled, let handle else { return false }
    return bytes.withUnsafeBufferPointer { pm_paste(handle, $0.baseAddress, $0.count) == 1 }
  }
  // `data` must already be encoded as `format`; the native layer sends it to the
  // device pasteboard as-is under the matching UTI.
  func pasteImage(_ data: Data, format: ImageFormat) -> Bool {
    guard !data.isEmpty, data.count <= 15 * 1024 * 1024 else { return false }
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled, let handle else { return false }
    return data.withUnsafeBytes {
      pm_paste_image(
        handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, format.rawValue) == 1
    }
  }
  static func discover(completion: @escaping (DeviceList) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      guard let text = pm_devices() else {
        completion(DeviceList(devices: [], error: "USB discovery failed."))
        return
      }
      defer { pm_string_free(text) }
      let result =
        (try? JSONDecoder().decode(DeviceList.self, from: Data(String(cString: text).utf8)))
        ?? DeviceList(devices: [], error: "Invalid response from USB discovery.")
      completion(result)
    }
  }
}
