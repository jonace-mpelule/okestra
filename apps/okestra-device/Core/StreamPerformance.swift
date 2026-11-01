import Foundation

public enum StreamMode: String, CaseIterable, Sendable {
  case automatic, responsive, balanced, smooth, native
  public var title: String {
    switch self {
    case .automatic: return "Adaptive"
    case .responsive: return "Responsive"
    case .balanced: return "Balanced"
    case .smooth: return "Smooth · 60 fps"
    case .native: return "Native"
    }
  }
  public var configuration: StreamConfiguration {
    switch self {
    case .responsive: return StreamConfiguration(maxSize: 1024, maxFPS: 24, bitRate: 2_000_000)
    case .smooth: return StreamConfiguration(maxSize: 1280, maxFPS: 60, bitRate: 6_000_000)
    case .native: return StreamConfiguration(maxSize: 0, maxFPS: 0, bitRate: 40_000_000)
    default: return StreamConfiguration(maxSize: 1280, maxFPS: 30, bitRate: 4_000_000)
    }
  }
}
public struct StreamConfiguration: Equatable, Sendable {
  // scrcpy uses zero for the device's full resolution and unrestricted capture frame rate.
  public let maxSize, maxFPS, bitRate: Int
  public var summary: String {
    maxSize == 0 ? "Full resolution · Uncapped fps" : "Up to \(maxFPS) fps"
  }
  public var serverArguments: [String] {
    var args = ["max_size=\(maxSize)", "max_fps=\(maxFPS)", "video_bit_rate=\(bitRate)"]
    // Preserve the Native contract even if the device cannot encode its full display size.
    if maxSize == 0 { args.append("downsize_on_error=false") }
    return args
  }
}

// A decoded frame can safely replace another decoded frame. Compressed H.264 frames must not
// be discarded here: subsequent pictures can reference them. At most one delivery is scheduled.
public final class LatestFrameMailbox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value?
  private var scheduled = false
  private var closed = false
  public init() {}
  public func offer(_ next: Value) -> (schedule: Bool, replaced: Bool) {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return (false, false) }
    let replaced = value != nil
    value = next
    let needsSchedule = !scheduled
    scheduled = true
    return (needsSchedule, replaced)
  }
  public func take() -> Value? {
    lock.lock()
    defer { lock.unlock() }
    let next = value
    value = nil
    scheduled = false
    return next
  }
  public func close() {
    lock.lock()
    defer { lock.unlock() }
    closed = true
    value = nil
  }
}

// Relative growth in capture-to-arrival delay; deliberately NOT an absolute network latency.
// Reset on timestamp regression/reconnect. Min offset accounts for unsynchronised clocks.
public struct StreamBacklogEstimator: Sendable {
  private var offset: Double?
  private var lastPTS: UInt64?
  public init() {}
  public mutating func observe(microseconds: UInt64, arrival: Double) -> Double {
    let current = arrival - Double(microseconds) / 1_000_000
    if let lastPTS, microseconds < lastPTS { offset = nil }
    lastPTS = microseconds
    offset = min(offset ?? current, current)
    return max(0, (current - (offset ?? current)) * 1000)
  }
}
public struct StreamMeasurement: Sendable {
  public var received = 0, delivered = 0, replaced = 0, bytes = 0
  public var decodeMS = 0.0, uiWaitMS = 0.0, backlogMS = 0.0
  public var hardwareDecoder: Bool?
  public init() {}
}
public final class StreamMeasurements: @unchecked Sendable {
  private let lock = NSLock()
  private var measurement = StreamMeasurement()
  private var decodeCount = 0
  public init() {}
  public func received(bytes: Int, decodeMS: Double, backlogMS: Double, hardware: Bool?) {
    lock.lock()
    defer { lock.unlock() }
    measurement.received += 1
    measurement.bytes += bytes
    measurement.decodeMS += decodeMS
    measurement.backlogMS = max(measurement.backlogMS, backlogMS)
    measurement.hardwareDecoder = hardware
    decodeCount += 1
  }
  public func replaced() {
    lock.lock()
    measurement.replaced += 1
    lock.unlock()
  }
  public func delivered(waitMS: Double) {
    lock.lock()
    defer { lock.unlock() }
    measurement.delivered += 1
    measurement.uiWaitMS = max(measurement.uiWaitMS, waitMS)
  }
  public func snapshot() -> StreamMeasurement {
    lock.lock()
    defer { lock.unlock() }
    var value = measurement
    value.decodeMS /= Double(max(1, decodeCount))
    measurement = StreamMeasurement()
    decodeCount = 0
    return value
  }
}

// Conservative hysteresis: ignore idle screens, require sustained pressure, and impose a
// cooldown because capture changes restart only the viewer stream, never the Android app.
public struct AdaptiveStreamPolicy: Sendable {
  public private(set) var level: StreamMode = .balanced
  private var pressure = 0, healthy = 0
  private var lastChange = -Double.infinity
  public init() {}
  public mutating func reset() { self = AdaptiveStreamPolicy() }
  public mutating func evaluate(_ sample: StreamMeasurement, now: Double) -> StreamMode? {
    guard sample.received >= 5 else {
      pressure = 0
      healthy = 0
      return nil
    }
    let overloaded =
      sample.backlogMS > 100 || sample.uiWaitMS > 65 || sample.decodeMS > 30
      || Double(sample.replaced) / Double(max(1, sample.received)) > 0.20
    pressure = overloaded ? pressure + 1 : 0
    healthy = overloaded ? 0 : healthy + 1
    guard now - lastChange >= 60 else { return nil }
    if level == .balanced && pressure >= 4 {
      level = .responsive
      lastChange = now
      pressure = 0
      healthy = 0
      return level
    }
    if level == .responsive && healthy >= 45 {
      level = .balanced
      lastChange = now
      pressure = 0
      healthy = 0
      return level
    }
    return nil
  }
}
