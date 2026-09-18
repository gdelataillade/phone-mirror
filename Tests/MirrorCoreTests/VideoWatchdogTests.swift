import XCTest

@testable import MirrorCore

final class VideoWatchdogTests: XCTestCase {
  func testNoDecodedOutputTimesOutEvenIfEncodedFramesKeepArriving() {
    let watchdog = VideoWatchdog(started: 100)
    XCTAssertFalse(watchdog.expired(now: 124.9))
    XCTAssertTrue(watchdog.expired(now: 125))
  }
  func testClearedMailboxAndRepeatedOldFrameCannotKeepSessionAlive() {
    var watchdog = VideoWatchdog(started: 100)
    watchdog.observe(frameAt: 101)
    watchdog.observe(frameAt: nil)
    XCTAssertFalse(watchdog.expired(now: 101.9))
    watchdog.observe(frameAt: 101)
    XCTAssertTrue(watchdog.expired(now: 102))
  }
  func testFreshDecodedOutputRenewsDeadline() {
    var watchdog = VideoWatchdog(started: 100)
    watchdog.observe(frameAt: 101)
    watchdog.observe(frameAt: 104)
    XCTAssertFalse(watchdog.expired(now: 104.9))
    XCTAssertTrue(watchdog.expired(now: 105))
  }
}
