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
  private func idleHealth(queries: UInt64) -> SessionHealth {
    var health = SessionHealth()
    health.native.stage = 6
    health.native.assembledFrames = 100
    health.native.queuedFrames = 100
    health.decodedFrames = 100
    health.native.orientationQueries = queries
    health.native.lastPacketAgeMs = 500
    return health
  }
  func testResponsiveStaticScreenStaysUsableButCachedHeartbeatExpires() {
    var watchdog = VideoWatchdog(started: 0)
    watchdog.observe(frameAt: 1)
    for step in 1...20 {
      let now = 1 + Double(step) / 2
      watchdog.observe(health: idleHealth(queries: UInt64(step)), now: now)
      XCTAssertFalse(watchdog.expired(now: now))
    }
    // Cached counters do not extend the deadline when the receiver stops running.
    watchdog.observe(health: idleHealth(queries: 20), now: 11.8)
    XCTAssertTrue(watchdog.expired(now: 12))
  }
  func testHeartbeatCannotHideQueuedFramesOrStreamDamage() {
    for issue in 0..<5 {
      var watchdog = VideoWatchdog(started: 0)
      watchdog.observe(frameAt: 1)
      watchdog.observe(health: idleHealth(queries: 1), now: 1.5)
      var health = idleHealth(queries: 2)
      switch issue {
      case 0: health.native.queuedFrames += 1
      case 1: health.native.queueOverflows = 1
      case 2: health.native.discontinuities = 1
      case 3: health.decoderErrors = 1
      default: health.native.orientationFailures = 1
      }
      watchdog.observe(health: health, now: 1.9)
      XCTAssertTrue(watchdog.expired(now: 2))
    }
  }
  func testDeviceResponsesCannotHideMissingFirstPicture() {
    var watchdog = VideoWatchdog(started: 0)
    watchdog.observe(health: idleHealth(queries: 10), now: 24.9)
    XCTAssertTrue(watchdog.expired(now: 25))
  }
}
