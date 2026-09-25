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
  /// The route without its query string.
  public let path: String
  public let query: [String: String]
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
    let target = first[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    var query: [String: String] = [:]
    if target.count == 2 {
      // Plain name=value tokens only: no escaping to interpret, no repeated names.
      func plain(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
      }
      for pair in target[1].split(separator: "&", omittingEmptySubsequences: false) {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, plain(parts[0]), plain(parts[1]),
          query[String(parts[0])] == nil
        else { throw AutomationFailure(400, "Invalid query string") }
        query[String(parts[0])] = String(parts[1])
      }
    }
    return AutomationRequest(
      method: first[0], path: String(target[0]), query: query, headers: headers,
      body: Data(data[end.upperBound...]))
  }

  /// Rejects parameters an endpoint does not understand rather than ignoring them.
  public func requireQuery(allowing names: Set<String>) throws {
    guard Set(query.keys).isSubset(of: names) else {
      throw AutomationFailure(400, "Unsupported query parameter")
    }
  }

  public func authorize(token: String, port: UInt16) throws {
    guard headers["origin"] == nil else {
      throw AutomationFailure(403, "Browser origins are not allowed")
    }
    // Literal loopback names only: a rebinding attacker's own domain never matches.
    guard let host = headers["host"], ["127.0.0.1:\(port)", "localhost:\(port)"].contains(host)
    else { throw AutomationFailure(403, "Expected loopback Host") }
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

/// `GET /v1/screenshot?format=json|png&scale=default|full`.
public struct ScreenshotOptions: Equatable {
  /// Longest edge of the default screenshot; `full` keeps the stream resolution.
  public static let defaultLongEdge: Double = 1280
  public let rawPNG: Bool
  public let fullResolution: Bool
  public init(rawPNG: Bool = false, fullResolution: Bool = false) {
    self.rawPNG = rawPNG
    self.fullResolution = fullResolution
  }
  public init(query: [String: String]) throws {
    guard Set(query.keys).isSubset(of: ["format", "scale"]) else {
      throw AutomationFailure(400, "Unsupported query parameter")
    }
    switch query["format"] ?? "json" {
    case "json": rawPNG = false
    case "png": rawPNG = true
    default: throw AutomationFailure(400, "format must be json or png")
    }
    switch query["scale"] ?? "default" {
    case "default": fullResolution = false
    case "full": fullResolution = true
    default: throw AutomationFailure(400, "scale must be default or full")
    }
  }
  /// Uniform downscale factor for an upright image of the given size.
  public func scale(for size: CGSize) -> Double {
    fullResolution ? 1 : min(1, Self.defaultLongEdge / max(size.width, size.height, 1))
  }
}

/// Serialized response head. Header values come from our own identifiers, but are
/// still restricted so nothing can inject a line break into the response.
public enum AutomationResponseHead {
  public static func make(
    status: Int, contentType: String, length: Int, extra: [(String, String)] = []
  ) -> Data {
    var head =
      "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(contentType)\r\nContent-Length: \(length)\r\nCache-Control: no-store\r\nConnection: close\r\n"
    // Scalars, not Characters: Swift treats "\r\n" as one Character equal to neither.
    for (name, value) in extra
    where value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F })
    {
      head += "\(name): \(value)\r\n"
    }
    return Data((head + "\r\n").utf8)
  }
}

/// The listener port preference. 0 picks a free port on every enable.
public enum AutomationPort {
  public static let automatic = 0
  public static let preset = 8090
  /// Unprivileged ports only, so a fixed port never needs elevated rights.
  public static func parse(_ text: String) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.allSatisfy({ $0 >= "0" && $0 <= "9" }),
      let value = Int(trimmed), (1024...65535).contains(value)
    else { return nil }
    return value
  }
}

/// Buttons the `button` action can press. Values are the native command 13 IDs;
/// Home keeps its existing command.
public enum HardwareButton: String {
  case home, lock
  case volumeUp = "volume_up"
  case volumeDown = "volume_down"
  /// nil for Home, which uses native command 5.
  public var nativeID: UInt32? {
    switch self {
    case .home: nil
    case .lock: 1
    case .volumeUp: 2
    case .volumeDown: 3
    }
  }
}

public struct AutomationAction {
  public enum Operation: String {
    case tap, swipe, type, key, home, button
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
  public let button: HardwareButton

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
    case .button: fields.insert("button")
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
    if operation == .button {
      guard let name = json["button"] as? String, let value = HardwareButton(rawValue: name) else {
        throw AutomationFailure("button must be home, lock, volume_up or volume_down")
      }
      button = value
    } else {
      button = .home
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
