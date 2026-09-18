import XCTest

@testable import MirrorCore

final class RotationRequestTests: XCTestCase {
  private let portrait = CGSize(width: 1200, height: 2600)
  private let landscape = CGSize(width: 2600, height: 1200)

  func testRotationWaitsForAcknowledgmentAndMatchingFreshFrame() {
    var request = RotationRequest()
    request.begin(orientation: 0, screen: portrait, now: 10)
    XCTAssertNil(request.observe(ordinal: 2, orientation: 2, screen: landscape, now: 10.1))
    request.acknowledge(after: 2)
    XCTAssertNil(request.observe(ordinal: 2, orientation: 2, screen: landscape, now: 10.2))
    XCTAssertNil(request.observe(ordinal: 3, orientation: 0, screen: portrait, now: 10.3))
    XCTAssertNil(request.observe(ordinal: 4, orientation: 4, screen: landscape, now: 10.4))
    XCTAssertEqual(
      request.observe(ordinal: 5, orientation: 2, screen: portrait, now: 10.5), .completed)
    XCTAssertFalse(request.isPending)
  }
  func testUnsupportedRotationTimesOutWithoutRenewingDeadlineOnRepeatedClicks() {
    var request = RotationRequest()
    XCTAssertTrue(request.begin(orientation: 0, screen: portrait, now: 0))
    XCTAssertFalse(request.begin(orientation: 0, screen: portrait, now: 3))
    request.acknowledge(after: 1)
    XCTAssertNil(request.observe(ordinal: 10, orientation: 0, screen: portrait, now: 3))
    XCTAssertEqual(
      request.observe(ordinal: 20, orientation: 0, screen: portrait, now: 4), .timedOut)
  }
  func testCancellationDiscardsAcknowledgmentAndPermitsNextRequest() {
    var request = RotationRequest()
    request.begin(orientation: 0, screen: portrait, now: 0)
    request.cancel()
    request.acknowledge(after: 1)
    XCTAssertNil(request.observe(ordinal: 2, orientation: 2, screen: landscape, now: 1))
    XCTAssertTrue(request.begin(orientation: 2, screen: landscape, now: 2))
    XCTAssertNil(request.observe(ordinal: 3, orientation: 3, screen: landscape, now: 2.1))
    request.acknowledge(after: 3)
    XCTAssertEqual(
      request.observe(ordinal: 4, orientation: 3, screen: landscape, now: 2.2), .completed)
  }
}
