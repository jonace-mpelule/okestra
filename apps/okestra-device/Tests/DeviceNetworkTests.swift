import Foundation
import XCTest

@testable import DeviceCore
@testable import DeviceTransport

final class DeviceNetworkTests: XCTestCase {
  func testProtocolRejectsUnsupportedMalformedAndNegativeCounters() throws {
    let valid = try DeviceNetworkSnapshot(
      data: Data(
        #"{"version":1,"elapsed_ms":1000,"received_bytes":2000,"transmitted_bytes":3000}"#.utf8))
    XCTAssertEqual(valid.receivedBytes, 2000)
    XCTAssertEqual(valid.transmittedBytes, 3000)
    for text in [
      #"{"version":2,"elapsed_ms":1000,"received_bytes":2000,"transmitted_bytes":3000}"#,
      #"{"version":1,"elapsed_ms":1000,"received_bytes":-1,"transmitted_bytes":3000}"#,
      #"{"version":1,"elapsed_ms":1000,"received_bytes":2000}"#,
      #"{"version":1,"error":"Network counters unavailable"}"#,
      "not json",
    ] { XCTAssertThrowsError(try DeviceNetworkSnapshot(data: Data(text.utf8))) }
  }
  func testRatesUseBothDirectionsAndActualElapsedTime() throws {
    var estimator = DeviceNetworkEstimator()
    XCTAssertNil(estimator.observe(snapshot(1000, rx: 1_000_000, tx: 2_000_000)))
    let value = try XCTUnwrap(estimator.observe(snapshot(2500, rx: 4_000_000, tx: 2_750_000)))
    XCTAssertEqual(value.downloadMbps, 16, accuracy: 0.0001)
    XCTAssertEqual(value.uploadMbps, 4, accuracy: 0.0001)
    XCTAssertEqual(
      estimator.observe(snapshot(3500, rx: 4_000_000, tx: 2_750_000)),
      DeviceNetworkRate(uploadMbps: 0, downloadMbps: 0))
  }
  func testCounterResetClockResetAndStaleSamplesSeedNewBaselines() throws {
    var estimator = DeviceNetworkEstimator()
    _ = estimator.observe(snapshot(1000, rx: 1_000_000, tx: 2_000_000))
    XCTAssertNil(estimator.observe(snapshot(2000, rx: 10, tx: 20)))
    let afterReset = try XCTUnwrap(estimator.observe(snapshot(3000, rx: 1_000_010, tx: 500_020)))
    XCTAssertEqual(afterReset.downloadMbps, 8)
    XCTAssertEqual(afterReset.uploadMbps, 4)
    XCTAssertNil(estimator.observe(snapshot(1, rx: 100, tx: 200)))
    XCTAssertNil(estimator.observe(snapshot(1, rx: 100, tx: 200)))
    XCTAssertNil(estimator.observe(snapshot(7000, rx: 100_000_000, tx: 200_000_000)))
    let afterGap = try XCTUnwrap(
      estimator.observe(snapshot(8000, rx: 101_000_000, tx: 201_000_000)))
    XCTAssertEqual(afterGap.downloadMbps, 8)
    XCTAssertEqual(afterGap.uploadMbps, 8)
    estimator.reset()
    XCTAssertNil(estimator.observe(snapshot(9000, rx: 102_000_000, tx: 202_000_000)))
  }
  func testHistoryIsBoundedAndBothDirectionsShareTheCeiling() {
    var history = DeviceNetworkHistory()
    XCTAssertTrue(history.samples.allSatisfy { $0 == nil })
    history.append(DeviceNetworkRate(uploadMbps: 4.7, downloadMbps: 0.2))
    XCTAssertEqual(history.ceilingMbps, 5)
    history.append(DeviceNetworkRate(uploadMbps: 0.5, downloadMbps: 8.5))
    XCTAssertEqual(history.ceilingMbps, 10)
    for _ in 0..<65 { history.append(DeviceNetworkRate(uploadMbps: 0.1, downloadMbps: 0.2)) }
    XCTAssertEqual(history.samples.count, 60)
    XCTAssertEqual(history.ceilingMbps, 1)
    history.append(nil)
    XCTAssertNil(history.samples.last!)
    history.reset()
    XCTAssertTrue(history.samples.allSatisfy { $0 == nil })
  }
  func testUploadIsAboveAndDownloadBelowSharedZeroLine() {
    XCTAssertEqual(
      DuplexNetworkGeometry.y(rate: 1, ceiling: 2, center: 64, halfHeight: 34, upload: true), 47)
    XCTAssertEqual(
      DuplexNetworkGeometry.y(rate: 1, ceiling: 2, center: 64, halfHeight: 34, upload: false), 81)
    for uploading in [true, false] {
      XCTAssertEqual(
        DuplexNetworkGeometry.y(rate: 0, ceiling: 2, center: 64, halfHeight: 34, upload: uploading),
        64)
    }
    XCTAssertEqual(
      DuplexNetworkGeometry.y(rate: 20, ceiling: 2, center: 64, halfHeight: 34, upload: true), 30)
    XCTAssertEqual(
      DuplexNetworkGeometry.y(rate: 20, ceiling: 2, center: 64, halfHeight: 34, upload: false), 98)
  }
  func testStreamingReaderUsesExplicitDeviceAndStopsItsOwnProcess() async throws {
    let fixture = try NetworkFixture()
    defer { fixture.remove() }
    let reader = fixture.reader()
    let values = NetworkTestValues()
    let done = expectation(description: "reader stopped")
    DispatchQueue.global().async {
      do {
        try reader.stream(helper: fixture.jar) { sample in
          if values.append(sample) == 2 { reader.stop() }
        }
      } catch { XCTFail(error.localizedDescription) }
      done.fulfill()
    }
    await fulfillment(of: [done], timeout: 10)
    XCTAssertEqual(values.samples.count, 2)
    XCTAssertEqual(values.samples.last?.receivedBytes, 1_000_100)
    let calls = try String(contentsOf: fixture.root.appendingPathComponent("calls.jsonl")).split(
      separator: "\n")
    let args = try calls.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String] }
    XCTAssertTrue(args.allSatisfy { $0.prefix(2) == ["-s", "NETWORK_PHONE"] })
    XCTAssertTrue(args.contains { $0.contains("push") && $0.contains(fixture.jar.path) })
    XCTAssertTrue(
      args.contains {
        $0.contains("shell") && $0.contains("-T")
          && $0.contains("dev.okestra.device.NetworkMonitor")
      })
  }
  func testDeviceUnsupportedResponseEndsReaderWithoutInventingRates() throws {
    let fixture = try NetworkFixture()
    defer { fixture.remove() }
    try Data().write(to: fixture.root.appendingPathComponent("unsupported"))
    let values = NetworkTestValues()
    XCTAssertThrowsError(try fixture.reader().stream(helper: fixture.jar) { _ = values.append($0) })
    { error in
      XCTAssertTrue(error.localizedDescription.contains("unavailable"))
    }
    XCTAssertTrue(values.samples.isEmpty)
  }
  private func snapshot(_ time: UInt64, rx: UInt64, tx: UInt64) -> DeviceNetworkSnapshot {
    DeviceNetworkSnapshot(elapsedMilliseconds: time, receivedBytes: rx, transmittedBytes: tx)
  }
}
private final class NetworkTestValues: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [DeviceNetworkSnapshot] = []
  func append(_ sample: DeviceNetworkSnapshot) -> Int {
    lock.lock()
    defer { lock.unlock() }
    values.append(sample)
    return values.count
  }
  var samples: [DeviceNetworkSnapshot] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}
