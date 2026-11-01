import Foundation
import XCTest

@testable import DeviceCore

final class ConvenienceTests: XCTestCase {
  func testPhysicalPhoneChargingAndScaledLevel() {
    let reading = DeviceBatteryReading.parse(
      """
      Current Battery Service state:
        AC powered: false
        USB powered: true
        Wireless powered: false
        status: 2
        present: true
        level: 128
        scale: 200
      """)
    XCTAssertEqual(reading, DeviceBatteryReading(percent: 64, charging: true, pluggedIn: true))
  }
  func testEmptyBatteryIsValidAndFullPluggedBatteryIsNotCharging() {
    XCTAssertEqual(DeviceBatteryReading.parse("level: 0\nscale: 100\nstatus: 3")?.percent, 0)
    let full = DeviceBatteryReading.parse("level: 100\nscale: 100\nstatus: 5\nAC powered: true")
    XCTAssertEqual(full?.percent, 100)
    XCTAssertEqual(full?.charging, false)
    XCTAssertEqual(full?.pluggedIn, true)
  }
  func testUnavailableAndMalformedBatteryNeverBecomeZeroPercent() {
    for value in [
      "permission denied", "level: 4", "level: -1\nscale: 100",
      "level: 10\nscale: 0", "level: nan\nscale: 100",
      "level: 10\nscale: 100\npresent: false",
    ] {
      XCTAssertNil(DeviceBatteryReading.parse(value), value)
    }
  }
  func testCapturesAreDurableUniqueFilesEvenAtSameTimestamp() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let png = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
    )!
    let now = Date(timeIntervalSince1970: 1_000)
    let first = try DeviceScreenshotStore.save(png, in: folder, now: now)
    let second = try DeviceScreenshotStore.save(png, in: folder, now: now)
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(try Data(contentsOf: first), png)
    XCTAssertEqual(try Data(contentsOf: second), png)
    XCTAssertEqual(first.pathExtension, "png")
    XCTAssertThrowsError(try DeviceScreenshotStore.save(Data("not a screenshot".utf8), in: folder))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
  }
}
