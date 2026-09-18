import CMirror
import Foundation

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
  private let queue = DispatchQueue(label: "PhoneMirror.native", qos: .userInteractive)
  private let beforeDecode: (() -> Void)?
  var event: ((UInt32, String) -> Void)?
  // The local diagnostic injects a slow consumer here; the app uses no hook.
  init(beforeDecode: (() -> Void)? = nil) { self.beforeDecode = beforeDecode }
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
              size: CGSize(
                width: Int(pm_event_value(item, 0)), height: Int(pm_event_value(item, 1))),
              sync: pm_event_value(item, 2) == 1, orientation: pm_event_value(item, 4))
            if produced { decodeFailures = 0 }
          } catch {
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
      handle = nil
      lock.unlock()
      pm_close(session)
      decoder.stop()
      mailbox.clear()
      event?(4, "Disconnected")
    }
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
