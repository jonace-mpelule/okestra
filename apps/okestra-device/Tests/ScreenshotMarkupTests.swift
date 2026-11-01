import AppKit
import XCTest

@testable import DeviceCore

final class ScreenshotMarkupTests: XCTestCase {
  private func sourcePNG() throws -> Data {
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 200,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<200 {
      for x in 0..<120 {
        let pixel = bitmap.bitmapData!.advanced(by: y * bitmap.bytesPerRow + x * 4)
        pixel[0] = y < 100 ? 255 : 0
        pixel[1] = 0
        pixel[2] = y < 100 ? 0 : 255
        pixel[3] = 255
      }
    }
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
  }
  private func color(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
    try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
  }
  func testExportPreservesNativePixelsAndOrientation() throws {
    let image = try ScreenshotMarkupRenderer.source(sourcePNG())
    let png = try ScreenshotMarkupRenderer.png(image: image, marks: [])
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
    XCTAssertEqual(bitmap.pixelsWide, 120)
    XCTAssertEqual(bitmap.pixelsHigh, 200)
    XCTAssertGreaterThan(try color(bitmap, x: 10, y: 10).redComponent, 0.95)
    XCTAssertLessThan(try color(bitmap, x: 10, y: 10).blueComponent, 0.05)
    XCTAssertGreaterThan(try color(bitmap, x: 10, y: 190).blueComponent, 0.95)
  }
  func testRedactionReplacesPixelsAndStaysOpaqueAboveOtherMarks() throws {
    let image = try ScreenshotMarkupRenderer.source(sourcePNG())
    let redaction = ScreenshotMarkup(
      tool: .redact, color: .coral,
      points: [CGPoint(x: 0.2, y: 0.1), CGPoint(x: 0.6, y: 0.4)])
    let stroke = ScreenshotMarkup(
      tool: .pen, color: .white,
      points: [CGPoint(x: 0.1, y: 0.25), CGPoint(x: 0.8, y: 0.25)])
    let output = try ScreenshotMarkupRenderer.png(image: image, marks: [redaction, stroke])
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: output))
    let covered = try color(bitmap, x: 40, y: 50)
    XCTAssertLessThan(covered.redComponent, 0.01)
    XCTAssertLessThan(covered.greenComponent, 0.01)
    XCTAssertLessThan(covered.blueComponent, 0.01)
    XCTAssertEqual(covered.alphaComponent, 1, accuracy: 0.001)
    XCTAssertGreaterThan(try color(bitmap, x: 10, y: 10).redComponent, 0.95)
    XCTAssertGreaterThan(try color(bitmap, x: 40, y: 150).blueComponent, 0.95)
    // Redaction never changes the original image or its export.
    let original = try XCTUnwrap(
      NSBitmapImageRep(data: ScreenshotMarkupRenderer.png(image: image, marks: [])))
    XCTAssertGreaterThan(try color(original, x: 40, y: 50).redComponent, 0.95)
  }
  func testReverseDirectionRedactionCoversTheSameArea() throws {
    let image = try ScreenshotMarkupRenderer.source(sourcePNG())
    let mark = ScreenshotMarkup(
      tool: .redact, color: .blue,
      points: [CGPoint(x: 0.6, y: 0.4), CGPoint(x: 0.2, y: 0.1)])
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(data: ScreenshotMarkupRenderer.png(image: image, marks: [mark])))
    XCTAssertLessThan(try color(bitmap, x: 40, y: 50).redComponent, 0.01)
    XCTAssertGreaterThan(try color(bitmap, x: 100, y: 50).redComponent, 0.95)
  }
  func testLetterboxingAndPointerCoordinatesSurviveWindowResize() {
    let rect = ScreenshotMarkupRenderer.imageRect(
      image: CGSize(width: 100, height: 200),
      bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
    XCTAssertEqual(rect, CGRect(x: 250, y: 0, width: 300, height: 600))
    XCTAssertEqual(
      ScreenshotMarkupRenderer.normalized(CGPoint(x: 400, y: 300), in: rect),
      CGPoint(x: 0.5, y: 0.5))
    XCTAssertEqual(ScreenshotMarkupRenderer.normalized(CGPoint(x: 0, y: -40), in: rect), .zero)
    XCTAssertEqual(
      ScreenshotMarkupRenderer.normalized(CGPoint(x: 900, y: 900), in: rect), CGPoint(x: 1, y: 1))
    let small = ScreenshotMarkupRenderer.imageRect(
      image: CGSize(width: 100, height: 200),
      bounds: CGRect(x: 20, y: 20, width: 200, height: 400))
    XCTAssertEqual(
      ScreenshotMarkupRenderer.normalized(CGPoint(x: small.midX, y: small.midY), in: small),
      CGPoint(x: 0.5, y: 0.5))
  }

  func testHitTestingFollowsRedactionOrderAndAvoidsEmptySpaceBetweenPenPoints() {
    let rect = CGRect(x: 20, y: 20, width: 400, height: 800)
    let line = ScreenshotMarkup(
      tool: .pen, color: .coral,
      points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)])
    let cover = ScreenshotMarkup(
      tool: .redact, color: .coral,
      points: [CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.6)])
    XCTAssertEqual(
      ScreenshotMarkupRenderer.hitTest(
        CGPoint(x: 220, y: 420), marks: [cover, line], imageRect: rect), cover.id)
    XCTAssertNil(
      ScreenshotMarkupRenderer.hitTest(CGPoint(x: 70, y: 700), marks: [line], imageRect: rect))
    XCTAssertEqual(
      ScreenshotMarkupRenderer.hitTest(CGPoint(x: 100, y: 180), marks: [line], imageRect: rect),
      line.id)
  }

  func testMovingAnnotationPreservesItsShapeAndClampsToImageEdges() {
    let mark = ScreenshotMarkup(
      tool: .box, color: .blue,
      points: [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.6, y: 0.8)])
    let moved = ScreenshotMarkupRenderer.translated(mark, by: CGPoint(x: 0.9, y: -0.9))
    XCTAssertEqual(moved.id, mark.id)
    XCTAssertEqual(moved.points[0].x, 0.6, accuracy: 0.0001)
    XCTAssertEqual(moved.points[1].x, 1, accuracy: 0.0001)
    XCTAssertEqual(moved.points[0].y, 0, accuracy: 0.0001)
    XCTAssertEqual(moved.points[1].y, 0.5, accuracy: 0.0001)
  }

  func testAnnotationStyleChangesExportWithoutChangingNativeDimensions() throws {
    let image = try ScreenshotMarkupRenderer.source(sourcePNG())
    var line = ScreenshotMarkup(
      tool: .pen, color: .white,
      points: [CGPoint(x: 0.1, y: 0.25), CGPoint(x: 0.9, y: 0.25)])
    line.stroke = .fine
    let fine = try ScreenshotMarkupRenderer.png(image: image, marks: [line])
    line.stroke = .bold
    let bold = try ScreenshotMarkupRenderer.png(image: image, marks: [line])
    XCTAssertNotEqual(fine, bold)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: bold))
    XCTAssertEqual(bitmap.pixelsWide, 120)
    XCTAssertEqual(bitmap.pixelsHigh, 200)
  }
}
