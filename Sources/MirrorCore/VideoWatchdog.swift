import Foundation

/// Tracks decoded output even if the decoder clears its mailbox during recovery.
public struct VideoWatchdog {
  public static let staleAfter: TimeInterval = 1
  public static let startupTimeout: TimeInterval = 25
  private let started: TimeInterval
  private var lastFrame: TimeInterval?
  private var lastIdleHeartbeat: TimeInterval?
  private var orientationQueries: UInt64 = 0
  public init(started: TimeInterval) { self.started = started }
  public mutating func observe(frameAt: TimeInterval?) {
    if let frameAt { lastFrame = max(lastFrame ?? frameAt, frameAt) }
  }
  /// CoreDevice can stop sending pictures when the screen is unchanged. Only
  /// accept that silence with a NEW device response and a completely drained,
  /// error-free pipeline. Re-reading a cached health snapshot proves nothing.
  public mutating func observe(health: SessionHealth, now: TimeInterval) {
    let native = health.native
    guard native.stage == 6, health.decodedFrames > 0,
      native.queuedFrames == health.decodedFrames,
      native.assembledFrames == native.queuedFrames,
      native.queueOverflows == 0, native.discontinuities == 0, native.feedbackFailures == 0,
      health.decoderErrors == 0, native.orientationFailures == 0
    else {
      lastIdleHeartbeat = nil
      orientationQueries = native.orientationQueries
      return
    }
    if native.orientationQueries > orientationQueries,
      let age = native.lastPacketAgeMs, age >= 250
    {
      lastIdleHeartbeat = now
    }
    orientationQueries = native.orientationQueries
  }
  public func healthyIdle(now: TimeInterval) -> Bool {
    guard lastFrame != nil, let lastIdleHeartbeat else { return false }
    return now - lastIdleHeartbeat < Self.staleAfter
  }
  public func expired(now: TimeInterval) -> Bool {
    if let lastFrame { return now - lastFrame >= Self.staleAfter && !healthyIdle(now: now) }
    return now - started >= Self.startupTimeout
  }
}
