import Foundation

struct DeviceBatteryReading: Equatable, Sendable {
  let percent: Int
  let charging: Bool
  let pluggedIn: Bool

  static func parse(_ text: String) -> Self? {
    var fields: [String: String] = [:]
    for line in text.split(separator: "\n") {
      let pair = line.split(separator: ":", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      if pair.count == 2 { fields[pair[0]] = pair[1] }
    }
    guard let level = fields["level"].flatMap(Double.init),
      let scale = fields["scale"].flatMap(Double.init),
      level.isFinite, scale.isFinite, scale > 0, level >= 0,
      fields["present"] != "false"
    else { return nil }
    return Self(
      percent: Int((min(1, level / scale) * 100).rounded()),
      charging: fields["status"] == "2",
      pluggedIn: ["AC powered", "USB powered", "Wireless powered", "Dock powered"].contains {
        fields[$0] == "true"
      })
  }
}

enum DeviceScreenshotStore {
  static func save(
    _ png: Data, in directory: URL, now: Date = Date(), namePrefix: String = "Okestra"
  ) throws -> URL {
    guard png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    // A unique suffix also prevents simultaneous captures from overwriting each other.
    let name = "\(namePrefix) \(formatter.string(from: now)) \(UUID().uuidString.prefix(8)).png"
    let file = directory.appendingPathComponent(name)
    try png.write(to: file, options: .atomic)
    return file
  }
}
