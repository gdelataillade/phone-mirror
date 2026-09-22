import AppKit
import MirrorCore
import SwiftUI

@MainActor final class MirrorModel: ObservableObject {
  let recording = RecordingController()
  @Published var devices: [PhoneDevice] = []
  @Published var selection = ""
  @Published var discovering = false
  @Published private(set) var lifecycle = ConnectionLifecycle()
  @Published var status = "Ready when you are"
  @Published var error: String?
  @Published var hasPicture = false
  @Published var fps = 0
  @Published var dimensions = ""
  @Published private(set) var screenSize = CGSize(width: 1206, height: 2622)
  @Published private(set) var inputEpoch: UInt64 = 0
  @Published private(set) var fitWindowEpoch: UInt64 = 0
  @Published private(set) var isLandscape = false
  @Published private(set) var rotation = RotationRequest()
  @Published var rotationNotice: String?
  @Published var showingDiagnostics = false
  @Published var screenshotBusy = false
  @Published var screenshotNotice: String?
  @Published var screenshotError: String?
  // Defaults to muted: audio only starts once someone explicitly opts in.
  @Published var audioMuted: Bool =
    (UserDefaults.standard.object(forKey: "audioMuted") as? Bool)
    ?? true
  {
    didSet {
      UserDefaults.standard.set(audioMuted, forKey: "audioMuted")
      session?.setAudioMuted(audioMuted)
    }
  }
  @Published var audioVolume: Double =
    (UserDefaults.standard.object(forKey: "audioVolume")
      as? Double) ?? 0.7
  {
    didSet {
      UserDefaults.standard.set(audioVolume, forKey: "audioVolume")
      session?.setAudioVolume(Float(audioVolume))
    }
  }
  private(set) var diagnostics = ConnectionDiagnostics(
    started: ProcessInfo.processInfo.systemUptime)
  private var rotationLocked = false
  private(set) var session: NativeSession?
  private var timer: Timer?
  private var previousOrdinal: UInt64 = 0
  private var previousTime = ProcessInfo.processInfo.systemUptime
  private var watchdog = VideoWatchdog(started: ProcessInfo.processInfo.systemUptime)
  private var discoveryGeneration = UUID()
  private let makeSession: () -> NativeSession
  private var presence: USBPresenceMonitor?
  private var usbWasAbsent = false
  var onSessionClosed: (() -> Void)?
  private var observers: [NSObjectProtocol] = []
  var selected: PhoneDevice? { devices.first { $0.id == selection } }
  var diagnosticHealth: SessionHealth { session?.healthSnapshot() ?? diagnostics.lastSession }
  var diagnosticReport: String {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    return diagnostics.report(
      current: session?.healthSnapshot(), phase: lifecycle.phase,
      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "0.1.0",
      macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
      iOSVersion: selected?.version ?? "")
  }
  private func record(_ event: ConnectionDiagnostics.Event, health: SessionHealth? = nil) {
    diagnostics.record(event, now: ProcessInfo.processInfo.systemUptime, health: health)
  }
  var sessionID: UUID? { lifecycle.attempt?.id }
  var active: Bool { lifecycle.active }
  var closing: Bool { lifecycle.phase == .closing }
  var connecting: Bool { lifecycle.phase == .connecting }
  var connected: Bool { lifecycle.phase == .live }
  var canReconnect: Bool { lifecycle.desiredDevice != nil && lifecycle.phase != .sleeping }
  var canControl: Bool {
    guard connected, hasPicture, !rotation.isPending, session?.mailbox.latest() != nil else {
      return false
    }
    return !watchdog.expired(now: ProcessInfo.processInfo.systemUptime)
  }
  var connectionTitle: String {
    switch lifecycle.phase {
    case .sleeping: return "Ready after your Mac wakes"
    case .waiting: return "Reconnecting to your iPhone"
    case .closing:
      return lifecycle.desiredDevice == nil ? "Disconnecting…" : "Restoring the connection"
    case .connecting: return "Connecting to your iPhone"
    case .live: return "Waiting for your picture"
    case .idle: return error == nil ? "Your iPhone.\nRight here." : "Let’s reconnect."
    }
  }
  init(makeSession: @escaping () -> NativeSession = { NativeSession() }) {
    self.makeSession = makeSession
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.updateVideoState() }
    }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.releaseInputs() }
      })
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.sleep() }
      })
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.wake() }
      })
  }
  func refresh() {
    guard !discovering, !active else { return }
    discovering = true
    error = nil
    let current = UUID()
    discoveryGeneration = current
    NativeSession.discover { [weak self] result in
      Task { @MainActor in
        guard let self, self.discoveryGeneration == current else { return }
        self.discovering = false
        guard !self.active else { return }
        self.devices = result.devices
        self.error = result.error
        if !self.devices.contains(where: { $0.id == self.selection }) {
          self.selection = self.devices.first?.id ?? ""
        }
        self.status = self.devices.isEmpty ? "Connect your iPhone by USB" : "Ready to mirror"
      }
    }
  }
  func connect() {
    guard !active, !selection.isEmpty else { return }
    presence = USBPresenceMonitor(device: selection)
    usbWasAbsent = false
    execute(lifecycle.connect(device: selection))
  }
  func reconnectNow() {
    guard canReconnect else { return }
    record(.manualReconnect)
    error = nil
    execute(lifecycle.retryNow())
    if closing { status = "Reconnecting now…" }
  }
  private func execute(_ actions: [ConnectionLifecycle.Action]) {
    for action in actions {
      switch action {
      case .open(let attempt):
        record(.opening)
        // The lifecycle issues this only after the previous native worker has joined.
        let native = makeSession()
        session = native
        native.setAudioMuted(audioMuted)
        native.setAudioVolume(Float(audioVolume))
        error = nil
        rotation.cancel()
        rotationNotice = nil
        hasPicture = false
        fps = 0
        dimensions = ""
        previousOrdinal = 0
        previousTime = ProcessInfo.processInfo.systemUptime
        watchdog = VideoWatchdog(started: previousTime)
        status = "Opening USB connection…"
        native.event = { [weak self] kind, message in
          Task { @MainActor in
            self?.applyEvent(kind, message, attempt: attempt.id)
          }
        }
        native.start(device: attempt.device)
      case .close(let id):
        recording.stop()
        guard lifecycle.attempt?.id == id else { continue }
        hasPicture = false
        rotation.cancel()
        fps = 0
        session?.cancel()
        session?.mailbox.clear()
      }
    }
  }
  private func applyEvent(_ kind: UInt32, _ message: String, attempt: UUID) {
    guard lifecycle.attempt?.id == attempt else { return }
    switch kind {
    case 1:
      if connecting { status = message }
    case 3:
      guard !closing else { return }
      record(.nativeFailure)
      error = message
      status = "Connection interrupted · preparing to retry"
      execute(lifecycle.interrupt(attempt, now: ProcessInfo.processInfo.systemUptime))
    case 4:
      // NativeSession sends this only after input cleanup and pm_close complete.
      record(.closed, health: session?.healthSnapshot())
      recording.stop()
      session = nil
      hasPicture = false
      fps = 0
      execute(lifecycle.closed(attempt, now: ProcessInfo.processInfo.systemUptime))
      updateWaitingStatus()
      let completion = onSessionClosed
      onSessionClosed = nil
      completion?()
    case 5:
      guard rotation.isPending else { return }
      struct Reply: Decodable { let locked: Bool }
      rotationLocked =
        (try? JSONDecoder().decode(Reply.self, from: Data(message.utf8)))?.locked ?? false
      rotation.acknowledge(after: session?.mailbox.latest()?.ordinal ?? 0)
    case 6:
      guard rotation.isPending else { return }
      rotation.cancel()
      rotationNotice = message
    default: break
    }
  }
  func disconnect() {
    if active { record(.stopped) }
    presence = nil
    usbWasAbsent = false
    execute(lifecycle.disconnect())
    hasPicture = false
    error = nil
    status = closing ? "Disconnecting…" : "Disconnected"
  }
  private func sleep() {
    if active { record(.sleeping) }
    execute(lifecycle.sleep())
    hasPicture = false
    if active { status = "Paused while your Mac sleeps" }
  }
  private func wake() {
    if active { record(.waking) }
    execute(lifecycle.wake())
  }
  private func updateWaitingStatus() {
    switch lifecycle.phase {
    case .waiting:
      let remaining = max(
        1, Int(ceil((lifecycle.retryAt ?? 0) - ProcessInfo.processInfo.systemUptime)))
      status = "Retrying in \(remaining)s · connect USB and unlock iPhone"
    case .sleeping: status = "Paused while your Mac sleeps"
    case .idle: break
    default: break
    }
  }
  func fitWindow() { fitWindowEpoch &+= 1 }
  func rotate(clockwise: Bool = true) {
    guard canControl, let frame = session?.mailbox.latest() else { return }
    releaseInputs()
    rotationNotice = nil
    rotationLocked = false
    rotation.begin(
      orientation: frame.orientation, screen: frame.size,
      now: ProcessInfo.processInfo.systemUptime)
    if session?.send(clockwise ? 9 : 10) != true {
      rotation.cancel()
      rotationNotice = "Rotation could not be sent. Wait for the connection to recover."
    }
  }
  func releaseInputs() {
    inputEpoch &+= 1
    _ = session?.send(6)
  }
  func home() {
    guard canControl else { return }
    releaseInputs()
    _ = session?.send(5)
  }
  func appSwitcher() {
    guard canControl else { return }
    releaseInputs()
    _ = session?.send(8)
  }
  func spotlight() {
    guard canControl else { return }
    releaseInputs()
    _ = session?.send(11)
  }
  func controlCenter() {
    guard canControl else { return }
    releaseInputs()
    _ = session?.send(12)
  }
  func pasteText() {
    guard canControl, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
      NSSound.beep()
      return
    }
    // Paste releases native keys; reset the view's pending gestures and key state too.
    releaseInputs()
    if session?.paste(text) != true { NSSound.beep() }
  }
  func updateVideoState() {
    let now = ProcessInfo.processInfo.systemUptime
    // Drain attach/detach notifications before the retry timer; replug skips backoff.
    for _ in 0..<64 {
      let event = presence?.poll() ?? 0
      if event == 0 { break }
      if event == 2 {
        if !usbWasAbsent { record(.usbRemoved) }
        usbWasAbsent = true
        if let id = sessionID, connecting || connected {
          error = "USB disconnected. Reconnect the cable to resume."
          status = "Waiting for USB"
          execute(lifecycle.interrupt(id, now: now))
        }
      } else if event == 1 {
        if usbWasAbsent { record(.usbReturned) }
        if usbWasAbsent && (lifecycle.phase == .waiting || closing) {
          execute(lifecycle.retryNow())
        }
        usbWasAbsent = false
      } else if event == 3 {
        record(.usbMonitorUnavailable)
        presence = nil
      }
      // Monitor failure leaves the watchdog and timed retries available.
    }
    execute(lifecycle.tick(now: now))
    updateWaitingStatus()
    guard connecting || connected, let id = sessionID else { return }
    let frame = session?.mailbox.latest()
    watchdog.observe(frameAt: frame?.receivedAt)
    if let health = session?.healthSnapshot() { watchdog.observe(health: health, now: now) }
    if watchdog.expired(now: now) {
      record(connected ? .videoStalled : .startupTimeout)
      error = "Video stopped updating. Checking the USB connection and restarting the stream."
      status = "Restoring video…"
      execute(lifecycle.interrupt(id, now: now))
      return
    }
    guard let frame else {
      if hasPicture {
        releaseInputs()
        status = "Recovering decoded video…"
      }
      hasPicture = false
      fps = 0
      return
    }
    if connecting { record(.firstFrame) }
    lifecycle.frame(id, now: now)
    hasPicture = true
    let displaySize =
      ScreenPresentation(encoded: frame.size, rawOrientation: frame.orientation)?.size ?? frame.size
    if screenSize != displaySize { screenSize = displaySize }
    isLandscape = displaySize.width > displaySize.height
    if rotation.observe(
      ordinal: frame.ordinal, orientation: frame.orientation,
      screen: frame.size, now: now) == .timedOut
    {
      rotationNotice =
        rotationLocked
        ? "The iPhone kept its current orientation. Turn off Portrait Orientation Lock on the iPhone, then try an app that supports landscape."
        : "The iPhone kept its current orientation. Try an app that supports landscape, such as Safari. Some screens stay in portrait."
    }
    status =
      rotation.isPending
      ? "Rotating iPhone…"
      : InputGeometry(view: frame.size, screen: frame.size, rawOrientation: frame.orientation)
        == nil
        ? "Adjusting to rotation · touch paused" : "Live over USB"
    dimensions = "\(Int(displaySize.width)) × \(Int(displaySize.height))"
    fps = Int((Double(frame.ordinal - previousOrdinal) / max(0.1, now - previousTime)).rounded())
    previousOrdinal = frame.ordinal
    previousTime = now
  }
}
