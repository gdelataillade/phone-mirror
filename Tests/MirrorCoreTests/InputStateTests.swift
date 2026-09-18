import XCTest

@testable import MirrorCore

final class InputStateTests: XCTestCase {
  func testModifierReleaseAfterFocusLossNeverBecomesAPress() {
    var state = KeyboardState()
    XCTAssertTrue(state.modifiersChanged([225]).isEmpty)
    XCTAssertEqual(
      state.keyDown(4, modifiers: [225], repeating: false),
      [.init(225, down: true), .init(4, down: true)])
    XCTAssertEqual(state.releaseAll(), [.init(4, down: false), .init(225, down: false)])
    XCTAssertTrue(state.modifiersChanged([]).isEmpty)
    XCTAssertTrue(state.keyUp(4).isEmpty)
    XCTAssertTrue(state.isEmpty)
  }
  func testRepeatCannotRestartKeyAfterReconnect() {
    var state = KeyboardState()
    _ = state.keyDown(42, modifiers: [], repeating: false)
    XCTAssertTrue(state.keyDown(42, modifiers: [], repeating: true).isEmpty)
    _ = state.releaseAll()
    XCTAssertTrue(state.keyDown(42, modifiers: [], repeating: true).isEmpty)
    XCTAssertTrue(state.isEmpty)
  }
  func testModifiersCanChangeWhileRemoteKeyIsHeld() {
    var state = KeyboardState()
    _ = state.keyDown(4, modifiers: [], repeating: false)
    XCTAssertEqual(state.modifiersChanged([229]), [.init(229, down: true)])
    XCTAssertEqual(state.modifiersChanged([]), [.init(229, down: false)])
    XCTAssertEqual(state.keyUp(4), [.init(4, down: false)])
  }
  func testBothShiftKeysAndRightOptionPreserveTheirIdentity() {
    XCTAssertEqual(ModifierKeys.usages(rawFlags: 0x20000 | 0x2 | 0x4), [225, 229])
    XCTAssertEqual(ModifierKeys.usages(rawFlags: 0x20000 | 0x4), [229])
    XCTAssertEqual(ModifierKeys.usages(rawFlags: 0x80000 | 0x40), [230])
    XCTAssertEqual(ModifierKeys.usages(rawFlags: 0x100000), [227])
    XCTAssertEqual(ModifierKeys.usages(rawFlags: 0x4), [])
  }
  func testRemoteShortcutPressesModifiersBeforeKeyAndReleasesKeysFirst() {
    var state = KeyboardState()
    XCTAssertEqual(
      state.keyDown(4, modifiers: [227, 225], repeating: false),
      [.init(225, down: true), .init(227, down: true), .init(4, down: true)])
    XCTAssertEqual(
      state.releaseAll(), [.init(4, down: false), .init(225, down: false), .init(227, down: false)])
  }
  func testNaturalPortraitFramesSupportRotatedInputAndUnknownOrientationDisablesInput() {
    let view = CGSize(width: 800, height: 600)
    let portrait = CGSize(width: 1200, height: 2600)
    XCTAssertEqual(
      InputGeometry(view: view, screen: portrait, rawOrientation: 2)?.screen,
      CGSize(width: 2600, height: 1200))
    XCTAssertNil(InputGeometry(view: view, screen: portrait, rawOrientation: 4))
    XCTAssertNotNil(InputGeometry(view: view, screen: portrait, rawOrientation: 1))
    XCTAssertNotNil(
      InputGeometry(view: view, screen: CGSize(width: 2600, height: 1200), rawOrientation: 3))
  }
  func testDragOutsidePictureClampsButInitialClickInLetterboxIsRejected() {
    let geometry = InputGeometry(
      view: CGSize(width: 800, height: 600), screen: CGSize(width: 1200, height: 2600),
      rawOrientation: 0)!
    XCTAssertNil(geometry.point(CGPoint(x: 0, y: 300)))
    let edge = geometry.point(CGPoint(x: -500, y: 1000), clamp: true)!
    XCTAssertEqual(edge.0, 0)
    XCTAssertEqual(edge.1, 65535)
    XCTAssertNil(geometry.point(CGPoint(x: Double.nan, y: 0), clamp: true))
  }
  func testResizeAndRotationInvalidateCapturedGeometry() {
    let first = InputGeometry(
      view: CGSize(width: 400, height: 800), screen: CGSize(width: 1200, height: 2600),
      rawOrientation: 0)!
    XCTAssertNotEqual(
      first,
      InputGeometry(view: CGSize(width: 600, height: 800), screen: first.screen, rawOrientation: 0))
    XCTAssertNotEqual(
      first, InputGeometry(view: first.view, screen: first.screen, rawOrientation: 1))
  }
  func testLongScrollReanchorsAfterReachingEdge() {
    var scroll = ScrollGesture()
    let rect = CGRect(x: 20, y: 10, width: 300, height: 600)
    _ = scroll.move(
      at: CGPoint(x: 150, y: 100), delta: CGSize(width: 0, height: -500), within: rect)
    XCTAssertEqual(scroll.position?.y, 12)
    let next = scroll.move(
      at: CGPoint(x: 150, y: 100), delta: CGSize(width: 0, height: -100), within: rect)
    XCTAssertEqual(
      next, [.release, .contact(CGPoint(x: 170, y: 310)), .contact(CGPoint(x: 170, y: 210))])
    XCTAssertEqual(scroll.end(), [.release])
    XCTAssertTrue(scroll.end().isEmpty)
  }
  func testScrollIgnoresLetterboxZeroDeltaAndNonFiniteInput() {
    var scroll = ScrollGesture()
    let rect = CGRect(x: 20, y: 20, width: 300, height: 600)
    XCTAssertTrue(scroll.move(at: .zero, delta: CGSize(width: 0, height: 10), within: rect).isEmpty)
    XCTAssertTrue(scroll.move(at: CGPoint(x: 100, y: 100), delta: .zero, within: rect).isEmpty)
    XCTAssertTrue(
      scroll.move(
        at: CGPoint(x: 100, y: 100), delta: CGSize(width: CGFloat.infinity, height: 0), within: rect
      ).isEmpty)
    XCTAssertNil(scroll.position)
  }
}
