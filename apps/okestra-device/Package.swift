// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "OkestraDeviceCore", platforms: [.macOS(.v13)],
  products: [.library(name: "DeviceCore", targets: ["DeviceCore"])],
  targets: [
    .target(name: "DeviceCore", path: "Core"),
    .target(
      name: "DeviceTransport", dependencies: ["DeviceCore"], path: ".",
      exclude: [
        "Archive", "Core", "Tests", "EditorTests", "Android", "Resources", "DeviceNetwork.swift",
        "DeviceConvenience.swift", "ScreenshotEditor.swift", "ScreenshotEditorModel.swift",
        "WorkspaceCanvas.swift", "VideoReviewModel.swift", "VideoReviewWorkspace.swift",
        "OkestraDevice.swift",
        "DeviceWorkspace.swift",
        "DeveloperTools.swift", "DeveloperWorkspace.swift", "Info.plist",
      ], sources: ["Transport.swift", "DeveloperTransport.swift", "DeviceNetworkTransport.swift"]),
    .testTarget(
      name: "DeviceCoreTests", dependencies: ["DeviceCore", "DeviceTransport"], path: "Tests"),
  ])
