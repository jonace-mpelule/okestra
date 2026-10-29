import AVFoundation
import VideoToolbox
import XCTest

@testable import DeviceCore

final class ProtocolTests: XCTestCase {
  func testFrameBoundsAndFlags() throws {
    var header = Data()
    header.appendBE(1 << 63, bytes: 8)
    header.appendBE(100, bytes: 4)
    let packet = try VideoPacket(header: header)
    XCTAssertTrue(packet.config)
    XCTAssertEqual(packet.length, 100)
    XCTAssertThrowsError(try VideoPacket(header: Data(repeating: 0, count: 12)))
    XCTAssertThrowsError(try VideoPacket(header: Data(repeating: 255, count: 12)))
    XCTAssertThrowsError(try VideoPacket(header: Data([0])))
  }
  func testAnnexBConversion() throws {
    let units = try H264.units(Data([0, 0, 0, 1, 0x67, 12, 0, 0, 1, 0x68, 34]))
    XCTAssertEqual(units, [Data([0x67, 12]), Data([0x68, 34])])
    XCTAssertEqual(H264.avcc(units), Data([0, 0, 0, 2, 0x67, 12, 0, 0, 0, 2, 0x68, 34]))
    XCTAssertThrowsError(try H264.units(Data([0, 0, 1])))
    XCTAssertThrowsError(try H264.units(Data([5, 6, 7])))
  }
  func testTouchCoordinatesAndNavigation() throws {
    let touch = ControlPacket.touch(action: 0, x: -20, y: 9999, width: 720, height: 1280)
    XCTAssertEqual(touch.count, 32)
    XCTAssertEqual(try touch.unsigned(at: 10, bytes: 4), 0)
    XCTAssertEqual(try touch.unsigned(at: 14, bytes: 4), 1279)
    XCTAssertEqual(try touch.unsigned(at: 18, bytes: 2), 720)
    XCTAssertEqual(
      ControlPacket.key(3, down: true), Data([0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0]))
  }
  func testUTF8LimitsDoNotSplitCharacters() throws {
    let p = ControlPacket.text(String(repeating: "🙂", count: 200))
    XCTAssertEqual(p.count, 305)
    XCTAssertNotNil(String(data: p.dropFirst(5), encoding: .utf8))
    let paste = ControlPacket.paste("Hello")
    XCTAssertEqual(paste.count, 19)
    XCTAssertEqual(paste[9], 1)
  }
  func testLetterboxing() {
    let r = ScreenGeometry.fitted(
      containerWidth: 1000, containerHeight: 500, videoWidth: 400, videoHeight: 800)
    XCTAssertEqual(r.0, 375)
    XCTAssertEqual(r.1, 0)
    XCTAssertEqual(r.2, 250)
    XCTAssertEqual(r.3, 500)
  }
}

final class DecoderTests: XCTestCase {
  func testRealH264FrameDecodes() throws {
    let fixture = Data(
      base64Encoded:
        "AAAAAWdCwArZHsBEAAADAAQAAAMACDxImSAAAAABaMuDyyAAAAEGBf//bNxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0wIHJlZj0zIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDE6MHgxMTEgbWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTI1MCBrZXlpbnRfbWluPTEgc2NlbmVjdXQ9NDAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD00MCByYz1jcmYgbWJ0cmVlPTEgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAAFliIQFfEYoAAuMxwABOhjgADYNgA=="
    )!
    let units = try H264.units(fixture)
    let config = units.filter { [7, 8].contains(Int($0.first! & 31)) }
    let picture = units.filter { ![7, 8].contains(Int($0.first! & 31)) }
    func annex(_ units: [Data]) -> Data {
      var b = Data()
      for unit in units {
        b.append(contentsOf: [0, 0, 0, 1])
        b.append(unit)
      }
      return b
    }
    let decoder = VideoDecoder()
    XCTAssertNil(try decoder.consume(annex(config), config: true, keyframe: false))
    let sample = try XCTUnwrap(decoder.consume(annex(picture), config: false, keyframe: true))
    let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
    XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(format).width, 16)
    var session: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
      imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
    XCTAssertEqual(status, noErr)
    let live = try XCTUnwrap(session)
    defer { VTDecompressionSessionInvalidate(live) }
    let done = expectation(description: "decoded frame")
    let decode = VTDecompressionSessionDecodeFrame(
      live, sampleBuffer: sample, flags: [], infoFlagsOut: nil
    ) { status, _, image, _, _ in
      XCTAssertEqual(status, noErr)
      XCTAssertNotNil(image)
      if let image {
        XCTAssertEqual(CVPixelBufferGetWidth(image), 16)
        XCTAssertEqual(CVPixelBufferGetHeight(image), 16)
      }
      done.fulfill()
    }
    XCTAssertEqual(decode, noErr)
    VTDecompressionSessionWaitForAsynchronousFrames(live)
    wait(for: [done], timeout: 3)
  }
  func testFrameBeforeConfigurationFails() {
    XCTAssertThrowsError(
      try VideoDecoder().consume(Data([0, 0, 1, 0x65, 1, 2]), config: false, keyframe: true))
  }
}
