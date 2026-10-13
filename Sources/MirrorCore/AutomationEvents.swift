import Foundation

/// Bounded, payload-free connection history. Cursors survive device reconnects,
/// but are deliberately invalidated when the Mac app restarts.
public struct AutomationEvents {
  public struct Entry: Codable, Equatable {
    public let cursor: String
    public let type: String
    public let observedAt: TimeInterval
    public let monotonicSeconds: TimeInterval
    public let sessionID: String?
    public let transport: String?
  }
  public struct Page: Encodable {
    public let events: [Entry]
    public let nextCursor: String
    public let oldestCursor: String?
    public let gap: Bool
    public let lockState = "unknown"
  }
  private let generation: String
  private let capacity: Int
  private var sequence: UInt64 = 0
  private var entries: [(UInt64, Entry)] = []
  public init(capacity: Int = 256, generation: UUID = UUID()) {
    self.capacity = max(1, capacity)
    self.generation = generation.uuidString
  }
  public var cursor: String { "\(generation):\(sequence)" }
  public mutating func record(
    _ type: String, observedAt: TimeInterval, monotonicSeconds: TimeInterval,
    sessionID: String?, transport: String?
  ) {
    sequence += 1
    entries.append(
      (
        sequence,
        Entry(
          cursor: cursor, type: type, observedAt: observedAt, monotonicSeconds: monotonicSeconds,
          sessionID: sessionID, transport: transport)
      ))
    if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
  }
  public func read(after: String?, matching type: String? = nil) throws -> Page {
    var afterSequence: UInt64 = 0
    var gap = after == nil && (entries.first?.0 ?? 1) > 1
    if let after {
      let parsed = try Self.parseCursor(after)
      if parsed.0 != generation {
        gap = true
      } else {
        guard parsed.1 <= sequence else {
          throw AutomationFailure("Event cursor is ahead of history")
        }
        afterSequence = parsed.1
        if let first = entries.first { gap = afterSequence < first.0 - 1 }
      }
    }
    return Page(
      events: entries.filter { $0.0 > afterSequence && (type == nil || $0.1.type == type) }.map {
        $0.1
      },
      nextCursor: cursor, oldestCursor: entries.first?.1.cursor, gap: gap)
  }
  public static func parseCursor(_ cursor: String) throws -> (String, UInt64) {
    let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
      !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
      let sequence = UInt64(parts[1])
    else { throw AutomationFailure("Invalid event cursor") }
    return (id.uuidString, sequence)
  }
}

public struct AutomationEventQuery {
  public let afterCursor: String?
  public let event: String?
  public let timeoutSeconds: Double
  public init(_ query: [String: String]) throws {
    guard Set(query.keys).isSubset(of: ["afterCursor", "event", "timeoutSeconds"]) else {
      throw AutomationFailure("Unexpected event query parameter")
    }
    afterCursor = query["afterCursor"]
    if let afterCursor { _ = try AutomationEvents.parseCursor(afterCursor) }
    event = query["event"]
    if let event, !ConnectionDiagnostics.Event.allCases.contains(where: { $0.code == event }) {
      throw AutomationFailure("Unknown connection event")
    }
    guard let timeout = Double(query["timeoutSeconds"] ?? "0"),
      timeout.isFinite, (0...5).contains(timeout)
    else {
      throw AutomationFailure("timeoutSeconds must be between 0 and 5")
    }
    guard timeout == 0 || afterCursor != nil else {
      throw AutomationFailure("Waiting requires afterCursor; get eventCursor from status first")
    }
    timeoutSeconds = timeout
  }
}

/// Host-side freshness fence. A newer decoded frame is not proof of UI success.
public struct AutomationObservationGate {
  public let sessionID: UUID
  public let inputEpoch: UInt64
  public let frameID: UInt64
  public let confirmedAt: TimeInterval
  public init(sessionID: UUID, inputEpoch: UInt64, frameID: UInt64, confirmedAt: TimeInterval) {
    self.sessionID = sessionID
    self.inputEpoch = inputEpoch
    self.frameID = frameID
    self.confirmedAt = confirmedAt
  }
  public func status(
    sessionID: UUID?, inputEpoch: UInt64, canCapture: Bool,
    frameID: UInt64?, receivedAt: TimeInterval?
  ) -> String {
    guard sessionID == self.sessionID else { return "session_changed" }
    guard inputEpoch == self.inputEpoch else { return "cancelled" }
    guard canCapture, let frameID, let receivedAt,
      frameID > self.frameID, receivedAt > confirmedAt
    else { return "waiting" }
    return "fresh"
  }
}
