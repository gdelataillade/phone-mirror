import XCTest

@testable import MirrorCore

final class AudioPlaybackBudgetTests: XCTestCase {
  func testStalledOutputCannotGrowPastLimit() {
    let budget = AudioPlaybackBudget(limit: 9600)
    for _ in 0..<20 { XCTAssertNotNil(budget.reserve(480)) }
    XCTAssertNil(budget.reserve(480))
    XCTAssertNil(budget.reserve(UInt32.max))
  }

  func testOldCompletionCannotFreeNewStreamCapacity() {
    let budget = AudioPlaybackBudget(limit: 480)
    let old = budget.reserve(480)!
    budget.reset()
    let current = budget.reserve(480)!
    budget.complete(480, generation: old)
    XCTAssertNil(budget.reserve(480))
    budget.complete(480, generation: current)
    XCTAssertNotNil(budget.reserve(480))
  }

  func testConfigurationChangeBlocksSchedulingUntilOwnerRecovers() {
    let budget = AudioPlaybackBudget(limit: 480)
    budget.invalidate()
    XCTAssertNil(budget.reserve(480))
    XCTAssertTrue(budget.takeInvalidation())
    budget.reset()
    XCTAssertFalse(budget.takeInvalidation())
    XCTAssertNotNil(budget.reserve(480))
  }
}
