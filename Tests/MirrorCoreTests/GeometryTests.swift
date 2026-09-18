import XCTest

@testable import MirrorCore

final class GeometryTests: XCTestCase {
  func testNaturalPortraitVideoRotatesWithTouchCoordinates() {
    let encoded = CGSize(width: 1200, height: 2600)
    for (raw, turns) in [(UInt32(0), 0), (1, 2), (2, 3), (3, 1)] {
      let presentation = ScreenPresentation(encoded: encoded, rawOrientation: raw)!
      XCTAssertEqual(presentation.clockwiseQuarterTurns, turns)
      XCTAssertEqual(presentation.size, raw >= 2 ? CGSize(width: 2600, height: 1200) : encoded)
      let geometry = InputGeometry(view: presentation.size, screen: encoded, rawOrientation: raw)!
      // A known native point must land on the same point after rendering and inverse input mapping.
      let native = CGPoint(x: 0.25, y: 0.75)
      let visible: CGPoint
      switch turns {
      case 1: visible = CGPoint(x: 1 - native.y, y: native.x)
      case 2: visible = CGPoint(x: 1 - native.x, y: 1 - native.y)
      case 3: visible = CGPoint(x: native.y, y: 1 - native.x)
      default: visible = native
      }
      let touch = geometry.point(
        CGPoint(
          x: visible.x * presentation.size.width,
          y: visible.y * presentation.size.height))!
      XCTAssertEqual(touch.0, 16384)
      XCTAssertEqual(touch.1, 49151)
    }
  }
  func testAlreadyOrientedLandscapePixelsAreNotRotatedTwice() {
    let encoded = CGSize(width: 2600, height: 1200)
    let presentation = ScreenPresentation(encoded: encoded, rawOrientation: 2)!
    XCTAssertEqual(presentation.size, encoded)
    XCTAssertEqual(presentation.clockwiseQuarterTurns, 0)
    XCTAssertNil(ScreenPresentation(encoded: encoded, rawOrientation: 0))
    XCTAssertNil(ScreenPresentation(encoded: .zero, rawOrientation: 2))
    XCTAssertNil(ScreenPresentation(encoded: encoded, rawOrientation: 4))
  }
  func testLetterboxRejectedAndCenterMapsPrecisely() {
    let view = CGSize(width: 800, height: 600)
    let screen = CGSize(width: 1200, height: 2600)
    XCTAssertNil(
      MirrorGeometry.touch(
        point: CGPoint(x: 20, y: 300), view: view, screen: screen, orientation: .portrait))
    let center = MirrorGeometry.touch(
      point: CGPoint(x: 400, y: 300), view: view, screen: screen, orientation: .portrait)!
    XCTAssertLessThanOrEqual(abs(Int(center.0) - 32768), 1)
    XCTAssertLessThanOrEqual(abs(Int(center.1) - 32768), 1)
  }
  func testEveryOrientationMapsTopLeftToNaturalDigitizerCorner() {
    let size = CGSize(width: 500, height: 500)
    let expected: [DisplayOrientation: (UInt32, UInt32)] = [
      .portrait: (0, 0), .upsideDown: (65535, 65535), .landscapeLeft: (65535, 0),
      .landscapeRight: (0, 65535),
    ]
    for (orientation, corner) in expected {
      let point = MirrorGeometry.touch(
        point: .zero, view: size, screen: size, orientation: orientation)!
      XCTAssertEqual(point.0, corner.0)
      XCTAssertEqual(point.1, corner.1)
    }
  }
  func testInvalidDimensionsDoNotCreateInput() {
    XCTAssertNil(
      MirrorGeometry.touch(
        point: .zero, view: .zero, screen: CGSize(width: 1, height: 1), orientation: .portrait))
    XCTAssertNil(
      MirrorGeometry.touch(
        point: .zero, view: CGSize(width: 1, height: 1), screen: .zero, orientation: .portrait))
    XCTAssertNil(
      MirrorGeometry.touch(
        point: CGPoint(x: Double.nan, y: 0), view: CGSize(width: 1, height: 1),
        screen: CGSize(width: 1, height: 1), orientation: .portrait))
    XCTAssertEqual(
      MirrorGeometry.contentRect(
        view: CGSize(width: Double.infinity, height: 1), screen: CGSize(width: 1, height: 1)), .zero
    )
  }
  func testResizingPreservesTouchLocation() {
    for size in [CGSize(width: 400, height: 800), CGSize(width: 1000, height: 650)] {
      let screen = CGSize(width: 1200, height: 2600)
      let rect = MirrorGeometry.contentRect(view: size, screen: screen)
      let touch = MirrorGeometry.touch(
        point: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.75),
        view: size, screen: screen, orientation: .portrait)!
      XCTAssertEqual(touch.0, 16384)
      XCTAssertEqual(touch.1, 49151)
    }
  }
}
