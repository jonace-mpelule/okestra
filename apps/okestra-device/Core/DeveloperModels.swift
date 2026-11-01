import Foundation

public enum AndroidTooling {
  public static func shell(_ arguments: [String]) -> String {
    arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(
      separator: " ")
  }
  public static func package(_ value: String) throws -> String {
    guard
      value.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$"#, options: .regularExpression)
        != nil,
      value.utf8.count <= 255
    else { throw DeviceError.message("Enter a valid Android package name.") }
    return value
  }
  public static func link(_ value: String) throws -> String {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.utf8.count <= 8192,
      !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      let url = URLComponents(string: text), let scheme = url.scheme, !scheme.isEmpty
    else {
      throw DeviceError.message(
        "Enter a complete link, such as urbanman://bookings or https://example.com.")
    }
    return text
  }
  public static func port(_ value: String) throws -> Int {
    guard let port = Int(value), (1...65535).contains(port) else {
      throw DeviceError.message("Ports must be numbers from 1 to 65535.")
    }
    return port
  }
  public static func packages(_ output: String) -> [String] {
    Array(
      Set(
        output.split(separator: "\n").compactMap { line -> String? in
          guard line.hasPrefix("package:") else { return nil }
          return try? package(
            String(line.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines))
        })
    ).sorted()
  }
  public static func checkResult(_ output: String) throws {
    let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    if lines.contains(where: {
      $0.hasPrefix("Error:") || $0.hasPrefix("Failure [") || $0.hasPrefix("Exception occurred")
        || $0.hasPrefix("Security exception:")
    }) {
      throw DeviceError.message(output)
    }
  }
}

public struct SavedDeviceLink: Codable, Identifiable, Equatable, Sendable {
  public var id = UUID()
  public var name: String
  public var url: String
  public var package: String
  public init(name: String, url: String, package: String = "") throws {
    self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
    guard !self.name.isEmpty else { throw DeviceError.message("Give the link a name.") }
    self.url = try AndroidTooling.link(url)
    self.package = package.isEmpty ? "" : try AndroidTooling.package(package)
  }
}
public struct SavedDevicePort: Codable, Identifiable, Equatable, Sendable {
  public var id = UUID()
  public var name: String
  public var devicePort: Int
  public var macPort: Int
  public init(name: String, devicePort: String, macPort: String) throws {
    self.devicePort = try AndroidTooling.port(devicePort)
    self.macPort = try AndroidTooling.port(macPort)
    self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
    if self.name.isEmpty { self.name = "Port \(self.devicePort)" }
  }
}
public struct DeviceDeveloperPresets: Codable, Equatable, Sendable {
  public var links: [SavedDeviceLink] = []
  public var ports: [SavedDevicePort] = []
  public var selectedPackage = ""
  public init() {}
}
public struct DeveloperPresetStore: Codable, Sendable {
  public var devices: [String: DeviceDeveloperPresets] = [:]
  public init() {}
  public static func load(from url: URL) throws -> Self {
    guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
    let bytes = try Data(contentsOf: url)
    guard bytes.count < 2 * 1024 * 1024 else {
      throw DeviceError.message("Saved developer settings are too large.")
    }
    return try JSONDecoder().decode(Self.self, from: bytes)
  }
  public func save(to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(self).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

public struct DeviceLogEntry: Identifiable, Sendable {
  public let id = UUID()
  public let text: String
  public let pid: Int?
  public let level: String
  public init(_ text: String) {
    self.text = String(text.prefix(16_384))
    // logcat -v threadtime: MM-DD HH:mm:ss.SSS PID TID LEVEL TAG: MESSAGE
    let fields = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
    if fields.count >= 6, fields[0].count == 5, let pid = Int(fields[2]),
      fields[4].count == 1, "VDIWEF".contains(fields[4])
    {
      self.pid = pid
      self.level = String(fields[4])
    } else {
      pid = nil
      level = "I"
    }
  }
  public func matches(package: String, pids: Set<Int>, query: String, minimum: String) -> Bool {
    let ranks = ["V": 0, "D": 1, "I": 2, "W": 3, "E": 4, "F": 5]
    guard (ranks[level] ?? 2) >= (ranks[minimum] ?? 0) else { return false }
    if !package.isEmpty && !(pid.map { pids.contains($0) } ?? false) && !text.contains(package) {
      return false
    }
    return query.isEmpty || text.localizedCaseInsensitiveContains(query)
  }
  public var isCrash: Bool {
    text.contains("FATAL EXCEPTION:") || text.contains("ANR in ") || text.contains("Fatal signal ")
      || (text.contains("AndroidRuntime") && text.contains("Process: "))
  }
}

// Bound both the row count and byte count, even if an app emits very long log lines.
public struct DeviceLogBuffer: Sendable {
  public private(set) var entries: [DeviceLogEntry] = []
  private var bytes = 0
  public init() {}
  public mutating func append(_ lines: [String]) -> [DeviceLogEntry] {
    let incoming = lines.map(DeviceLogEntry.init)
    entries.append(contentsOf: incoming)
    bytes += incoming.reduce(0) { $0 + $1.text.utf8.count }
    var removed = 0
    while entries.count - removed > 5000 || bytes > 2 * 1024 * 1024 {
      bytes -= entries[removed].text.utf8.count
      removed += 1
    }
    if removed > 0 { entries.removeFirst(removed) }
    return incoming.filter(\.isCrash)
  }
  public mutating func clear() {
    entries = []
    bytes = 0
  }
}

public enum DeviceAudioPCM {
  public static let sampleRate = 48_000.0
  public static let channels = 2
  public static func frameCount(_ data: Data) throws -> Int {
    guard !data.isEmpty, data.count % 4 == 0, data.count <= 256 * 1024 else {
      throw DeviceError.message("Invalid Android audio frame.")
    }
    return data.count / 4
  }
}

// Coalesce high-volume logcat output into a single pending main-thread update.
// A stalled UI must not accumulate an unbounded queue of log callbacks.
public final class DeviceLogMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [String] = []
  private var scheduled = false
  private var dropped = 0
  public init() {}
  public func offer(_ lines: [String]) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let bounded = lines.suffix(512).map { String($0.prefix(4096)) }
    dropped += max(0, lines.count - bounded.count)
    pending.append(contentsOf: bounded)
    if pending.count > 512 {
      dropped += pending.count - 512
      pending.removeFirst(pending.count - 512)
    }
    if scheduled { return false }
    scheduled = true
    return true
  }
  public func take() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    let lines =
      (dropped > 0 ? ["[Okestra] Skipped \(dropped) log lines to keep the viewer responsive."] : [])
      + pending
    pending = []
    dropped = 0
    scheduled = false
    return lines
  }
}
