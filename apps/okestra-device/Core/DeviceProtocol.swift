import Foundation

public enum DeviceError: Error, LocalizedError {
  case message(String)
  public var errorDescription: String? {
    if case .message(let text) = self { return text }
    return nil
  }
}

extension Data {
  public func unsigned(at offset: Int, bytes: Int) throws -> UInt64 {
    guard offset >= 0, bytes > 0, bytes <= 8, offset + bytes <= count else {
      throw DeviceError.message("Truncated device packet")
    }
    return self.dropFirst(offset).prefix(bytes).reduce(0) { ($0 << 8) | UInt64($1) }
  }
  public mutating func appendBE(_ value: UInt64, bytes: Int) {
    for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) {
      append(UInt8(truncatingIfNeeded: value >> shift))
    }
  }
}

public struct VideoPacket {
  public let config: Bool
  public let keyframe: Bool
  public let length: Int
  public let timestampMicroseconds: UInt64
  public init(header: Data) throws {
    guard header.count == 12 else { throw DeviceError.message("Invalid frame header") }
    let flags = try header.unsigned(at: 0, bytes: 8)
    timestampMicroseconds = flags & ((1 << 62) - 1)
    config = flags & (1 << 63) != 0
    keyframe = flags & (1 << 62) != 0
    length = Int(try header.unsigned(at: 8, bytes: 4))
    guard length > 0, length <= 8 * 1024 * 1024 else {
      throw DeviceError.message("Device frame exceeds the supported size")
    }
  }
}

public enum H264 {
  // Android MediaCodec emits Annex B. CoreMedia expects length-prefixed NAL units.
  public static func units(_ data: Data) throws -> [Data] {
    let b = [UInt8](data)
    var boundaries: [(Int, Int)] = []
    var i = 0
    while i + 2 < b.count {
      if b[i] == 0 && b[i + 1] == 0 {
        if b[i + 2] == 1 {
          boundaries.append((i, 3))
          i += 3
          continue
        }
        if i + 3 < b.count && b[i + 2] == 0 && b[i + 3] == 1 {
          boundaries.append((i, 4))
          i += 4
          continue
        }
      }
      i += 1
    }
    guard !boundaries.isEmpty, boundaries[0].0 == 0 else {
      throw DeviceError.message("Unsupported H.264 framing")
    }
    var result: [Data] = []
    for (index, entry) in boundaries.enumerated() {
      let end = index + 1 < boundaries.count ? boundaries[index + 1].0 : b.count
      let start = entry.0 + entry.1
      guard end > start else { throw DeviceError.message("Empty H.264 NAL unit") }
      result.append(Data(b[start..<end]))
    }
    return result
  }
  public static func avcc(_ units: [Data]) -> Data {
    var result = Data()
    for unit in units {
      result.appendBE(UInt64(unit.count), bytes: 4)
      result.append(unit)
    }
    return result
  }
}

public enum ControlPacket {
  public static func key(_ code: UInt32, down: Bool) -> Data {
    var b = Data([0, down ? 0 : 1])
    b.appendBE(UInt64(code), bytes: 4)
    b.appendBE(0, bytes: 8)
    return b
  }
  public static func touch(action: UInt8, x: Int, y: Int, width: Int, height: Int) -> Data {
    var b = Data([2, action])
    b.appendBE(UInt64.max - 1, bytes: 8)  // generic finger
    b.appendBE(UInt64(max(0, min(width - 1, x))), bytes: 4)
    b.appendBE(UInt64(max(0, min(height - 1, y))), bytes: 4)
    b.appendBE(UInt64(max(1, min(65535, width))), bytes: 2)
    b.appendBE(UInt64(max(1, min(65535, height))), bytes: 2)
    b.appendBE(action == 1 || action == 3 ? 0 : 65535, bytes: 2)
    b.appendBE(0, bytes: 8)
    return b
  }
  public static func text(_ value: String) -> Data {
    let text = boundedUTF8(value, limit: 300)
    var b = Data([1])
    b.appendBE(UInt64(text.count), bytes: 4)
    b.append(text)
    return b
  }
  public static func paste(_ value: String) -> Data {
    let text = boundedUTF8(value, limit: 64 * 1024)
    var b = Data([9])
    b.appendBE(0, bytes: 8)
    b.append(1)
    b.appendBE(UInt64(text.count), bytes: 4)
    b.append(text)
    return b
  }
  private static func boundedUTF8(_ text: String, limit: Int) -> Data {
    var out = Data()
    for scalar in text.unicodeScalars {
      let b = Data(String(scalar).utf8)
      if out.count + b.count > limit { break }
      out.append(b)
    }
    return out
  }
}

public enum ScreenGeometry {
  public static func fitted(
    containerWidth: Double, containerHeight: Double, videoWidth: Double, videoHeight: Double
  ) -> (Double, Double, Double, Double) {
    let scale = min(containerWidth / max(1, videoWidth), containerHeight / max(1, videoHeight))
    let w = videoWidth * scale
    let h = videoHeight * scale
    return ((containerWidth - w) / 2, (containerHeight - h) / 2, w, h)
  }
}
