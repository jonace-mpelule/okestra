import Foundation

public struct DeviceNetworkSnapshot: Sendable {
  public let elapsedMilliseconds: UInt64
  public let receivedBytes: UInt64
  public let transmittedBytes: UInt64
  public init(elapsedMilliseconds: UInt64, receivedBytes: UInt64, transmittedBytes: UInt64) {
    self.elapsedMilliseconds = elapsedMilliseconds
    self.receivedBytes = receivedBytes
    self.transmittedBytes = transmittedBytes
  }
  public init(data: Data) throws {
    struct Envelope: Decodable {
      let version: Int
      let error: String?
      let elapsed_ms: UInt64?
      let received_bytes: UInt64?
      let transmitted_bytes: UInt64?
    }
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.version == 1 else {
      throw DeviceError.message("Unsupported network monitor version.")
    }
    if let error = envelope.error { throw DeviceError.message(String(error.prefix(256))) }
    guard let elapsed = envelope.elapsed_ms, let rx = envelope.received_bytes,
      let tx = envelope.transmitted_bytes
    else {
      throw DeviceError.message("Incomplete network counter sample.")
    }
    self.init(elapsedMilliseconds: elapsed, receivedBytes: rx, transmittedBytes: tx)
  }
}
public struct DeviceNetworkRate: Sendable, Equatable {
  public let uploadMbps: Double
  public let downloadMbps: Double
  public init(uploadMbps: Double, downloadMbps: Double) {
    self.uploadMbps = uploadMbps.isFinite ? max(0, uploadMbps) : 0
    self.downloadMbps = downloadMbps.isFinite ? max(0, downloadMbps) : 0
  }
}
public struct DeviceNetworkEstimator: Sendable {
  private var previous: DeviceNetworkSnapshot?
  public init() {}
  public mutating func reset() { previous = nil }
  public mutating func observe(_ value: DeviceNetworkSnapshot) -> DeviceNetworkRate? {
    defer { previous = value }
    guard let old = previous, value.elapsedMilliseconds > old.elapsedMilliseconds,
      value.receivedBytes >= old.receivedBytes, value.transmittedBytes >= old.transmittedBytes
    else { return nil }
    let elapsed = value.elapsedMilliseconds - old.elapsedMilliseconds
    // Seed a fresh baseline across sleep, device reboots or missing readings.
    guard elapsed <= 5_000 else { return nil }
    let seconds = Double(elapsed) / 1_000
    return DeviceNetworkRate(
      uploadMbps: Double(value.transmittedBytes - old.transmittedBytes) * 8 / seconds / 1_000_000,
      downloadMbps: Double(value.receivedBytes - old.receivedBytes) * 8 / seconds / 1_000_000)
  }
}
public struct DeviceNetworkHistory: Sendable {
  public private(set) var samples: [DeviceNetworkRate?]
  public init() { samples = Array(repeating: nil, count: 60) }
  public mutating func append(_ sample: DeviceNetworkRate?) {
    samples = Array((samples + [sample]).suffix(60))
  }
  public mutating func reset() { samples = Array(repeating: nil, count: 60) }
  public var ceilingMbps: Double {
    let peak = samples.compactMap { $0 }.reduce(1.0) { max($0, $1.uploadMbps, $1.downloadMbps) }
    let power = pow(10, floor(log10(peak)))
    let factor = peak / power
    return (factor <= 1 ? 1 : factor <= 2 ? 2 : factor <= 5 ? 5 : 10) * power
  }
}
public enum DuplexNetworkGeometry {
  public static func y(
    rate: Double, ceiling: Double, center: Double, halfHeight: Double, upload: Bool
  ) -> Double {
    let magnitude = max(0, min(1, rate / max(0.001, ceiling))) * max(0, halfHeight)
    return center + (upload ? -magnitude : magnitude)
  }
}
