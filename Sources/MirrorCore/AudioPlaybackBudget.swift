import Foundation

/// Bounds scheduled PCM frames; old completion callbacks cannot debit a new stream.
public final class AudioPlaybackBudget: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: UInt32
  private var frames: UInt32 = 0
  private var generation: UInt64 = 0
  private var invalidated = false

  public init(limit: UInt32) { self.limit = limit }

  public func reserve(_ count: UInt32) -> UInt64? {
    lock.lock()
    defer { lock.unlock() }
    guard !invalidated, count <= limit, frames <= limit - count else { return nil }
    frames += count
    return generation
  }

  public func complete(_ count: UInt32, generation expected: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    guard expected == generation else { return }
    frames -= min(frames, count)
  }

  public func invalidate() {
    lock.lock()
    defer { lock.unlock() }
    invalidated = true
  }

  public func takeInvalidation() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let result = invalidated
    invalidated = false
    return result
  }

  public func reset() {
    lock.lock()
    defer { lock.unlock() }
    generation &+= 1
    frames = 0
  }
}
