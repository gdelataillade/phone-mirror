import XCTest

@testable import MirrorCore

final class VideoWatchdogTests: XCTestCase {
  func testPreparationHasSeparateDeadline() {
    var watchdog = VideoWatchdog(started: 0)
    var health = SessionHealth()
    health.native.stage = 3
    watchdog.observe(health: health, now: 26)
    XCTAssertFalse(watchdog.expired(now: 26))
    XCTAssertTrue(watchdog.expired(now: 180))
    health.native.stage = 6
    watchdog.observe(health: health, now: 100)
    XCTAssertFalse(watchdog.expired(now: 124))
    XCTAssertTrue(watchdog.expired(now: 125))
  }
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
    health.decodedThrough = 100
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
      case 1: health.native.feedbackFailures = 1
      case 2: health.native.orientationFailures = 1
      case 3:
        health.decoderErrors = 1
        health.native.queuedFrames += 1
      default:
        health.skippedFrames = 1
        health.native.queuedFrames += 1
      }
      watchdog.observe(health: health, now: 1.9)
      XCTAssertTrue(watchdog.expired(now: 2))
    }
  }
  func testRecoveredDamageAndDroppedFramesDoNotPoisonStaticScreen() {
    for issue in 0..<4 {
      var watchdog = VideoWatchdog(started: 0)
      watchdog.observe(frameAt: 1)
      var health = idleHealth(queries: 1)
      health.native.recoveryPending = true
      switch issue {
      case 0:
        health.native.queueOverflows = 1
        health.native.assembledFrames += 1
      case 1: health.native.discontinuities = 1
      case 2:
        health.decoderErrors = 1
        health.native.queuedFrames += 1
        health.native.assembledFrames += 1
      default:
        health.skippedFrames = 1
        health.native.queuedFrames += 1
        health.native.assembledFrames += 1
      }
      watchdog.observe(health: health, now: 1.5)
      XCTAssertFalse(watchdog.healthyIdle(now: 1.5))

      // A fresh sync frame is queued and produces an image. Lifetime counters
      // and any assembled/queued/decoded offsets intentionally remain nonzero.
      health.native.recoveryPending = false
      health.native.queuedFrames += 1
      health.native.assembledFrames += 1
      health.native.recoveryFrame = health.native.queuedFrames
      health.decodedFrames += 1
      health.decodedThrough = health.native.queuedFrames
      watchdog.observe(frameAt: 2)
      for step in 1...20 {
        let now = 2 + Double(step) / 2
        health.native.orientationQueries += 1
        watchdog.observe(health: health, now: now)
        XCTAssertTrue(watchdog.healthyIdle(now: now))
        XCTAssertFalse(watchdog.expired(now: now))
      }
      // A cached recovered snapshot still cannot keep the stream alive.
      watchdog.observe(health: health, now: 12.8)
      XCTAssertTrue(watchdog.expired(now: 13))
    }
  }
  func testUnrecoveredDamageOrUndecodedSyncCannotExtendOutputDeadline() {
    for syncQueued in [false, true] {
      var watchdog = VideoWatchdog(started: 0)
      watchdog.observe(frameAt: 1)
      var health = idleHealth(queries: 1)
      health.native.recoveryPending = !syncQueued
      if syncQueued {
        health.native.queuedFrames += 1
        health.native.recoveryFrame = health.native.queuedFrames
      }
      watchdog.observe(health: health, now: 1.5)
      XCTAssertFalse(watchdog.healthyIdle(now: 1.5))
      XCTAssertFalse(watchdog.expired(now: 1.9))
      // Fresh orientation replies and queuing a sync frame cannot substitute
      // for decoded output or relax the existing one-second deadline.
      health.native.orientationQueries += 1
      watchdog.observe(health: health, now: 2)
      XCTAssertFalse(watchdog.healthyIdle(now: 2))
      XCTAssertTrue(watchdog.expired(now: 2))
    }
  }
  func testContinuingEncodedFramesCannotHideStalledDecoder() {
    var watchdog = VideoWatchdog(started: 0)
    watchdog.observe(frameAt: 1)
    var health = idleHealth(queries: 1)
    watchdog.observe(health: health, now: 1.5)
    for step in 1...10 {
      health.native.queuedFrames += 1
      health.native.assembledFrames += 1
      health.native.orientationQueries += 1
      health.native.lastPacketAgeMs = 0
      watchdog.observe(health: health, now: 1.5 + Double(step) / 10)
    }
    XCTAssertTrue(watchdog.expired(now: 2.5))
  }
  func testRecoveryBetweenHealthPollsAlsoAllowsIdle() {
    var watchdog = VideoWatchdog(started: 0)
    watchdog.observe(frameAt: 1)
    var health = idleHealth(queries: 1)
    health.native.queueOverflows = 1
    health.native.discontinuities = 1
    health.native.assembledFrames += 1
    health.native.recoveryFrame = 100
    watchdog.observe(health: health, now: 1.5)
    health.native.orientationQueries += 1
    watchdog.observe(health: health, now: 2)
    XCTAssertFalse(watchdog.expired(now: 2))
  }
  func testDeviceResponsesCannotHideMissingFirstPicture() {
    var watchdog = VideoWatchdog(started: 0)
    watchdog.observe(health: idleHealth(queries: 10), now: 24.9)
    XCTAssertTrue(watchdog.expired(now: 50))
  }
}
