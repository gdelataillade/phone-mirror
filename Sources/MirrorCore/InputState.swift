import CoreGraphics
import Foundation

public struct KeyTransition: Equatable {
  public let usage: UInt32
  public let down: Bool
  public init(_ usage: UInt32, down: Bool) {
    self.usage = usage
    self.down = down
  }
}

/// Tracks only keys actually sent to the phone. Modifier releases never manufacture presses.
public struct KeyboardState {
  public private(set) var keys: Set<UInt32> = []
  public private(set) var modifiers: Set<UInt32> = []
  public init() {}
  public var isEmpty: Bool { keys.isEmpty && modifiers.isEmpty }
  public mutating func modifiersChanged(_ desired: Set<UInt32>) -> [KeyTransition] {
    let released = modifiers.subtracting(desired).sorted()
    modifiers.formIntersection(desired)
    var result = released.map { KeyTransition($0, down: false) }
    if !keys.isEmpty {
      for modifier in desired.subtracting(modifiers).sorted() {
        modifiers.insert(modifier)
        result.append(KeyTransition(modifier, down: true))
      }
    }
    return result
  }
  public mutating func keyDown(_ usage: UInt32, modifiers desired: Set<UInt32>, repeating: Bool)
    -> [KeyTransition]
  {
    // A repeat arriving after focus loss or reconnection must not restart a held key.
    guard !repeating else { return [] }
    var result = modifiersChanged(desired)
    for modifier in desired.subtracting(modifiers).sorted() {
      modifiers.insert(modifier)
      result.append(KeyTransition(modifier, down: true))
    }
    if keys.insert(usage).inserted { result.append(KeyTransition(usage, down: true)) }
    return result
  }
  public mutating func keyUp(_ usage: UInt32) -> [KeyTransition] {
    keys.remove(usage) == nil ? [] : [KeyTransition(usage, down: false)]
  }
  public mutating func releaseAll() -> [KeyTransition] {
    let result = (keys.sorted() + modifiers.sorted()).map { KeyTransition($0, down: false) }
    keys.removeAll()
    modifiers.removeAll()
    return result
  }
}

public enum ModifierKeys {
  /// Public IOLLEvent.h device-dependent masks preserve left/right Option and Control.
  public static func usages(rawFlags: UInt64) -> Set<UInt32> {
    var result: Set<UInt32> = []
    let groups: [(UInt64, UInt64, UInt64, UInt32, UInt32)] = [
      (0x40000, 0x1, 0x2000, 224, 228), (0x20000, 0x2, 0x4, 225, 229),
      (0x80000, 0x20, 0x40, 226, 230), (0x100000, 0x8, 0x10, 227, 231),
    ]
    for (aggregate, left, right, leftUsage, rightUsage) in groups where rawFlags & aggregate != 0 {
      if rawFlags & left != 0 { result.insert(leftUsage) }
      if rawFlags & right != 0 { result.insert(rightUsage) }
      // Some keyboards and accessibility events supply only aggregate flags.
      if rawFlags & (left | right) == 0 { result.insert(leftUsage) }
    }
    return result
  }
}

public struct InputGeometry: Equatable {
  public let view: CGSize
  public let screen: CGSize
  public let orientation: DisplayOrientation
  public init?(view: CGSize, screen: CGSize, rawOrientation: UInt32) {
    guard let orientation = DisplayOrientation(rawValue: rawOrientation),
      let presentation = ScreenPresentation(encoded: screen, rawOrientation: rawOrientation),
      MirrorGeometry.contentRect(view: view, screen: presentation.size) != .zero
    else { return nil }
    self.view = view
    self.screen = presentation.size
    self.orientation = orientation
  }
  public var contentRect: CGRect { MirrorGeometry.contentRect(view: view, screen: screen) }
  public func point(_ point: CGPoint, clamp: Bool = false) -> (UInt32, UInt32)? {
    guard point.x.isFinite, point.y.isFinite else { return nil }
    let rect = contentRect
    let target =
      clamp
      ? CGPoint(
        x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
      : point
    return MirrorGeometry.touch(point: target, view: view, screen: screen, orientation: orientation)
  }
}

public enum TouchTransition: Equatable {
  case contact(CGPoint)
  case release
}

/// Wheel/trackpad scrolling is a bounded sequence of swipes, reanchored at an edge.
public struct ScrollGesture {
  public private(set) var position: CGPoint?
  public init() {}
  public mutating func move(at point: CGPoint, delta: CGSize, within rect: CGRect)
    -> [TouchTransition]
  {
    guard rect.width > 4, rect.height > 4,
      [point.x, point.y, delta.width, delta.height].allSatisfy(\.isFinite),
      delta.width != 0 || delta.height != 0
    else { return [] }
    let safe = rect.insetBy(dx: 2, dy: 2)
    var result: [TouchTransition] = []
    if position == nil {
      guard rect.contains(point) else { return [] }
      position = CGPoint(
        x: min(max(point.x, safe.minX), safe.maxX), y: min(max(point.y, safe.minY), safe.maxY))
      result.append(.contact(position!))
    }
    let old = position!
    let hitsEdge =
      (old.x <= safe.minX && delta.width < 0) || (old.x >= safe.maxX && delta.width > 0)
      || (old.y <= safe.minY && delta.height < 0) || (old.y >= safe.maxY && delta.height > 0)
    if hitsEdge {
      result.append(.release)
      position = CGPoint(x: safe.midX, y: safe.midY)
      result.append(.contact(position!))
    }
    let next = CGPoint(
      x: min(max(position!.x + delta.width, safe.minX), safe.maxX),
      y: min(max(position!.y + delta.height, safe.minY), safe.maxY))
    if next != position {
      result.append(.contact(next))
      position = next
    }
    return result
  }
  public mutating func end() -> [TouchTransition] {
    guard position != nil else { return [] }
    position = nil
    return [.release]
  }
}
