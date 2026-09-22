import Foundation

/// Allowlisted counters only. Device names, identifiers, error strings and media never enter reports.
public struct NativeHealth: Codable, Equatable, Sendable {
  public var stage = 0
  public var videoPackets: UInt64 = 0
  public var assembledFrames: UInt64 = 0
  public var queuedFrames: UInt64 = 0
  public var queueOverflows: UInt64 = 0
  public var discontinuities: UInt64 = 0
  public var refreshRequests: UInt64 = 0
  public var orientationQueries: UInt64 = 0
  public var orientationMaxMs: UInt64 = 0
  public var orientationFailures: UInt64 = 0
  public var maxPacketGapMs: UInt64 = 0
  public var lastPacketAgeMs: UInt64?
  public var feedbackFailures: UInt64 = 0
  public init() {}
  public var stageLabel: String {
    switch stage {
    case 1: return "USB connection"
    case 2: return "Developer services"
    case 3: return "Service discovery"
    case 4: return "Input services"
    case 5: return "Media negotiation"
    case 6: return "Video stream"
    default: return "Not started"
    }
  }
}

public struct SessionHealth: Equatable, Sendable {
  public var native = NativeHealth()
  public var decodedFrames: UInt64 = 0
  public var decoderErrors: UInt64 = 0
  public var skippedFrames: UInt64 = 0
  public var maxDecodeMs: UInt64 = 0
  public var maxOutputGapMs: UInt64 = 0
  public init() {}
  public var report: String {
    """
    Stage: \(native.stageLabel)
    Video packets: \(native.videoPackets)
    Last video packet age at sample: \(native.lastPacketAgeMs.map { "\($0) ms" } ?? "not received")
    Frames assembled / queued / decoded: \(native.assembledFrames) / \(native.queuedFrames) / \(decodedFrames)
    Encoded queue overflows: \(native.queueOverflows)
    Stream discontinuities: \(native.discontinuities)
    Keyframe requests: \(native.refreshRequests)
    Video feedback failures: \(native.feedbackFailures)
    Decoder errors / skipped outputs: \(decoderErrors) / \(skippedFrames)
    Maximum decode time: \(maxDecodeMs) ms
    Maximum packet / decoded-output gap: \(native.maxPacketGapMs) / \(maxOutputGapMs) ms
    Orientation queries / failures: \(native.orientationQueries) / \(native.orientationFailures)
    Maximum orientation query time: \(native.orientationMaxMs) ms
    """
  }
  public var guidance: String {
    if native.feedbackFailures > 0 {
      return "The USB video feedback path stopped responding. Reconnect the cable and retry."
    }
    if native.orientationFailures > 0 {
      return "The iPhone stopped answering orientation queries. Reconnect to restore controls."
    }
    if native.queueOverflows > 0 {
      return "Video arrived faster than it could be decoded. Close heavy workloads and retry."
    }
    if decoderErrors > 0 {
      return "Video decoding failed. Reconnect; include this report if it happens again."
    }
    if native.discontinuities > 0 {
      return
        "Incomplete or out-of-order video was detected. Try a direct USB connection and another cable."
    }
    if let age = native.lastPacketAgeMs, age >= 900 {
      return
        "Video is quiet. This can be normal on an unchanged screen. Recent device responses and frame counters determine whether reconnection is needed."
    }
    if native.stage == 2 {
      return "Unlock the iPhone, enable Developer Mode, and prepare it in Xcode’s Device Hub."
    }
    if native.stage == 1 {
      return
        "Connect with a data-capable USB cable, unlock the iPhone and accept Trust if prompted."
    }
    return
      "If video stops again, save this report after reconnection. It retains recent session counters."
  }
}

public struct ConnectionDiagnostics {
  public enum Event: String {
    case opening = "Opening connection"
    case firstFrame = "First decoded picture"
    case usbRemoved = "USB removed"
    case usbReturned = "USB returned"
    case usbMonitorUnavailable = "USB monitoring unavailable; timed recovery remains active"
    case videoStalled = "Decoded video stalled"
    case startupTimeout = "No first picture before timeout"
    case nativeFailure = "Native connection failed"
    case manualReconnect = "Manual reconnect requested"
    case stopped = "User stopped connection"
    case sleeping = "Mac sleeping"
    case waking = "Mac woke"
    case closed = "Session closed"
  }
  private struct Entry {
    let seconds: Int
    let event: Event
    let health: SessionHealth?
  }
  private let started: TimeInterval
  private var entries: [Entry] = []
  public private(set) var attempts = 0
  public private(set) var lastSession = SessionHealth()
  public init(started: TimeInterval) { self.started = started }
  public mutating func record(_ event: Event, now: TimeInterval, health: SessionHealth? = nil) {
    if event == .opening { attempts += 1 }
    if let health { lastSession = health }
    entries.append(Entry(seconds: max(0, Int(now - started)), event: event, health: health))
    if entries.count > 60 { entries.removeFirst(entries.count - 60) }
  }
  public func report(
    current: SessionHealth?, phase: ConnectionLifecycle.Phase,
    appVersion: String, macOSVersion: String, iOSVersion: String
  ) -> String {
    let history = entries.map {
      let line = "+\($0.seconds)s: \($0.event.rawValue)"
      return $0.health.map { line + "\n" + $0.report } ?? line
    }.joined(separator: "\n")
    return """
      iPhoneMirror connection diagnostics · format 1
      App: \(Self.version(appVersion)) · macOS: \(Self.version(macOSVersion)) · iOS: \(Self.version(iOSVersion))
      Transport: USB · State: \(phase) · Connection attempts: \(attempts)
      Counters are local observations, not end-to-end latency measurements.
      Gaps exclude startup and do not include Mac rendering time.
      No screen contents, typed text, clipboard, device names, identifiers, paths or raw errors are included.

      \(current == nil ? "Last session" : "Current session")
      \((current ?? lastSession).report)

      Recent events (up to 60, elapsed time since app launch)
      \(history.isEmpty ? "No connection attempts yet." : history)
      """
  }
  private static func version(_ value: String) -> String {
    guard value.count <= 32,
      value.range(of: #"^[0-9]+(?:\.[0-9]+){0,3}$"#, options: .regularExpression) != nil
    else { return "unknown" }
    return value
  }
}
