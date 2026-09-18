import Foundation

/// Tracks decoded output even if the decoder clears its mailbox during recovery.
public struct VideoWatchdog {
  public static let staleAfter: TimeInterval = 1
  public static let startupTimeout: TimeInterval = 25
  private let started: TimeInterval
  private var lastFrame: TimeInterval?
  public init(started: TimeInterval) { self.started = started }
  public mutating func observe(frameAt: TimeInterval?) {
    if let frameAt { lastFrame = max(lastFrame ?? frameAt, frameAt) }
  }
  public func expired(now: TimeInterval) -> Bool {
    if let lastFrame { return now - lastFrame >= Self.staleAfter }
    return now - started >= Self.startupTimeout
  }
}
