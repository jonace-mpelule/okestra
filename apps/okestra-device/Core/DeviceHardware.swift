import Foundation

public struct DeviceIdentity: Sendable {
  public var model: String
  public var avd: String
  public var nativeWidth: Int
  public var nativeHeight: Int
  public init(model: String = "Android", avd: String = "", width: Int = 0, height: Int = 0) {
    self.model = model
    self.avd = avd
    nativeWidth = width
    nativeHeight = height
  }
  public static func parse(model: String, avd: String, size: String) -> DeviceIdentity {
    // wm size may contain both Physical and Override size. The last valid value is the active one.
    let sizes = size.components(separatedBy: .newlines).compactMap { line -> (Int, Int)? in
      guard let tail = line.split(separator: ":").last else { return nil }
      let parts = tail.trimmingCharacters(in: .whitespaces).split(separator: "x")
      guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else {
        return nil
      }
      return (w, h)
    }
    let active = sizes.last ?? (0, 0)
    return DeviceIdentity(
      model: model.trimmingCharacters(in: .whitespacesAndNewlines),
      avd: avd.trimmingCharacters(in: .whitespacesAndNewlines), width: active.0, height: active.1)
  }
}

public struct DeviceChassis: Sendable {
  public let name: String
  public let classic: Bool
  public let side: Double
  public let end: Double
  public let bodyRadius: Double
  public let screenRadius: Double
  // A presentation skin only: the guest's native screen aspect ratio is preserved.
  public static let pixel7Skin: DeviceChassis = {
    // Google's 160.5 mm diagonal / 1080 × 2400 panel in a 73.2 × 155.6 mm body.
    // https://support.google.com/pixelphone/answer/7158570
    let panelWidth = 160.5 / sqrt(1 + pow(2400.0 / 1080, 2))
    return DeviceChassis(
      name: "Pixel 7", classic: false,
      side: (73.2 - panelWidth) / 2 / panelWidth,
      end: (155.6 - panelWidth * 2400 / 1080) / 2 / panelWidth,
      bodyRadius: 0.115, screenRadius: 0.085)
  }()
  // Bezels are proportions of portrait screen width, not fixed points. They scale with the device.
  public static func resolve(_ identity: DeviceIdentity, videoWidth: Double, videoHeight: Double)
    -> DeviceChassis
  {
    let name = (identity.model + " " + identity.avd).lowercased()
    let w = min(identity.nativeWidth, identity.nativeHeight)
    let h = max(identity.nativeWidth, identity.nativeHeight)
    if name.contains("pixel 7") || name.contains("pixel_7") {
      return pixel7Skin
    }
    // The bundled installer creates avdmanager's original `pixel` hardware profile.
    // Physical dimensions / display: https://support.google.com/pixelphone/answer/16043605
    if (identity.avd == "okestra-pixel" || name.contains("sailfish") || identity.model == "Pixel")
      && w == 1080 && h == 1920
    {
      return DeviceChassis(
        name: "Google Pixel", classic: true, side: (69.54 - 62.26) / 2 / 62.26,
        end: (143.84 - 110.69) / 2 / 62.26, bodyRadius: 0.12, screenRadius: 0.006)
    }
    // Pixel 9: 72 × 152.8 mm body, 1080 × 2424 display.
    // https://support.google.com/pixelphone/answer/7158570
    if (name.contains("pixel 9") || name.contains("pixel_9")) && !name.contains("pro")
      && !name.contains("xl")
    {
      return DeviceChassis(
        name: "Google Pixel 9", classic: false, side: 0.053, end: 0.051,
        bodyRadius: 0.15, screenRadius: 0.105)
    }
    let ratio = max(videoWidth, videoHeight) / max(1, min(videoWidth, videoHeight))
    let generic =
      identity.model.isEmpty || identity.model.lowercased().contains("sdk")
      || identity.model.lowercased().contains("gphone")
    return DeviceChassis(
      name: generic ? "Android emulator" : identity.model, classic: ratio < 1.9,
      side: ratio < 1.9 ? 0.05 : 0.025, end: ratio < 1.9 ? 0.18 : 0.025,
      bodyRadius: ratio < 1.9 ? 0.12 : 0.14, screenRadius: ratio < 1.9 ? 0.006 : 0.10)
  }
  public func layout(
    videoWidth: Double, videoHeight: Double, availableWidth: Double, availableHeight: Double,
    framed: Bool
  ) -> DeviceFrameLayout {
    let landscape = videoWidth > videoHeight
    let short = max(1, min(videoWidth, videoHeight))
    let insetX = framed ? short * (landscape ? end : side) : 0
    let insetY = framed ? short * (landscape ? side : end) : 0
    let outerW = max(1, videoWidth) + insetX * 2
    let outerH = max(1, videoHeight) + insetY * 2
    let scale = max(0.001, min(max(1, availableWidth) / outerW, max(1, availableHeight) / outerH))
    return DeviceFrameLayout(
      width: outerW * scale, height: outerH * scale,
      screenWidth: max(1, videoWidth) * scale, screenHeight: max(1, videoHeight) * scale,
      insetX: insetX * scale, insetY: insetY * scale,
      bodyRadius: short * bodyRadius * scale, screenRadius: short * screenRadius * scale)
  }
}
public struct DeviceFrameLayout: Sendable {
  public let width, height, screenWidth, screenHeight, insetX, insetY, bodyRadius,
    screenRadius: Double
}
