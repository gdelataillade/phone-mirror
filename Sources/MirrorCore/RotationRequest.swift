import CoreGraphics
import Foundation

/// Rotation is complete only when a fresh, usable picture shows a changed orientation.
public struct RotationRequest {
  public enum Outcome: Equatable { case completed, timedOut }
  public private(set) var isPending = false
  private var deadline: TimeInterval = 0
  private var initialOrientation: UInt32 = 0
  private var initialScreen = CGSize.zero
  private var acknowledgedAfter: UInt64?
  public init() {}

  @discardableResult public mutating func begin(
    orientation: UInt32, screen: CGSize, now: TimeInterval
  ) -> Bool {
    guard !isPending else { return false }
    isPending = true
    initialOrientation = orientation
    initialScreen = screen
    acknowledgedAfter = nil
    deadline = now + 4
    return true
  }
  public mutating func acknowledge(after ordinal: UInt64) {
    guard isPending else { return }
    acknowledgedAfter = ordinal
  }
  public mutating func observe(
    ordinal: UInt64, orientation: UInt32, screen: CGSize, now: TimeInterval
  ) -> Outcome? {
    guard isPending else { return nil }
    if let acknowledgedAfter, ordinal > acknowledgedAfter,
      orientation != initialOrientation || screen != initialScreen,
      InputGeometry(view: screen, screen: screen, rawOrientation: orientation) != nil
    {
      cancel()
      return .completed
    }
    if now >= deadline {
      cancel()
      return .timedOut
    }
    return nil
  }
  public mutating func cancel() {
    isPending = false
    acknowledgedAfter = nil
  }
}
