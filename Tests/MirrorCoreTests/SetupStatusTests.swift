import Foundation
import XCTest

@testable import MirrorCore

final class SetupStatusTests: XCTestCase {
  private func decode(_ json: String) throws -> SetupStatus {
    try JSONDecoder().decode(SetupStatus.self, from: Data(json.utf8))
  }

  func testPreparedPhoneIsReady() throws {
    // Exact output of pm_prepare_status for an iPhone 17 Xcode 27 had prepared.
    let status = try decode(
      #"{"connected":true,"ddiMounted":true,"ddiOnMac":true,"ddiVersion":"27A266a","developerMode":true,"developerServices":true,"trusted":true}"#
    )
    XCTAssertTrue(status.isReady)
    XCTAssertEqual(status.ddiVersion, "27A266a")
    XCTAssertNil(status.detail)
  }

  func testLaterStepsStayUnknownAfterAnEarlierFailure() throws {
    let noPhone = try decode(
      #"{"connected":false,"ddiMounted":null,"ddiOnMac":true,"developerMode":null,"trusted":null,"ddiVersion":null,"detail":"Connect this iPhone by USB and unlock it."}"#
    )
    XCTAssertEqual(noPhone.state(of: .components), .done)
    for step in [SetupStatus.Step.trust, .developerMode, .services] {
      XCTAssertEqual(noPhone.state(of: step), .unknown, "\(step)")
    }
    XCTAssertFalse(noPhone.isReady)

    let untrusted = try decode(#"{"connected":true,"ddiOnMac":true,"trusted":false}"#)
    XCTAssertEqual(untrusted.state(of: .trust), .needed)
    XCTAssertEqual(untrusted.state(of: .developerMode), .unknown)

    let developerModeOff = try decode(
      #"{"connected":true,"ddiOnMac":true,"trusted":true,"developerMode":false}"#)
    XCTAssertEqual(developerModeOff.state(of: .developerMode), .needed)
    XCTAssertEqual(developerModeOff.state(of: .services), .unknown)
  }

  func testMountedImageWithoutRunningServicesIsNotReady() throws {
    // The state a crash-looping cryptexd left behind: mounted, nothing advertised.
    let stuck = try decode(
      #"{"connected":true,"ddiMounted":true,"ddiOnMac":true,"ddiVersion":"27A266a","developerMode":true,"developerServices":false,"trusted":true,"detail":"The iPhone's developer services did not start."}"#
    )
    XCTAssertEqual(stuck.state(of: .services), .needed)
    XCTAssertFalse(stuck.isReady)
    // Service list unreadable: known missing if unmounted, otherwise unknown.
    let unmounted = SetupStatus(
      ddiOnMac: true, connected: true, trusted: true, developerMode: true, ddiMounted: false)
    XCTAssertEqual(unmounted.state(of: .services), .needed)
    let unreadable = SetupStatus(
      ddiOnMac: true, connected: true, trusted: true, developerMode: true, ddiMounted: true)
    XCTAssertEqual(unreadable.state(of: .services), .unknown)
  }

  func testMacComponentsAreOnlyNeededForAnUnpreparedPhone() {
    let prepared = SetupStatus(
      ddiOnMac: false, connected: true, trusted: true, developerMode: true, ddiMounted: true,
      developerServices: true)
    XCTAssertEqual(prepared.state(of: .components), .done)
    XCTAssertTrue(prepared.isReady)
    let unprepared = SetupStatus(
      ddiOnMac: false, connected: true, trusted: true, developerMode: true, ddiMounted: false)
    XCTAssertEqual(unprepared.state(of: .components), .needed)
    XCTAssertEqual(unprepared.state(of: .services), .needed)
  }

  func testFailurePrefixMatchesTheBackend() {
    // Backend/src/lib.rs DEVELOPER_SERVICES_UNAVAILABLE.
    XCTAssertEqual(developerServicesUnavailablePrefix, "Developer services are unavailable.")
  }
}
