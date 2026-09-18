import XCTest

@testable import MirrorCore

final class ConnectionLifecycleTests: XCTestCase {
  func testCableLossClosesBeforeRetryAndKeepsSamePhone() {
    var state = ConnectionLifecycle()
    _ = state.connect(device: "phone-a")
    let first = state.attempt!
    state.frame(first.id, now: 0)
    XCTAssertEqual(state.interrupt(first.id, now: 100), [.close(first.id)])
    XCTAssertTrue(state.tick(now: 100).isEmpty)
    XCTAssertTrue(state.connect(device: "phone-b").isEmpty)
    _ = state.closed(first.id, now: 100)
    XCTAssertTrue(state.tick(now: 100.9).isEmpty)
    let actions = state.tick(now: 101)
    XCTAssertEqual(actions, [.open(state.attempt!)])
    XCTAssertEqual(state.attempt?.device, "phone-a")
    XCTAssertNotEqual(state.attempt?.id, first.id)
  }
  func testStopDuringBackoffNeverRestarts() {
    var state = ConnectionLifecycle()
    _ = state.connect(device: "phone")
    _ = state.closed(state.attempt!.id, now: 0)
    _ = state.disconnect()
    XCTAssertFalse(state.active)
    XCTAssertTrue(state.tick(now: 1000).isEmpty)
    XCTAssertTrue(state.wake().isEmpty)
  }
  func testStopWhileClosingAndLateCallbacksCannotReviveSession() {
    var state = ConnectionLifecycle()
    _ = state.connect(device: "phone")
    let old = state.attempt!.id
    _ = state.interrupt(old, now: 0)
    _ = state.disconnect()
    state.frame(old, now: 1)
    XCTAssertEqual(state.phase, .closing)
    _ = state.closed(old, now: 2)
    XCTAssertEqual(state.phase, .idle)
    _ = state.connect(device: "other-phone")
    let current = state.attempt
    _ = state.closed(old, now: 3)
    state.frame(old, now: 4)
    XCTAssertEqual(state.attempt, current)
    XCTAssertEqual(state.phase, .connecting)
  }
  func testSleepPreservesIntentAndWakeWaitsForCleanup() {
    var state = ConnectionLifecycle()
    _ = state.connect(device: "phone")
    let old = state.attempt!.id
    XCTAssertEqual(state.sleep(), [.close(old)])
    XCTAssertTrue(state.wake().isEmpty)
    XCTAssertEqual(state.attempt?.id, old)
    _ = state.closed(old, now: 0)
    _ = state.tick(now: 1)
    XCTAssertNotEqual(state.attempt?.id, old)
  }
  func testNoRetriesDuringSleepAndStopCancelsWake() {
    var state = ConnectionLifecycle()
    _ = state.connect(device: "phone")
    let old = state.attempt!.id
    _ = state.sleep()
    _ = state.closed(old, now: 0)
    XCTAssertEqual(state.phase, .sleeping)
    XCTAssertTrue(state.tick(now: 1000).isEmpty)
    XCTAssertEqual(state.wake(), [.open(state.attempt!)])
    _ = state.sleep()
    _ = state.disconnect()
    _ = state.closed(state.attempt!.id, now: 1001)
    XCTAssertTrue(state.wake().isEmpty)
  }
  func testBackoffCapsAndOnlyResetsAfterSustainedVideo() {
    var state = ConnectionLifecycle()
    _ = state.connect(device: "phone")
    var time = 0.0
    for delay in [1.0, 2, 4, 8, 16, 30, 30] {
      let id = state.attempt!.id
      state.frame(id, now: time)
      _ = state.closed(id, now: time)
      XCTAssertEqual(state.retryAt!, time + delay)
      time += delay
      _ = state.tick(now: time)
    }
    let id = state.attempt!.id
    state.frame(id, now: time)
    state.frame(id, now: time + 10)
    _ = state.closed(id, now: time + 11)
    XCTAssertEqual(state.retryAt, time + 12)
  }
  func testCleanupUsesRetryDelayAndOpensImmediatelyIfItAlreadyElapsed() {
    var state = ConnectionLifecycle()
    _ = state.connect(device: "phone")
    let id = state.attempt!.id
    _ = state.interrupt(id, now: 10)
    XCTAssertEqual(state.closed(id, now: 11.5), [.open(state.attempt!)])
    XCTAssertNotEqual(state.attempt?.id, id)
  }
  func testManualRetryBypassesLongBackoffAndResetsFailureSequence() {
    var state = ConnectionLifecycle()
    _ = state.connect(device: "phone")
    for time in [0.0, 10, 20, 30] {
      _ = state.closed(state.attempt!.id, now: time)
      if time < 30 { _ = state.tick(now: time + 9) }
    }
    XCTAssertEqual(state.retryAt, 38)
    XCTAssertEqual(state.retryNow(), [.open(state.attempt!)])
    _ = state.closed(state.attempt!.id, now: 31)
    XCTAssertEqual(state.retryAt, 32)
  }
  func testManualRetryWhileClosingWaitsForWorkerAndStopCancelsIt() {
    var state = ConnectionLifecycle()
    _ = state.connect(device: "phone")
    let first = state.attempt!.id
    XCTAssertEqual(state.retryNow(), [.close(first)])
    XCTAssertTrue(state.retryNow().isEmpty)
    XCTAssertTrue(state.tick(now: 100).isEmpty)
    XCTAssertEqual(state.closed(first, now: 101), [.open(state.attempt!)])
    let next = state.attempt!.id
    _ = state.retryNow()
    _ = state.disconnect()
    XCTAssertTrue(state.closed(next, now: 102).isEmpty)
    XCTAssertTrue(state.retryNow().isEmpty)
    XCTAssertFalse(state.active)
  }
  func testImmediateRetryDoesNotOverrideSleepOrStoppedConnection() {
    var state = ConnectionLifecycle()
    _ = state.connect(device: "phone")
    let id = state.attempt!.id
    _ = state.sleep()
    XCTAssertTrue(state.retryNow().isEmpty)
    _ = state.closed(id, now: 0)
    XCTAssertTrue(state.retryNow().isEmpty)
    _ = state.disconnect()
    XCTAssertTrue(state.wake().isEmpty)
  }

}
