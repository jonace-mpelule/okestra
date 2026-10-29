// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "OkestraDeviceCore", platforms: [.macOS(.v13)],
  products: [.library(name: "DeviceCore", targets: ["DeviceCore"])],
  targets: [
    .target(name: "DeviceCore", path: "Core"),
    .target(
      name: "DeviceTransport", dependencies: ["DeviceCore"], path: ".",
      exclude: ["Core", "Tests", "OkestraDevice.swift", "Info.plist"], sources: ["Transport.swift"]),
    .testTarget(
      name: "DeviceCoreTests", dependencies: ["DeviceCore", "DeviceTransport"], path: "Tests"),
  ])
