import CoreFoundation
import Foundation

public struct AutomationFailure: Error, LocalizedError {
  public let status: Int
  public let message: String
  public var errorDescription: String? { message }
  public init(_ message: String) { self.init(400, message) }
  public init(_ status: Int, _ message: String) {
    self.status = status
    self.message = message
  }
}

/// One bounded HTTP/1.1 request per connection. No chunking or pipelining.
public struct AutomationRequest {
  public let method: String
  public let path: String
  public let headers: [String: String]
  public let body: Data
  public static let maximumBody = 128 * 1024

  public static func parse(_ data: Data) throws -> AutomationRequest? {
    guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
      guard data.count <= 8192 else { throw AutomationFailure(413, "Headers too large") }
      return nil
    }
    guard end.lowerBound <= 8192,
      let header = String(data: data[..<end.lowerBound], encoding: .utf8)
    else { throw AutomationFailure(400, "Invalid headers") }
    let lines = header.components(separatedBy: "\r\n")
    let first = lines[0].components(separatedBy: " ")
    guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "POST"].contains(first[0]),
      first[1].hasPrefix("/"), !first[1].contains("#")
    else { throw AutomationFailure(400, "Expected GET or POST HTTP/1.1") }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t")
      else { throw AutomationFailure(400, "Invalid header") }
      let name = String(line[..<colon]).lowercased()
      guard !name.isEmpty,
        name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
        headers[name] == nil
      else { throw AutomationFailure(400, "Duplicate or invalid header") }
      headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    guard headers["transfer-encoding"] == nil, headers["expect"] == nil else {
      throw AutomationFailure(400, "Chunking and Expect are unsupported")
    }
    let length: Int
    if let value = headers["content-length"] {
      guard !value.isEmpty, value.allSatisfy({ $0 >= "0" && $0 <= "9" }),
        let parsed = Int(value), parsed <= maximumBody
      else { throw AutomationFailure(413, "Invalid or excessive Content-Length") }
      length = parsed
    } else {
      guard first[0] == "GET" else { throw AutomationFailure(411, "Content-Length required") }
      length = 0
    }
    let received = data.count - end.upperBound
    guard received <= length else { throw AutomationFailure(400, "Pipelining is unsupported") }
    guard received == length else { return nil }
    return AutomationRequest(
      method: first[0], path: first[1], headers: headers,
      body: Data(data[end.upperBound...]))
  }

  public func authorize(token: String, port: UInt16) throws {
    guard headers["origin"] == nil else {
      throw AutomationFailure(403, "Browser origins are not allowed")
    }
    guard headers["host"] == "127.0.0.1:\(port)" else {
      throw AutomationFailure(403, "Expected loopback Host")
    }
    guard headers["authorization"] == "Bearer \(token)" else {
      throw AutomationFailure(401, "Bearer token required")
    }
    if method == "POST" {
      guard
        headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
          .lowercased()
          == "application/json"
      else { throw AutomationFailure(415, "Expected application/json") }
    }
  }
}

public struct AutomationAction {
  public enum Operation: String {
    case tap, swipe, type, key, home
    case appSwitcher = "app_switcher"
    case spotlight
    case controlCenter = "control_center"
    case rotate, release
  }
  public let operation: Operation
  public let sessionID: String?
  public let observationID: String?
  public let x: Double
  public let y: Double
  public let toX: Double
  public let toY: Double
  public let duration: Double
  public let text: String
  public let key: UInt32
  public let clockwise: Bool

