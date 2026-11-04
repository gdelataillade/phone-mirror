import XCTest

@testable import MirrorCore

final class ConnectionDiagnosticsTests: XCTestCase {
  func testNativeFailureCodeDecodesAndSurvivesReconnectAndCleanup() throws {
    var encoded =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(NativeHealth())) as! [String: Any]
    encoded["failureCategory"] = 4
    var native = try JSONDecoder().decode(
      NativeHealth.self, from: JSONSerialization.data(withJSONObject: encoded))
    XCTAssertEqual(native.failureLabel, "Input command timed out")
    native.cleanupStatus = 2
    var health = SessionHealth()
    health.native = native
    var log = ConnectionDiagnostics(started: 0)
    log.record(.closed, now: 1, health: health)
    log.record(.opening, now: 2)
    let report = log.report(
      current: SessionHealth(), phase: .live,
      appVersion: "0.5.2", macOSVersion: "27", iOSVersion: "27", transport: "wifi")
    XCTAssertTrue(report.contains("Native failure: Input command timed out"))
    XCTAssertTrue(report.contains("20-second timeout"))
    XCTAssertEqual(log.lastSession.native.failureCategory, 4)
    encoded.removeValue(forKey: "failureCategory")
    let older = try JSONDecoder().decode(
      NativeHealth.self, from: JSONSerialization.data(withJSONObject: encoded))
    XCTAssertEqual(older.failureLabel, "None recorded")
  }

  func testNativeFailureLabelsAreAllowlisted() {
    var health = SessionHealth()
    // Pin the wire-code contract, not just whether a label is present.
    let labels = [
      "Setup failed", "Orientation query failed", "Input worker stopped",
      "Input command timed out", "Input command failed", "Video transport closed",
      "Audio transport closed", "Media feedback failed", "Video recovery timed out",
      "First picture timed out", "Native worker panicked", "Native runtime failed",
      "Other native failure",
    ]
    for (index, label) in labels.enumerated() {
      health.native.failureCategory = UInt32(index + 1)
      XCTAssertEqual(health.native.failureLabel, label)
    }
    health.native.failureCategory = UInt32.max
    XCTAssertEqual(health.native.failureLabel, "Unknown native failure")
    XCTAssertFalse(health.report.contains(String(UInt32.max)))
    health.native.failureCategory = 0
    XCTAssertEqual(health.native.failureLabel, "None recorded")
  }
  func testDecodedPositionIncludesEarlierFailuresAndSkippedEvents() {
    var health = SessionHealth()
    health.recordDecode(produced: true, failed: false)
    XCTAssertEqual(health.decodedThrough, 1)
    health.recordDecode(produced: false, failed: true)
    health.recordDecode(produced: false, failed: false)
    XCTAssertEqual(health.decodedThrough, 1)
    health.recordDecode(produced: true, failed: false)
    XCTAssertEqual(health.decodedFrames, 2)
    XCTAssertEqual(health.decoderErrors, 1)
    XCTAssertEqual(health.skippedFrames, 1)
    XCTAssertEqual(health.decodedThrough, 4)
  }
  func testReportUsesObservedTransportAndRedactsUnexpectedValues() {
    let log = ConnectionDiagnostics(started: 0)
    for (transport, label) in [("usb", "USB"), ("wifi", "Wi-Fi"), ("private-id", "unknown")] {
      let report = log.report(
        current: nil, phase: .live, appVersion: "0.5.2", macOSVersion: "27", iOSVersion: "27",
        transport: transport)
      XCTAssertTrue(report.contains("Transport: \(label)"))
      XCTAssertFalse(report.contains("private-id"))
    }
    XCTAssertTrue(
      log.report(
        current: nil, phase: .idle, appVersion: "0.5.2", macOSVersion: "27", iOSVersion: "27"
      )
      .contains("Transport: unknown"))
  }
  func testReportRetainsFailureCountersAfterReconnectWithoutAcceptingIdentityText() {
    var log = ConnectionDiagnostics(started: 100)
    log.record(.opening, now: 100)
    var failed = SessionHealth()
    failed.native.queueOverflows = 3
    failed.decoderErrors = 2
    log.record(.videoStalled, now: 104)
    log.record(.closed, now: 105, health: failed)
    log.record(.opening, now: 106)
    let report = log.report(
      current: SessionHealth(), phase: .live, appVersion: "0.1.0",
      macOSVersion: "27.0", iOSVersion: "Private Phone / private-token")
    XCTAssertTrue(report.contains("Connection attempts: 2"))
    XCTAssertTrue(report.contains("Encoded queue overflows: 3"))
    XCTAssertTrue(report.contains("Decoder errors / skipped outputs: 2 / 0"))
    XCTAssertTrue(report.contains("iOS: unknown"))
    XCTAssertFalse(report.contains("Private Phone"))
    XCTAssertFalse(report.contains("private-token"))
  }
  func testHistoryIsBoundedAndAttemptsSurviveTrimming() {
    var log = ConnectionDiagnostics(started: 0)
    for time in 0..<100 { log.record(.opening, now: Double(time)) }
    let report = log.report(
      current: nil, phase: .waiting, appVersion: "0.1.0", macOSVersion: "27", iOSVersion: "27")
    XCTAssertEqual(log.attempts, 100)
    XCTAssertFalse(report.contains("+39s:"))
    XCTAssertTrue(report.contains("+40s:"))
    XCTAssertTrue(report.contains("+99s:"))
  }
  func testGuidanceDistinguishesSetupDecoderAndOrientationFailures() {
    var health = SessionHealth()
    health.native.stage = 2
    XCTAssertTrue(health.guidance.contains("Developer Mode"))
    XCTAssertTrue(health.guidance.contains("Setup Check"))
    health.decoderErrors = 1
    XCTAssertTrue(health.guidance.contains("decoding failed"))
    health.native.orientationFailures = 1
    XCTAssertTrue(health.guidance.contains("orientation"))
  }
  func testReleaseEvidenceSurvivesCloseAndDoesNotClaimConfirmedRelease() {
    var health = SessionHealth()
    health.native.cleanupStatus = 2
    health.native.cleanupDurationMs = 42
    var log = ConnectionDiagnostics(started: 0)
    log.record(.closed, now: 1, health: health)
    XCTAssertEqual(log.lastSession.native.cleanupStatus, 2)
    XCTAssertTrue(log.lastSession.report.contains("Waiting for the iPhone"))
    XCTAssertTrue(log.lastSession.guidance.contains("20 seconds"))
    for status in [3, 4, 5, 6] {
      health.native.cleanupStatus = status
      XCTAssertTrue(health.native.cleanupLabel.contains("unconfirmed"))
    }
    health.native.cleanupStatus = 1
    XCTAssertTrue(health.native.cleanupLabel.contains("No owned streams reported"))
  }

}
