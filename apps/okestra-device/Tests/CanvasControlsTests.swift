import Foundation
import XCTest

@testable import DeviceCore

final class CanvasControlsTests: XCTestCase {
  func testFocusWindowFitsBesideEditorAndStaysOnTheCurrentScreen() {
    let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
    let anchor = CGRect(x: -1300, y: 50, width: 1100, height: 800)
    for framed in [true, false] {
      for (width, height) in [(1080.0, 2392.0), (2392.0, 1080.0)] {
        let device = DeviceChassis.pixel7Skin.layout(
          videoWidth: width, videoHeight: height,
          availableWidth: 1000, availableHeight: 1000, framed: framed)
        let frame = FocusWindowGeometry.frame(
          deviceSize: CGSize(width: device.width, height: device.height),
          screen: screen, anchor: anchor)
        XCTAssertTrue(screen.contains(frame))
        XCTAssertLessThanOrEqual(frame.width, width < height ? 340 : 640)
        XCTAssertLessThanOrEqual(frame.height, height > width ? 760 : 400)
        XCTAssertEqual(frame.maxX, anchor.maxX, accuracy: 0.001)
        let fitted = ScreenGeometry.fitted(
          containerWidth: frame.width,
          containerHeight: frame.height - FocusWindowGeometry.titlebarHeight,
          videoWidth: device.width, videoHeight: device.height)
        XCTAssertGreaterThanOrEqual(fitted.0, -0.001)
        XCTAssertGreaterThanOrEqual(fitted.1, -0.001)
        XCTAssertLessThanOrEqual(fitted.2, frame.width + 0.001)
        XCTAssertLessThanOrEqual(
          fitted.3, frame.height - FocusWindowGeometry.titlebarHeight + 0.001)
      }
    }
  }
  func testFocusWindowClampsAnOffscreenAnchor() {
    let screen = CGRect(x: 0, y: 25, width: 1280, height: 775)
    let frame = FocusWindowGeometry.frame(
      deviceSize: CGSize(width: 1080, height: 2392),
      screen: screen, anchor: CGRect(x: 2000, y: -1000, width: 1000, height: 800))
    XCTAssertTrue(screen.contains(frame))
    XCTAssertEqual(frame.maxX, screen.maxX - 16, accuracy: 0.001)
    XCTAssertEqual(frame.minY, screen.minY + 16, accuracy: 0.001)
  }
  func testRotationSnapshotLandsOnTargetBoundsWithAndWithoutFrame() {
    for framed in [true, false] {
      let portrait = DeviceChassis.pixel7Skin.layout(
        videoWidth: 1080, videoHeight: 2392,
        availableWidth: 700, availableHeight: 600, framed: framed)
      let landscape = DeviceChassis.pixel7Skin.layout(
        videoWidth: 2392, videoHeight: 1080,
        availableWidth: 700, availableHeight: 600, framed: framed)
      let scale = DeviceRotationGeometry.scale(from: portrait, to: landscape)
      XCTAssertEqual(portrait.height * scale, landscape.width, accuracy: 0.001)
      XCTAssertEqual(portrait.width * scale, landscape.height, accuracy: 0.001)
      XCTAssertEqual(DeviceRotationGeometry.angle(from: portrait), 90)
      XCTAssertEqual(DeviceRotationGeometry.angle(from: landscape), -90)
    }
  }
  func testActualSizeUsesVideoPixelsAndBackingScaleWithEitherFrameStyle() {
    for framed in [true, false] {
      for (width, height) in [(1080.0, 2392.0), (2392.0, 1080.0), (576.0, 1280.0)] {
        let fitted = DeviceChassis.pixel7Skin.layout(
          videoWidth: width, videoHeight: height, availableWidth: 400, availableHeight: 600,
          framed: framed)
        let backingScale = 2.0
        let fittedScale = fitted.screenWidth * backingScale / width
        var zoom = CanvasZoom()
        XCTAssertEqual(zoom.resolved(fittedScale: fittedScale), fittedScale)
        zoom.actualSize()
        let actual = fitted.scaled(by: zoom.resolved(fittedScale: fittedScale) / fittedScale)
        XCTAssertEqual(actual.screenWidth * backingScale, width, accuracy: 0.001)
        XCTAssertEqual(actual.screenHeight * backingScale, height, accuracy: 0.001)
        XCTAssertEqual(actual.screenWidth / actual.screenHeight, width / height, accuracy: 0.001)
        zoom.fit()
        XCTAssertNil(zoom.scale)
      }
    }
  }
  func testZoomStepsFromFitAndStaysBounded() {
    var zoom = CanvasZoom()
    zoom.step(inwards: true, fittedScale: 0.5)
    XCTAssertEqual(zoom.scale!, 0.55, accuracy: 0.001)
    zoom.step(inwards: false, fittedScale: 0.5)
    XCTAssertEqual(zoom.scale!, 0.5, accuracy: 0.001)
    zoom.fit()
    zoom.step(inwards: true, fittedScale: 0.91)
    XCTAssertEqual(zoom.scale!, 0.96, accuracy: 0.001)
    zoom.step(inwards: false, fittedScale: 0.91)
    XCTAssertEqual(zoom.scale!, 0.91, accuracy: 0.001)
    zoom.actualSize()
    zoom.step(inwards: false, fittedScale: 0.5)
    XCTAssertEqual(zoom.scale!, 0.95, accuracy: 0.001)
    for _ in 0..<100 { zoom.step(inwards: true, fittedScale: 0.5) }
    XCTAssertEqual(zoom.scale, 4)
    for _ in 0..<100 { zoom.step(inwards: false, fittedScale: 0.5) }
    XCTAssertEqual(zoom.scale, 0.1)
  }
}
