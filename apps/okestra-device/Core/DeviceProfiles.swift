import Foundation

public struct RemoteDeviceProfile: Codable, Identifiable, Sendable, Equatable {
  public var id: String
  public var name: String
  public var avd: String
  public var hardware: String
  public var cores: Int
  public var memory_mb: Int
  public var width: Int
  public var height: Int
}
public struct RemoteDeviceStatus: Decodable, Sendable {
  public let enabled: Bool
  public let device: String
  public let profiles: [RemoteDeviceProfile]?
  public let active_profile: String?
  public let active_avd: String?
  public let local_serial: String?
  public let checks: [String: String]?
}
public struct PairedDeviceServers: Decodable, Sendable {
  public let names: [String]
  public let active: String
}
