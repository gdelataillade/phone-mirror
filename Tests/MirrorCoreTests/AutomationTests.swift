import Foundation
import XCTest

@testable import MirrorCore

final class AutomationTests: XCTestCase {
  private func request(_ extra: String = "", body: String = "{}") -> Data {
    Data(
      "POST /v1/actions HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nAuthorization: Bearer test\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\(extra)\r\n\(body)"
        .utf8)
  }
  func testPartialBodyWaitsThenAuthorizesExactRequest() throws {
    let wire = request(body: "{\"op\":\"home\"}")
    XCTAssertNil(try AutomationRequest.parse(wire.dropLast()))
    let parsed = try XCTUnwrap(AutomationRequest.parse(wire))
    XCTAssertEqual(parsed.path, "/v1/actions")
    try parsed.authorize(token: "test", port: 1234)
    XCTAssertThrowsError(try parsed.authorize(token: "wrong", port: 1234))
    XCTAssertThrowsError(try parsed.authorize(token: "test", port: 9999))
  }
  func testRejectsBrowserOriginAndAmbiguousRequestFraming() throws {
    let browser = try XCTUnwrap(
      AutomationRequest.parse(request("Origin: http://127.0.0.1:1234\r\n")))
    XCTAssertThrowsError(try browser.authorize(token: "test", port: 1234))
    for header in [
      "Content-Length: 2\r\n", "Transfer-Encoding: chunked\r\n", "Expect: 100-continue\r\n",
    ] {
      XCTAssertThrowsError(try AutomationRequest.parse(request(header)))
    }
    XCTAssertThrowsError(
      try AutomationRequest.parse(request() + Data("GET / HTTP/1.1\r\n\r\n".utf8)))
    XCTAssertThrowsError(try AutomationRequest.parse(Data(repeating: 65, count: 8193)))
    XCTAssertThrowsError(
      try AutomationRequest.parse(
        Data("POST /v1/actions HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)))
  }
  func testActionValidationRejectsCoercionAndOutOfBoundsCommands() throws {
    for json in [
      "{\"op\":\"tap\",\"x\":true,\"y\":0.5}",
      "{\"op\":\"tap\",\"x\":-0.01,\"y\":0.5}",
      "{\"op\":\"tap\",\"x\":0.5,\"y\":1.01}",
      "{\"op\":\"swipe\",\"x\":0,\"y\":0}",
      "{\"op\":\"key\",\"key\":\"power\"}",
      "{\"op\":\"home\",\"text\":\"unexpected\"}",
      "{\"op\":\"home\",\"sessionID\":\"wrong\"}",
      "{\"op\":\"type\",\"text\":\"\"}",
      "{\"op\":\"rotate\",\"direction\":\"up\"}",
      "{\"op\":\"tap\",\"x\":0.5,\"y\":0.5,\"duration\":30}",
    ] { XCTAssertThrowsError(try AutomationAction(data: Data(json.utf8)), json) }
    let text = try JSONSerialization.data(withJSONObject: [
      "op": "type", "text": String(repeating: "é", count: 32769),
    ])
    XCTAssertThrowsError(try AutomationAction(data: text))
  }
  @MainActor func testLandscapeTapMapsUprightScreenshotToNaturalDigitizer() async throws {
    let action = try AutomationAction(data: Data("{\"op\":\"tap\",\"x\":0.25,\"y\":0.75}".utf8))
    var commands: [(UInt32, UInt32, UInt32)] = []
    try await AutomationGesture.perform(
      action, orientation: .landscapeRight, validate: {},
      send: {
        commands.append(($0, $1, $2))
        return true
      }, sleep: { _ in })
    XCTAssertEqual(commands.map { $0.0 }, [1, 2, 6])
    XCTAssertEqual(commands[0].1, 49151)
    XCTAssertEqual(commands[0].2, 49151)
  }
  @MainActor func testCancelledSwipeReleasesWithoutSendingFurtherContacts() async throws {
    let action = try AutomationAction(
      data: Data("{\"op\":\"swipe\",\"x\":0.2,\"y\":0.8,\"toX\":0.2,\"toY\":0.2}".utf8))
    var cancelled = false
    var commands: [UInt32] = []
    do {
      try await AutomationGesture.perform(
        action, orientation: .portrait,
        validate: { if cancelled { throw AutomationFailure(409, "Session changed") } },
        send: { kind, _, _ in
          commands.append(kind)
          return true
        },
        sleep: { _ in cancelled = true })
      XCTFail("Expected cancellation")
    } catch { XCTAssertEqual((error as? AutomationFailure)?.status, 409) }
    XCTAssertEqual(commands, [1, 6])
  }
  @MainActor func testFailedInputQueueStillAttemptsRelease() async throws {
    let action = try AutomationAction(data: Data("{\"op\":\"key\",\"key\":\"enter\"}".utf8))
    var commands: [UInt32] = []
    do {
      try await AutomationGesture.perform(
        action, orientation: .portrait, validate: {},
        send: { kind, _, _ in
          commands.append(kind)
          return false
        }, sleep: { _ in })
      XCTFail("Expected queue failure")
    } catch { XCTAssertEqual((error as? AutomationFailure)?.status, 409) }
    XCTAssertEqual(commands, [3, 6])
  }
}
