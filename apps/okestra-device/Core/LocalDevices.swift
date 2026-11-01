import Foundation

public enum DeviceSource: String, CaseIterable, Sendable {
  case server, local
  public var title: String { self == .server ? "Server" : "This Mac" }
}

public struct LocalAndroidDevice: Identifiable, Equatable, Sendable {
  public let id: String
  public let state: String
  public let model: String
  public var ready: Bool { state == "device" }
  public var wireless: Bool { id.contains(":") || id.contains("._adb-tls-connect._tcp") }
  public var title: String { model.isEmpty ? id : model.replacingOccurrences(of: "_", with: " ") }
  public var status: String {
    switch state {
    case "device": return wireless ? "Wi-Fi" : "USB"
    case "unauthorized": return "Unlock phone and allow USB debugging"
    case "offline": return "Offline · reconnect device"
    default: return state
    }
  }
  public static func parse(_ output: String) -> [LocalAndroidDevice] {
    output.components(separatedBy: .newlines).compactMap { line in
      let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard fields.count >= 2,
        ["device", "unauthorized", "offline", "recovery", "sideload", "no"].contains(fields[1]),
        !fields[0].hasPrefix("emulator-"), !fields[0].hasPrefix("127."),
        !fields[0].hasPrefix("localhost:"), !fields[0].hasPrefix("[::1]:")
      else { return nil }
      let model =
        fields.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)) } ?? ""
      return LocalAndroidDevice(id: fields[0], state: fields[1], model: model)
    }
  }
}

public enum WirelessDeviceAddress {
  // Require an explicit port: Android uses different pairing and connection ports.
  public static func validate(_ input: String) throws -> String {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !value.hasPrefix("-"),
      value.unicodeScalars.allSatisfy({
        CharacterSet(
          charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]%"
        ).contains($0)
      }),
      let split = value.lastIndex(of: ":"), let port = UInt16(value[value.index(after: split)...]),
      port > 0
    else {
      throw DeviceError.message(
        "Enter the phone’s address and port, for example 192.168.1.20:37123.")
    }
    let host = String(value[..<split])
    guard !host.isEmpty,
      (host.hasPrefix("[") && host.hasSuffix("]") && host.count > 4)
        || (!host.contains(":") && !host.contains("[") && !host.contains("]"))
    else { throw DeviceError.message("Use host:port, or [IPv6 address]:port.") }
    return value
  }
  public static func validateCode(_ input: String) throws -> String {
    let code = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard code.utf8.count == 6, code.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
      throw DeviceError.message("Enter the six-digit pairing code shown on your phone.")
    }
    return code
  }
}