private struct NetworkFixture: Sendable {
  let root: URL
  var jar: URL { root.appendingPathComponent("monitor.jar") }
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "network tests " + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([1]).write(to: root.appendingPathComponent("monitor.jar"))
    try Data("#!/bin/sh\nprintf '%s/adb\\n' \"$PWD\"\n".utf8).write(
      to: root.appendingPathComponent("okestra"))
    let adb = #"""
      #!/usr/bin/python3
      import sys,pathlib,json,time
      root=pathlib.Path(__file__).parent
      args=sys.argv[1:]
      assert args[:2]==['-s','NETWORK_PHONE']
      with (root/'calls.jsonl').open('a') as out: out.write(json.dumps(args)+'\n')
      if args[2]=='shell':
          if (root/'unsupported').exists():
              print(json.dumps(dict(version=1,error='Network counters unavailable')),flush=True)
          else:
              print(json.dumps(dict(version=1,elapsed_ms=1000,received_bytes=100,transmitted_bytes=200)),flush=True)
              time.sleep(.02)
              print(json.dumps(dict(version=1,elapsed_ms=2000,received_bytes=1000100,transmitted_bytes=500200)),flush=True)
          sys.stdin.buffer.read()
      """#
    try Data(adb.utf8).write(to: root.appendingPathComponent("adb"))
    for name in ["okestra", "adb"] {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent(name).path)
    }
  }
  func reader() -> DeviceNetworkSession {
    DeviceNetworkSession(
      cli: root.appendingPathComponent("okestra").path, directory: root.path,
      serial: "NETWORK_PHONE")
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}
