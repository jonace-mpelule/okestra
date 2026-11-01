import XCTest

@testable import DeviceCore

final class StreamPerformanceTests: XCTestCase {
  func testMailboxCoalescesWithoutSchedulingUnboundedUIWork() {
    let mailbox = LatestFrameMailbox<Int>()
    XCTAssertTrue(mailbox.offer(1).schedule)
    for n in 2...1000 {
      let offered = mailbox.offer(n)
      XCTAssertFalse(offered.schedule)
      XCTAssertTrue(offered.replaced)
    }
    XCTAssertEqual(mailbox.take(), 1000)
    XCTAssertNil(mailbox.take())
    XCTAssertTrue(mailbox.offer(1001).schedule)
    mailbox.close()
    XCTAssertNil(mailbox.take())
    XCTAssertFalse(mailbox.offer(1002).schedule)
  }
  func testConcurrentProducerMailboxRetainsOnlyLatestUntilDrain() {
    let mailbox = LatestFrameMailbox<Int>()
    XCTAssertTrue(mailbox.offer(-1).schedule)
    DispatchQueue.concurrentPerform(iterations: 1000) { index in
      XCTAssertFalse(mailbox.offer(index).schedule)
    }
    XCTAssertFalse(mailbox.offer(2000).schedule)
    XCTAssertEqual(mailbox.take(), 2000)
    XCTAssertTrue(mailbox.offer(2001).schedule)
  }
  func testCaptureTimestampFlagsAreNotMistakenForTime() throws {
    var data = Data()
    data.appendBE((1 << 62) | 1_234_567, bytes: 8)
    data.appendBE(20, bytes: 4)
    let packet = try VideoPacket(header: data)
    XCTAssertTrue(packet.keyframe)
    XCTAssertEqual(packet.timestampMicroseconds, 1_234_567)
  }
  func testBacklogUsesRelativeClockOffsetAndHandlesRestart() {
    var estimator = StreamBacklogEstimator()
    XCTAssertEqual(estimator.observe(microseconds: 1_000_000, arrival: 500), 0)
    XCTAssertEqual(estimator.observe(microseconds: 2_000_000, arrival: 501.1), 100, accuracy: 0.001)
    XCTAssertEqual(estimator.observe(microseconds: 3_000_000, arrival: 502), 0, accuracy: 0.001)
    XCTAssertEqual(estimator.observe(microseconds: 1, arrival: 503), 0)
  }
  func testAdaptiveModeIgnoresIdleAndRequiresSustainedPressure() {
    var policy = AdaptiveStreamPolicy()
    var pressure = StreamMeasurement()
    pressure.backlogMS = 200
    for n in 0..<100 { XCTAssertNil(policy.evaluate(pressure, now: Double(n))) }
    pressure.received = 30
    for n in 0..<3 { XCTAssertNil(policy.evaluate(pressure, now: Double(n) + 100)) }
    XCTAssertEqual(policy.evaluate(pressure, now: 103), .responsive)
    var healthy = StreamMeasurement()
    healthy.received = 30
    healthy.decodeMS = 2
    for n in 104..<163 { XCTAssertNil(policy.evaluate(healthy, now: Double(n))) }
    XCTAssertEqual(policy.evaluate(healthy, now: 163), .balanced)
    for n in 164..<170 { XCTAssertNil(policy.evaluate(pressure, now: Double(n))) }
  }
  func testSnapshotResetsMeasurementWindow() {
    let metrics = StreamMeasurements()
    metrics.received(bytes: 500, decodeMS: 2, backlogMS: 12, hardware: true)
    metrics.received(bytes: 700, decodeMS: 4, backlogMS: 8, hardware: true)
    metrics.replaced()
    metrics.delivered(waitMS: 5)
    let sample = metrics.snapshot()
    XCTAssertEqual(sample.bytes, 1200)
    XCTAssertEqual(sample.received, 2)
    XCTAssertEqual(sample.decodeMS, 3)
    XCTAssertEqual(sample.backlogMS, 12)
    XCTAssertEqual(sample.delivered, 1)
    XCTAssertEqual(sample.replaced, 1)
    XCTAssertEqual(sample.hardwareDecoder, true)
    XCTAssertEqual(metrics.snapshot().bytes, 0)
  }
  func testProfilesSpecifyCaptureCapsWithoutChangingGuestResolution() {
    XCTAssertEqual(StreamMode.responsive.configuration.maxSize, 1024)
    XCTAssertEqual(StreamMode.balanced.configuration.maxFPS, 30)
    XCTAssertEqual(StreamMode.smooth.configuration.maxFPS, 60)
    XCTAssertEqual(
      StreamMode.smooth.configuration.serverArguments,
      ["max_size=1280", "max_fps=60", "video_bit_rate=6000000"])
  }
  func testNativePreservesResolutionAndDisablesEncoderDownsizeFallback() {
    let configuration = StreamMode.native.configuration
    XCTAssertEqual(configuration.maxSize, 0)
    XCTAssertEqual(configuration.maxFPS, 0)
    XCTAssertEqual(configuration.summary, "Full resolution · Uncapped fps")
    XCTAssertEqual(
      configuration.serverArguments,
      [
        "max_size=0", "max_fps=0", "video_bit_rate=40000000", "downsize_on_error=false",
      ])
    XCTAssertEqual(StreamMode(rawValue: "native"), .native)
    XCTAssertTrue(StreamMode.allCases.contains(.native))
    XCTAssertFalse(
      StreamMode.smooth.configuration.serverArguments.contains("downsize_on_error=false"))
  }
}
