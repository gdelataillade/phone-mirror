import XCTest

@testable import MirrorCore

final class ConnectionDiagnosticsTests: XCTestCase {
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
    health.decoderErrors = 1
    XCTAssertTrue(health.guidance.contains("decoding failed"))
    health.native.orientationFailures = 1
    XCTAssertTrue(health.guidance.contains("orientation"))
  }
}
