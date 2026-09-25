import Foundation
import XCTest

@testable import MirrorCore

final class AutomationRegressionTests: XCTestCase {
  private func wire(_ method: String = "POST", headers: String, body: Data = Data()) -> Data {
    var data = Data("\(method) /v1/actions HTTP/1.1\r\n\(headers)\r\n".utf8)
    data.append(body)
    return data
  }

  func testUnicodeBodyCanArriveAcrossEveryByteBoundary() throws {
    let body = Data("{\"op\":\"type\",\"text\":\"é 📱\"}".utf8)
    let data = wire(headers: "Content-Length: \(body.count)\r\n", body: body)
    // A network receive may split a UTF-8 sequence or even the header terminator.
    for length in 0..<data.count {
      XCTAssertNil(try AutomationRequest.parse(Data(data.prefix(length))), "prefix \(length)")
    }
    let parsed = try XCTUnwrap(AutomationRequest.parse(data))
    XCTAssertEqual(try AutomationAction(data: parsed.body).text, "é 📱")
  }

  func testGetStillRequiresAuthenticationAndExactLoopbackHost() throws {
    let invalid: [(String, Int)] = [
      ("Host: 127.0.0.1:1234\r\n", 401),
      ("Host: localhost:1234\r\nAuthorization: Bearer test\r\n", 403),
      ("Host: attacker.example:1234\r\nAuthorization: Bearer test\r\n", 403),
      ("Host: 127.0.0.1:1234\r\nAuthorization: Bearer test\r\nOrigin: null\r\n", 403),
    ]
    for (headers, status) in invalid {
      let request = try XCTUnwrap(AutomationRequest.parse(wire("GET", headers: headers)))
      XCTAssertThrowsError(try request.authorize(token: "test", port: 1234)) {
        XCTAssertEqual(($0 as? AutomationFailure)?.status, status)
      }
    }
  }

  func testPostCannotBeAcceptedAsBrowserSimpleFormContent() throws {
    let base = "Host: 127.0.0.1:1234\r\nAuthorization: Bearer test\r\nContent-Length: 0\r\n"
    for type in ["text/plain", "application/x-www-form-urlencoded", "multipart/form-data"] {
      let request = try XCTUnwrap(
        AutomationRequest.parse(
          wire(headers: base + "Content-Type: \(type)\r\n")))
      XCTAssertThrowsError(try request.authorize(token: "test", port: 1234)) {
        XCTAssertEqual(($0 as? AutomationFailure)?.status, 415)
      }
    }
    let json = try XCTUnwrap(
      AutomationRequest.parse(
        wire(headers: base + "Content-Type: application/json; charset=utf-8\r\n")))
    XCTAssertNoThrow(try json.authorize(token: "test", port: 1234))
  }

  func testRejectsConflictingHeaderCasingAndInvalidLengthsBeforeBodyArrives() {
    for headers in [
      "Content-Length: 0\r\ncontent-length: 0\r\n",
      "Host: 127.0.0.1:1234\r\nhOsT: attacker.example\r\nContent-Length: 0\r\n",
      "Content-Length: -1\r\n", "Content-Length: +1\r\n",
      "Content-Length: 1, 1\r\n", "Content-Length: 999999999999999999999\r\n",
      "Content-Length: \(AutomationRequest.maximumBody + 1)\r\n",
    ] {
      XCTAssertThrowsError(try AutomationRequest.parse(wire(headers: headers)), headers)
    }
    XCTAssertThrowsError(try AutomationRequest.parse(wire(headers: ""))) {
      XCTAssertEqual(($0 as? AutomationFailure)?.status, 411)
    }
  }

  func testTextLimitUsesUTF8BytesAndRejectsEmbeddedNul() throws {
    let boundary = String(repeating: "é", count: 32768)
    let valid = try JSONSerialization.data(withJSONObject: ["op": "type", "text": boundary])
    XCTAssertEqual(try AutomationAction(data: valid).text.utf8.count, 65536)
    for text in [boundary + "a", "before\0after"] {
      let invalid = try JSONSerialization.data(withJSONObject: ["op": "type", "text": text])
      XCTAssertThrowsError(try AutomationAction(data: invalid))
    }
  }

  @MainActor func testTaskCancellationWhileHoldingContactReleasesImmediately() async throws {
    let action = try AutomationAction(
      data: Data(
        "{\"op\":\"tap\",\"x\":0.5,\"y\":0.5,\"duration\":2}".utf8))
    let down = expectation(description: "Contact reached the input queue")
    var commands: [UInt32] = []
    let gesture = Task { @MainActor in
      try await AutomationGesture.perform(
        action, orientation: .portrait,
        validate: { try Task.checkCancellation() },
        send: { kind, _, _ in
          commands.append(kind)
          if kind == 1 { down.fulfill() }
          return true
        })
    }
    await fulfillment(of: [down], timeout: 1)
    gesture.cancel()
    do {
      try await gesture.value
      XCTFail("Expected task cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(commands, [1, 6], "Cancellation must release without a later touch-up action")
  }

  @MainActor func testAlreadyCancelledTaskNeverPressesAKey() async throws {
    let action = try AutomationAction(data: Data("{\"op\":\"key\",\"key\":\"enter\"}".utf8))
    var commands: [UInt32] = []
    let gesture = Task { @MainActor in
      try await AutomationGesture.perform(
        action, orientation: .portrait,
        validate: { try Task.checkCancellation() },
        send: { kind, _, _ in
          commands.append(kind)
          return true
        })
    }
    gesture.cancel()
    do {
      try await gesture.value
      XCTFail("Expected task cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(commands, [6])
  }

  @MainActor func testQueueFailureAfterKeyDownStillAttemptsEmergencyRelease() async throws {
    let action = try AutomationAction(data: Data("{\"op\":\"key\",\"key\":\"enter\"}".utf8))
    var commands: [UInt32] = []
    do {
      try await AutomationGesture.perform(
        action, orientation: .portrait, validate: {},
        send: { kind, _, _ in
          commands.append(kind)
          return kind == 3
        }, sleep: { _ in })
      XCTFail("Expected failure after key-down")
    } catch { XCTAssertEqual((error as? AutomationFailure)?.status, 409) }
    XCTAssertEqual(commands, [3, 4, 6])
    // The real backend cancels its session if any queue send fails. This test
    // checks Swift cleanup attempts; it does not claim native release delivery.
  }
}
