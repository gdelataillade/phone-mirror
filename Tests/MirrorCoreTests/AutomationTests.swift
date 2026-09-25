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
      "{\"op\":\"button\"}",
      "{\"op\":\"button\",\"button\":\"siri\"}",
      "{\"op\":\"button\",\"button\":1}",
      "{\"op\":\"home\",\"button\":\"lock\"}",
      "{\"op\":\"tap\",\"x\":0.5,\"y\":0.5,\"duration\":30}",
    ] { XCTAssertThrowsError(try AutomationAction(data: Data(json.utf8)), json) }
    let text = try JSONSerialization.data(withJSONObject: [
      "op": "type", "text": String(repeating: "é", count: 32769),
    ])
    XCTAssertThrowsError(try AutomationAction(data: text))
  }
  func testAppRequestsValidateStrictlyAndProduceCanonicalNativeJSON() throws {
    XCTAssertEqual(try AppRequest(listQuery: [:]).kind, .list(developerOnly: false))
    XCTAssertEqual(try AppRequest(listQuery: ["scope": "all"]).kind, .list(developerOnly: false))
    XCTAssertEqual(
      try AppRequest(listQuery: ["scope": "developer"]).kind, .list(developerOnly: true))
    XCTAssertEqual(
      try AppRequest(listQuery: ["scope": "developer"]).nativeJSON,
      "{\"op\":\"list\",\"scope\":\"developer\"}")
    let session = UUID().uuidString
    let launch = try AppRequest(
      path: "/v1/apps/launch",
      body: Data(
        "{\"bundleID\":\"com.apple.Preferences\",\"restart\":true,\"sessionID\":\"\(session)\"}"
          .utf8))
    XCTAssertEqual(launch.kind, .launch(bundleID: "com.apple.Preferences", restart: true))
    XCTAssertEqual(launch.sessionID, session)
    XCTAssertTrue(launch.changesScreen)
    XCTAssertEqual(
      launch.nativeJSON,
      "{\"bundleID\":\"com.apple.Preferences\",\"op\":\"launch\",\"restart\":true}")
    let stop = try AppRequest(
      path: "/v1/apps/terminate", body: Data("{\"bundleID\":\"com.example.app-1\"}".utf8))
    XCTAssertEqual(stop.kind, .terminate(bundleID: "com.example.app-1"))
    XCTAssertFalse(try AppRequest(listQuery: [:]).changesScreen)

    for query in [["scope": "system"], ["scope": "1"], ["system": "true"]] {
      XCTAssertThrowsError(try AppRequest(listQuery: query), "\(query)")
    }
    let invalid: [(String, String)] = [
      ("/v1/apps/launch", "{}"),
      ("/v1/apps/launch", "{\"bundleID\":\"\"}"),
      ("/v1/apps/launch", "{\"bundleID\":\"com.x/../y\"}"),
      ("/v1/apps/launch", "{\"bundleID\":\"com x\"}"),
      ("/v1/apps/launch", "{\"bundleID\":\"com.é\"}"),
      ("/v1/apps/launch", "{\"bundleID\":1}"),
      ("/v1/apps/launch", "{\"bundleID\":\"a\",\"restart\":1}"),
      ("/v1/apps/launch", "{\"bundleID\":\"a\",\"arguments\":[]}"),
      ("/v1/apps/launch", "{\"bundleID\":\"a\",\"sessionID\":\"x\"}"),
      ("/v1/apps/terminate", "{\"bundleID\":\"a\",\"restart\":true}"),
      ("/v1/apps/uninstall", "{\"bundleID\":\"a\"}"),
      ("/v1/apps/launch", "[]"),
      ("/v1/apps/launch", "{\"bundleID\":\"\(String(repeating: "a", count: 256))\"}"),
    ]
    for (path, body) in invalid {
      XCTAssertThrowsError(try AppRequest(path: path, body: Data(body.utf8)), "\(path) \(body)")
    }
  }
  func testButtonActionsMapToFixedNativeIDs() throws {
    let expected: [String: UInt32?] = [
      "home": nil, "lock": 1, "volume_up": 2, "volume_down": 3,
    ]
    for (name, id) in expected {
      let action = try AutomationAction(
        data: Data("{\"op\":\"button\",\"button\":\"\(name)\"}".utf8))
      XCTAssertEqual(action.operation, .button)
      XCTAssertEqual(action.button.nativeID, id, name)
    }
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
