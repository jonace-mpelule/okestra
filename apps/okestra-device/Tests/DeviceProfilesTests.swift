import Foundation
import XCTest

@testable import DeviceCore

final class DeviceProfilesTests: XCTestCase {
  func testServerProfileContractAndOptionalCompatibilityFields() throws {
    let data = Data(
      #"{"enabled":true,"device":"ready","active_profile":"p7","profiles":[{"id":"p7","name":"Daily Pixel","avd":"okestra-pixel_7-test","hardware":"pixel_7","cores":4,"memory_mb":3072,"width":1080,"height":2400}]}"#
        .utf8)
    let status = try JSONDecoder().decode(RemoteDeviceStatus.self, from: data)
    let profile = try XCTUnwrap(status.profiles?.first)
    XCTAssertEqual(profile.id, status.active_profile)
    XCTAssertEqual(profile.memory_mb, 3072)
    XCTAssertEqual(profile.width, 1080)
    let roundtrip = try JSONDecoder().decode(
      RemoteDeviceProfile.self, from: JSONEncoder().encode(profile))
    XCTAssertEqual(roundtrip, profile)
    let old = try JSONDecoder().decode(
      RemoteDeviceStatus.self, from: Data(#"{"enabled":true,"device":"stopped"}"#.utf8))
    XCTAssertNil(old.profiles)
    let disabled = try JSONDecoder().decode(
      RemoteDeviceStatus.self,
      from: Data(#"{"enabled":false,"device":"stopped","profiles":[]}"#.utf8))
    XCTAssertEqual(disabled.profiles?.count, 0)
  }
  func testProfilesUseDistinctSkinsWithoutStretchingTheDisplay() {
    let pixel7 = DeviceChassis.resolve(
      DeviceIdentity(model: "Pixel 7", width: 1080, height: 2400), videoWidth: 720,
      videoHeight: 1600)
    let pixel9 = DeviceChassis.resolve(
      DeviceIdentity(model: "Pixel 9", width: 1080, height: 2424), videoWidth: 720,
      videoHeight: 1616)
    let seven = pixel7.layout(
      videoWidth: 1080, videoHeight: 2400, availableWidth: 600, availableHeight: 900, framed: true)
    let nine = pixel9.layout(
      videoWidth: 1080, videoHeight: 2424, availableWidth: 600, availableHeight: 900, framed: true)
    XCTAssertEqual(seven.height / seven.width, 155.6 / 73.2, accuracy: 0.00001)
    XCTAssertEqual(seven.screenWidth / seven.screenHeight, 1080.0 / 2400, accuracy: 0.00001)
    XCTAssertEqual(nine.screenWidth / nine.screenHeight, 1080.0 / 2424, accuracy: 0.00001)
    XCTAssertNotEqual(seven.bodyRadius, nine.bodyRadius)
  }
}
