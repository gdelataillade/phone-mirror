import Foundation

/// Pure connection policy. Every open owns a new input queue and must follow a completed close.
public struct ConnectionLifecycle {
  public enum Phase: Equatable { case idle, connecting, live, closing, waiting, sleeping }
  public struct Attempt: Equatable {
    public let id: UUID
    public let device: String
  }
  public enum Action: Equatable {
    case open(Attempt)
    case close(UUID)
  }
  public private(set) var phase: Phase = .idle
  public private(set) var attempt: Attempt?
  public private(set) var desiredDevice: String?
  public private(set) var retryAt: TimeInterval?
  public private(set) var failures = 0
  private var sleeping = false
  private var liveSince: TimeInterval?
  private var interruptedAt: TimeInterval?
  private var retryImmediately = false
  public var active: Bool { desiredDevice != nil || attempt != nil }
  public init() {}

  public mutating func connect(device: String) -> [Action] {
    guard !active, !device.isEmpty else { return [] }
    desiredDevice = device
    failures = 0
    if sleeping {
      phase = .sleeping
      return []
    }
    return open()
  }
  public mutating func disconnect() -> [Action] {
    desiredDevice = nil
    retryAt = nil
    failures = 0
    retryImmediately = false
    return closeOrRest()
  }
  public mutating func sleep() -> [Action] {
    sleeping = true
    retryAt = nil
    retryImmediately = false
    return closeOrRest()
  }
  public mutating func wake() -> [Action] {
    sleeping = false
    guard desiredDevice != nil, attempt == nil else { return [] }
    return open()
  }
  public mutating func interrupt(_ id: UUID, now: TimeInterval) -> [Action] {
    guard attempt?.id == id, phase == .connecting || phase == .live else { return [] }
    phase = .closing
    liveSince = nil
    interruptedAt = now
    return [.close(id)]
  }
  /// Manual retry or a returning USB cable can bypass backoff, but never overlap sessions.
  public mutating func retryNow() -> [Action] {
    guard desiredDevice != nil, !sleeping else { return [] }
    failures = 0
    retryAt = nil
    if let attempt {
      retryImmediately = true
      guard phase != .closing else { return [] }
      phase = .closing
      liveSince = nil
      return [.close(attempt.id)]
    }
    return open()
  }
  public mutating func closed(_ id: UUID, now: TimeInterval) -> [Action] {
    guard attempt?.id == id else { return [] }
    attempt = nil
    liveSince = nil
    guard desiredDevice != nil else {
      phase = .idle
      return []
    }
    guard !sleeping else {
      phase = .sleeping
      return []
    }
    if retryImmediately { return open() }
    failures = min(failures + 1, 6)
    // Cleanup consumes the retry delay instead of adding another delay afterwards.
    retryAt = (interruptedAt ?? now) + [1.0, 2, 4, 8, 16, 30][failures - 1]
    phase = .waiting
    if let retryAt, now >= retryAt { return open() }
    return []
  }
  public mutating func frame(_ id: UUID, now: TimeInterval) {
    guard attempt?.id == id, phase == .connecting || phase == .live else { return }
    phase = .live
    if liveSince == nil { liveSince = now }
    // A single frame does not establish a stable connection or reset a failure loop.
    if now - (liveSince ?? now) >= 10 { failures = 0 }
  }
  public mutating func tick(now: TimeInterval) -> [Action] {
    guard phase == .waiting, !sleeping, let retryAt, now >= retryAt else { return [] }
    return open()
  }
  private mutating func open() -> [Action] {
    guard attempt == nil, let desiredDevice else { return [] }
    let next = Attempt(id: UUID(), device: desiredDevice)
    attempt = next
    retryAt = nil
    liveSince = nil
    interruptedAt = nil
    retryImmediately = false
    phase = .connecting
    return [.open(next)]
  }
  private mutating func closeOrRest() -> [Action] {
    liveSince = nil
    if let attempt {
      guard phase != .closing else { return [] }
      phase = .closing
      return [.close(attempt.id)]
    }
    phase = sleeping && desiredDevice != nil ? .sleeping : .idle
    return []
  }
}