  public init(data: Data) throws {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let op = json["op"] as? String, let operation = Operation(rawValue: op)
    else { throw AutomationFailure("Expected an action object with a known op") }
    self.operation = operation
    var fields: Set<String> = ["op", "sessionID", "observationID"]
    switch operation {
    case .tap: fields.formUnion(["x", "y", "duration"])
    case .swipe: fields.formUnion(["x", "y", "toX", "toY", "duration"])
    case .type: fields.insert("text")
    case .key: fields.insert("key")
    case .rotate: fields.insert("direction")
    default: break
    }
    guard Set(json.keys).isSubset(of: fields) else {
      throw AutomationFailure("Unexpected action field")
    }
    if let supplied = json["sessionID"] {
      guard let value = supplied as? String, UUID(uuidString: value) != nil else {
        throw AutomationFailure("sessionID must be a UUID")
      }
      sessionID = value
    } else {
      sessionID = nil
    }
    if let supplied = json["observationID"] {
      guard let value = supplied as? String, !value.isEmpty, value.utf8.count <= 200 else {
        throw AutomationFailure("observationID must be a nonempty string of at most 200 bytes")
      }
      observationID = value
    } else {
      observationID = nil
    }
    func number(_ name: String, fallback: Double? = nil, range: ClosedRange<Double>) throws
      -> Double
    {
      if json[name] == nil, let fallback { return fallback }
      guard let value = json[name] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
        value.doubleValue.isFinite, range.contains(value.doubleValue)
      else { throw AutomationFailure("\(name) must be a number in \(range)") }
      return value.doubleValue
    }
    x = try number("x", fallback: operation == .tap || operation == .swipe ? nil : 0, range: 0...1)
    y = try number("y", fallback: operation == .tap || operation == .swipe ? nil : 0, range: 0...1)
    toX = try number("toX", fallback: operation == .swipe ? nil : 0, range: 0...1)
    toY = try number("toY", fallback: operation == .swipe ? nil : 0, range: 0...1)
    duration = try number("duration", fallback: operation == .swipe ? 0.35 : 0.06, range: 0.03...2)
    if operation == .type {
      guard let value = json["text"] as? String, !value.isEmpty, value.utf8.count <= 65536,
        !value.contains("\0")
      else { throw AutomationFailure("text must contain 1–65536 UTF-8 bytes without NUL") }
      text = value
    } else {
      text = ""
    }
    if operation == .key {
      let keys: [String: UInt32] = [
        "enter": 40, "backspace": 42, "tab": 43, "escape": 41,
        "left": 80, "right": 79, "up": 82, "down": 81, "space": 44,
      ]
      guard let name = json["key"] as? String, let usage = keys[name] else {
        throw AutomationFailure("Unsupported key")
      }
      key = usage
    } else {
      key = 0
    }
    if operation == .rotate {
      guard let direction = json["direction"] as? String, ["left", "right"].contains(direction)
      else {
        throw AutomationFailure("direction must be left or right")
      }
      clockwise = direction == "right"
    } else {
      clockwise = true
    }
  }
}

/// Sends a bounded gesture to one captured session. validate must reject changed
/// sessions, orientation, explicit cancellation and loss of control before every step.
@MainActor public enum AutomationGesture {
  public static func perform(
    _ action: AutomationAction, orientation: DisplayOrientation,
    validate: () throws -> Void, send: (UInt32, UInt32, UInt32) -> Bool,
    sleep: (Double) async throws -> Void = {
      try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
    }
  ) async throws {
    defer { _ = send(6, 0, 0) }
    func emit(_ kind: UInt32, _ a: UInt32 = 0, _ b: UInt32 = 0) throws {
      try validate()
      guard send(kind, a, b) else { throw AutomationFailure(409, "Input queue unavailable") }
    }
    if action.operation == .key {
      try emit(3, action.key)
      try await sleep(0.05)
      try emit(4, action.key)
      return
    }
    func contact(_ progress: Double) throws {
      let point = CGPoint(
        x: action.x + (action.toX - action.x) * progress,
        y: action.y + (action.toY - action.y) * progress)
      guard
        let (x, y) = MirrorGeometry.touch(
          point: point, view: CGSize(width: 1, height: 1),
          screen: CGSize(width: 1, height: 1), orientation: orientation)
      else { throw AutomationFailure("Invalid point") }
      try emit(1, x, y)
    }
    try contact(0)
    if action.operation == .swipe {
      let steps = max(2, Int(ceil(action.duration * 30)))
      for step in 1...steps {
        try await sleep(action.duration / Double(steps))
        try contact(Double(step) / Double(steps))
      }
    } else {
      try await sleep(action.duration)
    }
    try emit(2)
  }
}
