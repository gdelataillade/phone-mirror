import CMirror
import Foundation

// Explicit, local device diagnostic. Does not send input or save screen contents.
func argument(_ key: String, default fallback: Double) -> Double {
  guard let index = CommandLine.arguments.firstIndex(of: key),
    CommandLine.arguments.indices.contains(index + 1),
    let value = Double(CommandLine.arguments[index + 1]), value.isFinite, value >= 0
  else { return fallback }
  return value
}
let duration = min(1800, max(10, argument("--seconds", default: 30)))
let pauseAt = argument("--pause-at", default: .infinity)
let pauseFor = min(3, argument("--pause-for", default: 1))
guard let listText = pm_devices() else {
  print("USB discovery failed")
  exit(2)
}
let list = try JSONDecoder().decode(DeviceList.self, from: Data(String(cString: listText).utf8))
pm_string_free(listText)
guard let device = list.devices.first else {
  print("No USB iPhone available")
  exit(2)
}
guard let session = device.id.withCString({ pm_start($0) }) else { exit(2) }
let mailbox = FrameMailbox()
let decoder = HEVCDecoder(mailbox: mailbox)
let began = ProcessInfo.processInfo.systemUptime
var lastOutput = began
var lastReport = began
var assembled = 0
var decoded = 0
var errors = 0
var skipped = 0
var failed = false
var paused = false
var resumed = false
var pauseEnded = 0.0
var maxGap = 0.0
while ProcessInfo.processInfo.systemUptime - began < duration {
  let now = ProcessInfo.processInfo.systemUptime
  if !paused && now - began >= pauseAt {
    print("Pausing encoded consumer for \(pauseFor)s")
    fflush(stdout)
    Thread.sleep(forTimeInterval: pauseFor)
    paused = true
    pauseEnded = ProcessInfo.processInfo.systemUptime
  }
  guard let event = pm_poll(session, 100) else { continue }
  let kind = pm_event_kind(event)
  if kind == 2 {
    assembled += 1
    let data = (0..<4).map { part -> Data in
      var length = 0
      guard let bytes = pm_event_data(event, UInt32(part), &length) else { return Data() }
      return Data(bytes: bytes, count: length)
    }
    do {
      guard data.allSatisfy({ !$0.isEmpty }) else {
        throw DecodeFailure(operation: "Missing frame data", status: -1)
      }
      if try decoder.decode(
        bytes: data[0], sets: Array(data.dropFirst()),
        size: CGSize(width: Int(pm_event_value(event, 0)), height: Int(pm_event_value(event, 1))),
        sync: pm_event_value(event, 2) == 1, orientation: pm_event_value(event, 4)
      ) {
        decoded += 1
        let outputTime = ProcessInfo.processInfo.systemUptime
        maxGap = max(maxGap, outputTime - lastOutput)
        lastOutput = outputTime
        // A queued frame immediately after the pause is not proof of recovery.
        if paused && outputTime - pauseEnded > 3 { resumed = true }
      } else {
        skipped += 1
      }
    } catch {
      errors += 1
      print(error.localizedDescription)
      decoder.stop()
      _ = pm_command(session, 7, 0, 0)
    }
  } else {
    var length = 0
    if let bytes = pm_event_data(event, 0, &length) {
      print(kind, String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self))
    }
    if kind == 3 { failed = true }
  }
  pm_event_free(event)
  if now - lastReport >= 5 {
    print(
      "elapsed=\(Int(now - began))s assembled=\(assembled) decoded=\(decoded) errors=\(errors) skipped=\(skipped)"
    )
    fflush(stdout)
    lastReport = now
  }
  if kind == 4 { break }
}
pm_close(session)
decoder.stop()
print(
  "Finished: decoded=\(decoded) errors=\(errors) maximumOutputGap=\(maxGap)s pauseRecovered=\(resumed)"
)
exit(failed || errors > 0 || decoded == 0 || (paused && !resumed) ? 1 : 0)
