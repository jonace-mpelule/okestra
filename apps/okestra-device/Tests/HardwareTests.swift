import XCTest

@testable import DeviceCore

final class HardwareTests: XCTestCase {
  func testActiveDisplayOverrideIsUsed() {
    let identity = DeviceIdentity.parse(
      model: "sdk_gphone64_x86_64\n", avd: "okestra-pixel\n",
      size: "Physical size: 1080x1920\nOverride size: 1080x2424\n")
    XCTAssertEqual(identity.nativeWidth, 1080)
    XCTAssertEqual(identity.nativeHeight, 2424)
    let frame = DeviceChassis.resolve(identity, videoWidth: 568, videoHeight: 1280)
    XCTAssertNotEqual(frame.name, "Google Pixel")
    XCTAssertFalse(frame.classic)
  }
  func testPixelBodyMatchesPhysicalProportions() {
    let identity = DeviceIdentity(
      model: "sdk_gphone64_x86_64", avd: "okestra-pixel", width: 1080, height: 1920)
    let frame = DeviceChassis.resolve(identity, videoWidth: 720, videoHeight: 1280)
    XCTAssertEqual(frame.name, "Google Pixel")
    let layout = frame.layout(
      videoWidth: 720, videoHeight: 1280, availableWidth: 600, availableHeight: 800, framed: true)
    XCTAssertEqual(layout.height / layout.width, 143.84 / 69.54, accuracy: 0.001)
    XCTAssertEqual(layout.screenWidth / layout.screenHeight, 720.0 / 1280, accuracy: 0.000001)
    XCTAssertLessThanOrEqual(layout.height, 800)
  }
  func testResizingRotationAndFramelessPreserveTheGuestDisplay() {
    let identity = DeviceIdentity(model: "Pixel 9", width: 1080, height: 2424)
    let frame = DeviceChassis.resolve(identity, videoWidth: 568, videoHeight: 1280)
    for (w, h) in [(568.0, 1280.0), (1280.0, 568.0)] {
      for framed in [true, false] {
        for (cw, ch) in [(300.0, 700.0), (900.0, 300.0)] {
          let layout = frame.layout(
            videoWidth: w, videoHeight: h, availableWidth: cw, availableHeight: ch, framed: framed)
          XCTAssertEqual(layout.screenWidth / layout.screenHeight, w / h, accuracy: 0.000001)
          XCTAssertLessThanOrEqual(layout.width, cw + 0.000001)
          XCTAssertLessThanOrEqual(layout.height, ch + 0.000001)
          if !framed {
            XCTAssertEqual(layout.insetX, 0)
            XCTAssertEqual(layout.insetY, 0)
          }
        }
      }
    }
  }
  func testInvalidMetadataHasSafeFallback() {
    let identity = DeviceIdentity.parse(model: "Android", avd: "", size: "permission denied")
    XCTAssertEqual(identity.nativeWidth, 0)
    let frame = DeviceChassis.resolve(identity, videoWidth: 720, videoHeight: 1280)
    XCTAssertEqual(frame.name, "Android")
    let layout = frame.layout(
      videoWidth: 720, videoHeight: 1280, availableWidth: 0, availableHeight: 0, framed: true)
    XCTAssertTrue(layout.width.isFinite)
    XCTAssertGreaterThan(layout.screenWidth, 0)
  }
}
