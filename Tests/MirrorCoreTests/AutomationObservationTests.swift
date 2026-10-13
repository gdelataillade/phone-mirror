import Foundation
import XCTest

@testable import MirrorCore

final class AutomationObservationTests: XCTestCase {
  func testFreshnessRequiresFrameAfterDispatchConfirmation() {
    let session = UUID()
    let gate = AutomationObservationGate(
      sessionID: session, inputEpoch: 7, frameID: 12, confirmedAt: 100)
    // A newer frame decoded before dispatch is not usable, nor is the old frame.
    for (frame, time) in [(13, 99.9), (13, 100), (12, 100.1)] {
      XCTAssertEqual(
        gate.status(
          sessionID: session, inputEpoch: 7, canCapture: true,
          frameID: UInt64(frame), receivedAt: time), "waiting")
    }
    XCTAssertEqual(
      gate.status(
        sessionID: session, inputEpoch: 7, canCapture: true,
        frameID: 13, receivedAt: 100.1), "fresh")
    XCTAssertEqual(
      gate.status(
        sessionID: session, inputEpoch: 7, canCapture: false,
        frameID: 13, receivedAt: 100.1), "waiting")
    XCTAssertEqual(
      gate.status(
        sessionID: session, inputEpoch: 7, canCapture: true,
        frameID: nil, receivedAt: nil), "waiting")
  }
  func testStopAndReconnectInvalidateEvenFreshFrames() {
    let session = UUID()
    let gate = AutomationObservationGate(
      sessionID: session, inputEpoch: 7, frameID: 12, confirmedAt: 100)
    XCTAssertEqual(
      gate.status(
        sessionID: session, inputEpoch: 8, canCapture: true,
        frameID: 13, receivedAt: 101), "cancelled")
    for id in [UUID(), nil] {
      XCTAssertEqual(
        gate.status(
          sessionID: id, inputEpoch: 7, canCapture: true,
          frameID: 13, receivedAt: 101), "session_changed")
    }
  }
  func testObservationOptionsAreOptInAndStrictlyBounded() throws {
    XCTAssertFalse(try AutomationAction(data: Data(#"{"op":"home"}"#.utf8)).observeAfter)
    let action = try AutomationAction(data: Data(#"{"op":"home","observeAfter":true}"#.utf8))
    XCTAssertTrue(action.observeAfter)
    XCTAssertEqual(action.observationTimeoutSeconds, 2)
    for json in [
      #"{"op":"home","observeAfter":1}"#,
      #"{"op":"home","observeAfter":"true"}"#,
      #"{"op":"home","observationTimeoutSeconds":2}"#,
      #"{"op":"home","observeAfter":true,"observationTimeoutSeconds":true}"#,
      #"{"op":"home","observeAfter":true,"observationTimeoutSeconds":0}"#,
      #"{"op":"home","observeAfter":true,"observationTimeoutSeconds":6}"#,
      #"{"op":"release","observeAfter":true}"#,
    ] { XCTAssertThrowsError(try AutomationAction(data: Data(json.utf8)), json) }
  }
  func testHistoryKeepsPreciseHostTimesAndSessionBoundaries() throws {
    var history = AutomationEvents()
    let initial = history.cursor
    history.record(
      "opening", observedAt: 2000.125, monotonicSeconds: 12.25, sessionID: "first", transport: nil)
    let firstCursor = history.cursor
    // Wall time can go backwards. Elapsed durations use the monotonic clock.
    history.record(
      "closed", observedAt: 1900, monotonicSeconds: 12.75, sessionID: "first", transport: "usb")
    history.record(
      "opening", observedAt: 1901, monotonicSeconds: 13, sessionID: "second", transport: nil)
    let page = try history.read(after: initial)
    XCTAssertEqual(page.events.map(\.sessionID), ["first", "first", "second"])
    XCTAssertEqual(page.events[0].observedAt, 2000.125)
    XCTAssertEqual(page.events[1].monotonicSeconds - page.events[0].monotonicSeconds, 0.5)
    XCTAssertFalse(page.gap)
    XCTAssertEqual(try history.read(after: firstCursor).events.count, 2)
    XCTAssertTrue(try history.read(after: page.nextCursor).events.isEmpty)
    XCTAssertEqual(page.lockState, "unknown")
  }
  func testEvictionRestartAndFilteringCannotSilentlyLoseEvents() throws {
    var history = AutomationEvents(capacity: 2)
    let initial = history.cursor
    history.record("opening", observedAt: 0, monotonicSeconds: 0, sessionID: "one", transport: nil)
    let first = history.cursor
    for event in ["closed", "opening"] {
      history.record(event, observedAt: 1, monotonicSeconds: 1, sessionID: "two", transport: nil)
    }
    let evicted = try history.read(after: initial)
    XCTAssertTrue(evicted.gap)
    XCTAssertTrue(try history.read(after: nil).gap)
    XCTAssertEqual(evicted.events.count, 2)
    XCTAssertFalse(try history.read(after: first).gap)  // Exactly at the retention boundary.
    let filtered = try history.read(after: first, matching: "firstFrame")
    XCTAssertTrue(filtered.events.isEmpty)
    XCTAssertEqual(filtered.nextCursor, history.cursor)  // Advance even over nonmatching events.
    let restarted = try history.read(after: AutomationEvents().cursor)
    XCTAssertTrue(restarted.gap)
    XCTAssertEqual(restarted.events.count, 2)
  }
  func testEventQueriesRejectBadCursorsUnknownEventsAndUnboundedWaits() throws {
    let history = AutomationEvents()
    for query in [
      ["timeoutSeconds": "6"], ["timeoutSeconds": "nan"], ["timeoutSeconds": "-1"],
      ["timeoutSeconds": "1"], ["afterCursor": "bad"], ["event": "locked"], ["other": "x"],
    ] { XCTAssertThrowsError(try AutomationEventQuery(query)) }
    let query = try AutomationEventQuery([
      "afterCursor": history.cursor, "event": "firstFrame", "timeoutSeconds": "5",
    ])
    XCTAssertEqual(query.timeoutSeconds, 5)
    let future = history.cursor.dropLast() + "1"
    XCTAssertThrowsError(try history.read(after: String(future)))
    XCTAssertThrowsError(
      try AutomationEvents.parseCursor(UUID().uuidString + ":18446744073709551616"))
    XCTAssertEqual(
      Set(ConnectionDiagnostics.Event.allCases.map(\.code)).count,
      ConnectionDiagnostics.Event.allCases.count)
  }
}
