import CoreGraphics
import Foundation

public enum DisplayOrientation: UInt32, Sendable {
  case portrait = 0
  case upsideDown, landscapeLeft, landscapeRight
}

/// CoreDevice can retain the natural portrait pixel buffer while iOS rotates its content.
public struct ScreenPresentation: Equatable {
  public let size: CGSize
  public let clockwiseQuarterTurns: Int
  public init?(encoded: CGSize, rawOrientation: UInt32) {
    guard let orientation = DisplayOrientation(rawValue: rawOrientation),
      [encoded.width, encoded.height].allSatisfy({ $0.isFinite && $0 > 0 })
    else { return nil }
    let landscape = orientation == .landscapeLeft || orientation == .landscapeRight
    if encoded.width > encoded.height {
      // Some stream configurations already orient their encoded pixels.
      guard landscape else { return nil }
      size = encoded
      clockwiseQuarterTurns = 0
    } else {
      size = landscape ? CGSize(width: encoded.height, height: encoded.width) : encoded
      switch orientation {
      case .portrait: clockwiseQuarterTurns = 0
      case .upsideDown: clockwiseQuarterTurns = 2
      case .landscapeLeft: clockwiseQuarterTurns = 3
      case .landscapeRight: clockwiseQuarterTurns = 1
      }
    }
  }
}

public enum MirrorGeometry {
  public static func contentRect(view: CGSize, screen: CGSize) -> CGRect {
    guard
      [view.width, view.height, screen.width, screen.height].allSatisfy({ $0.isFinite && $0 > 0 })
    else { return .zero }
    let scale = min(view.width / screen.width, view.height / screen.height)
    let size = CGSize(width: screen.width * scale, height: screen.height * scale)
    return CGRect(
      x: (view.width - size.width) / 2, y: (view.height - size.height) / 2, width: size.width,
      height: size.height)
  }
  /// Coordinates use a top-left origin, exclude letterboxing, and target the natural portrait digitizer.
  public static func touch(
    point: CGPoint, view: CGSize, screen: CGSize, orientation: DisplayOrientation
  ) -> (UInt32, UInt32)? {
    let rect = contentRect(view: view, screen: screen)
    guard point.x.isFinite, point.y.isFinite, rect.width > 0, rect.height > 0, point.x >= rect.minX,
      point.x <= rect.maxX,
      point.y >= rect.minY, point.y <= rect.maxY
    else { return nil }
    let x = (point.x - rect.minX) / rect.width
    let y = (point.y - rect.minY) / rect.height
    let native: CGPoint
    switch orientation {
    case .portrait: native = CGPoint(x: x, y: y)
    case .upsideDown: native = CGPoint(x: 1 - x, y: 1 - y)
    case .landscapeLeft: native = CGPoint(x: 1 - y, y: x)
    case .landscapeRight: native = CGPoint(x: y, y: 1 - x)
    }
    return (
      UInt32((min(max(native.x, 0), 1) * 65535).rounded()),
      UInt32((min(max(native.y, 0), 1) * 65535).rounded())
    )
  }
}

public enum KeyboardMap {
  // macOS hardware keycodes → USB HID usages. The iPhone's hardware-keyboard layout interprets them.
  public static let usages: [UInt16: UInt32] = [
    0: 4, 1: 22, 2: 7, 3: 9, 4: 11, 5: 10, 6: 29, 7: 27, 8: 6, 9: 25, 10: 100, 11: 5, 12: 20,
    13: 26, 14: 8, 15: 21, 16: 28, 17: 23,
    18: 30, 19: 31, 20: 32, 21: 33, 22: 35, 23: 34, 24: 46, 25: 38, 26: 36, 27: 45, 28: 37, 29: 39,
    30: 48, 31: 18,
    32: 24, 33: 47, 34: 12, 35: 19, 36: 40, 37: 15, 38: 13, 39: 52, 40: 14, 41: 51, 42: 49, 43: 54,
    44: 56, 45: 17,
    46: 16, 47: 55, 48: 43, 49: 44, 50: 53, 51: 42, 53: 41, 55: 227, 54: 231, 56: 225, 60: 229,
    58: 226, 61: 230,
    59: 224, 62: 228, 57: 57, 65: 99, 67: 85, 69: 87, 71: 83, 75: 84, 76: 88, 78: 86, 81: 103,
    82: 98, 83: 89,
    84: 90, 85: 91, 86: 92, 87: 93, 88: 94, 89: 95, 91: 96, 92: 97, 96: 62, 97: 63, 98: 64, 99: 60,
    100: 65,
    101: 66, 103: 68, 109: 67, 111: 69, 115: 74, 116: 75, 117: 76, 118: 61, 119: 77, 120: 59,
    121: 78, 122: 58,
    123: 80, 124: 79, 125: 81, 126: 82,
  ]
}
