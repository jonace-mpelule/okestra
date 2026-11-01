import Foundation

public struct CanvasZoom: Equatable, Sendable {
  // Nil follows the available canvas; 1 means one video pixel per display pixel.
  public private(set) var scale: Double?
  public init() {}
  public mutating func fit() { scale = nil }
  public mutating func actualSize() { scale = 1 }
  public func resolved(fittedScale: Double) -> Double {
    scale ?? max(0.001, fittedScale)
  }
  public mutating func step(inwards: Bool, fittedScale: Double) {
    let current = resolved(fittedScale: fittedScale)
    scale = min(4, max(0.1, current + (inwards ? 0.05 : -0.05)))
  }
}

extension DeviceFrameLayout {
  public func scaled(by factor: Double) -> DeviceFrameLayout {
    DeviceFrameLayout(
      width: width * factor, height: height * factor,
      screenWidth: screenWidth * factor, screenHeight: screenHeight * factor,
      insetX: insetX * factor, insetY: insetY * factor,
      bodyRadius: bodyRadius * factor, screenRadius: screenRadius * factor)
  }
}

public enum DeviceRotationGeometry {
  public static func angle(from: DeviceFrameLayout) -> Double {
    from.width > from.height ? -90 : 90
  }
  public static func scale(from: DeviceFrameLayout, to: DeviceFrameLayout) -> Double {
    to.width / max(1, from.height)
  }
}

public enum FocusWindowGeometry {
  public static let titlebarHeight = 28.0
  public static func frame(deviceSize: CGSize, screen: CGRect, anchor: CGRect) -> CGRect {
    let portrait = deviceSize.height >= deviceSize.width
    let maxWidth = max(1, min(portrait ? 340 : 640, screen.width - 32))
    let maxHeight = max(1, min(portrait ? 760 : 400, screen.height - 60))
    let factor = min(
      maxWidth / max(1, deviceSize.width),
      max(1, maxHeight - titlebarHeight) / max(1, deviceSize.height))
    let width = min(maxWidth, max(220, deviceSize.width * factor))
    let height = min(maxHeight, max(320, deviceSize.height * factor + titlebarHeight))
    return CGRect(
      x: max(screen.minX + 16, min(screen.maxX - width - 16, anchor.maxX - width)),
      y: max(screen.minY + 16, min(screen.maxY - height - 16, anchor.maxY - height)),
      width: width, height: height)
  }
}
