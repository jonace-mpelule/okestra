import AVFoundation
import Foundation
import XCTest

@testable import DeviceCore
@testable import DeviceTransport

final class DeveloperToolsTests: XCTestCase {
  func testShellArgumentsKeepLinksAndMetacharactersLiteral() throws {
    let values = [
      "am", "a'b", "app://booking?id=5&name='Jon'", "$(printf injected)", "", "two words",
    ]
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", "printf '%s\\n' " + AndroidTooling.shell(values)]
    task.standardOutput = pipe
    try task.run()
    let result = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    task.waitUntilExit()
    XCTAssertEqual(task.terminationStatus, 0)
    XCTAssertEqual(result, values.joined(separator: "\n") + "\n")
    XCTAssertThrowsError(try AndroidTooling.package("com.example; reboot"))
    XCTAssertThrowsError(try AndroidTooling.package(""))
    XCTAssertThrowsError(try AndroidTooling.link("missing scheme"))
    XCTAssertThrowsError(try AndroidTooling.link("app://test\nreboot"))
    XCTAssertEqual(
      try AndroidTooling.link(" urbanman://booking?id=5&source=test "),
      "urbanman://booking?id=5&source=test")
    for port in ["0", "65536", "-1", "localhost:8081"] {
      XCTAssertThrowsError(try AndroidTooling.port(port))
    }
  }
  func testPresetStoreKeepsDevicesSeparateAndUsesPrivateFilePermissions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("presets.json")
    var store = DeveloperPresetStore()
    var first = DeviceDeveloperPresets()
    first.links = [
      try SavedDeviceLink(name: "Booking", url: "app://booking?id=1", package: "com.example.app")
    ]
    first.ports = [try SavedDevicePort(name: "Metro", devicePort: "8081", macPort: "8081")]
    store.devices["local:phone1"] = first
    store.devices["server:dev:pixel"] = DeviceDeveloperPresets()
    try store.save(to: url)
    XCTAssertEqual(try DeveloperPresetStore.load(from: url).devices["local:phone1"], first)
    XCTAssertEqual(
      try DeveloperPresetStore.load(from: url).devices["server:dev:pixel"]?.links.count, 0)
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o600)
    try Data("bad json".utf8).write(to: url)
    XCTAssertThrowsError(try DeveloperPresetStore.load(from: url))
    XCTAssertEqual(try String(contentsOf: url), "bad json")
  }
  func testLogFilteringIncludesAppProcessesAndCrashSignalsAndStaysBounded() {
    let crash = DeviceLogEntry("10-30 12:00:00.000 123 124 E AndroidRuntime: FATAL EXCEPTION: main")
    XCTAssertEqual(crash.pid, 123)
    XCTAssertEqual(crash.level, "E")
    XCTAssertTrue(crash.isCrash)
    XCTAssertTrue(
      crash.matches(package: "com.example.app", pids: [123], query: "fatal", minimum: "W"))
    XCTAssertFalse(crash.matches(package: "com.other.app", pids: [456], query: "", minimum: "V"))
    let process = DeviceLogEntry(
      "10-30 12:00:00.001 123 124 E AndroidRuntime: Process: com.example.app, PID: 123")
    XCTAssertTrue(process.matches(package: "com.example.app", pids: [], query: "", minimum: "E"))
    XCTAssertTrue(
      DeviceLogEntry("10-30 12:00:00.000 100 100 E ActivityManager: ANR in com.example.app").isCrash
    )
    var buffer = DeviceLogBuffer()
    _ = buffer.append((0..<6000).map { "line \($0)" })
    XCTAssertEqual(buffer.entries.count, 5000)
    XCTAssertEqual(buffer.entries.first?.text, "line 1000")
    _ = buffer.append(Array(repeating: String(repeating: "x", count: 30_000), count: 200))
    XCTAssertLessThanOrEqual(buffer.entries.reduce(0) { $0 + $1.text.utf8.count }, 2 * 1024 * 1024)
    XCTAssertTrue(buffer.entries.allSatisfy { $0.text.count <= 16_384 })
  }
  func testToolCommandsTargetOnlyExplicitSerialAndCheckAndroidFailures() throws {
    let fixture = try FakeDeveloperDevice()
    defer { fixture.remove() }
    let device = fixture.device()
    XCTAssertEqual(try device.applications(), ["com.example.app"])
    XCTAssertTrue(try device.launch("com.example.app").contains("Status: ok"))
    XCTAssertEqual(try device.clearData("com.example.app"), "Cleared app storage.")
    let link = try SavedDeviceLink(name: "Example", url: "app://route?x='quoted'&other=$HOME")
    _ = try device.open(link)
    let lines = try String(contentsOf: fixture.root.appendingPathComponent("calls.jsonl")).split(
      separator: "\n")
    let calls = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String] }
    XCTAssertTrue(calls.allSatisfy { $0.prefix(2) == ["-s", "PHONE123"] })
    XCTAssertTrue(
      calls.contains { $0.last?.contains("'app://route?x='\\''quoted'\\''&other=$HOME'") == true })
    XCTAssertThrowsError(try device.launch("com.example.nonlaunchable"))
    XCTAssertThrowsError(try device.clearData("com.example.denied"))
    XCTAssertThrowsError(try AndroidTooling.checkResult("Error: Activity not started"))
  }
  func testInstallReportsFailureAndNeverAutomaticallyClearsData() throws {
    let fixture = try FakeDeveloperDevice()
    defer { fixture.remove() }
    let good = fixture.root.appendingPathComponent("a build.apk")
    let bad = fixture.root.appendingPathComponent("failure.apk")
    try Data([1]).write(to: good)
    try Data([1]).write(to: bad)
    let device = fixture.device()
    XCTAssertTrue(try device.install(good).contains("Installed"))
    XCTAssertThrowsError(try device.install(bad))
    XCTAssertThrowsError(try device.install(fixture.root.appendingPathComponent("app.aab")))
    let calls = try String(contentsOf: fixture.root.appendingPathComponent("calls.jsonl"))
    XCTAssertFalse(calls.contains("clear"))
    XCTAssertFalse(calls.contains("uninstall"))
  }
  func testReverseMappingsRefuseToReplaceOrRemoveAnotherMapping() throws {
    let fixture = try FakeDeveloperDevice()
    defer { fixture.remove() }
    let device = fixture.device()
    let metro = try SavedDevicePort(name: "Metro", devicePort: "8081", macPort: "8081")
    _ = try device.apply(metro)
    XCTAssertEqual(try device.mappings()[8081], "tcp:8081")
    _ = try device.apply(metro)
    let conflicting = try SavedDevicePort(name: "Other", devicePort: "8081", macPort: "3000")
    XCTAssertThrowsError(try device.apply(conflicting))
    XCTAssertThrowsError(try device.remove(conflicting))
    XCTAssertEqual(try device.mappings()[8081], "tcp:8081")
    _ = try device.remove(metro)
    XCTAssertNil(try device.mappings()[8081])
  }
  func testLogMailboxCoalescesAndBoundsUIWork() {
    let mailbox = DeviceLogMailbox()
    XCTAssertTrue(mailbox.offer(["first"]))
    for index in 0..<1000 { XCTAssertFalse(mailbox.offer(["line \(index)"])) }
    let lines = mailbox.take()
    XCTAssertEqual(lines.count, 513)
    XCTAssertTrue(lines.first!.contains("Skipped"))
    XCTAssertEqual(lines.last, "line 999")
    XCTAssertTrue(mailbox.offer(["next batch"]))
    XCTAssertEqual(mailbox.take(), ["next batch"])
  }
  func testBugReportContainsSessionLogsScreenshotAndOptionalRecording() throws {
    let fixture = try FakeDeveloperDevice()
    defer { fixture.remove() }
    let destination = fixture.root.appendingPathComponent("report.zip")
    let movie = fixture.root.appendingPathComponent("recorded.mov")
    try Data([1, 2, 3]).write(to: movie)
    try DeveloperBugReport.export(
      session: fixture.device(), destination: destination,
      context: ["device": "test phone", "app_package": "com.example.app"],
      package: "com.example.app",
      notes: "Repro steps", logs: "App log text", recording: movie)
    let unpacked = fixture.root.appendingPathComponent("unpacked")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", destination.path, unpacked.path]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    let folder = unpacked.appendingPathComponent("Okestra Bug Report")
    XCTAssertEqual(
      try String(contentsOf: folder.appendingPathComponent("logcat.txt")), "App log text")
    XCTAssertEqual(
      try String(contentsOf: folder.appendingPathComponent("notes.txt")), "Repro steps")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: folder.appendingPathComponent("screenshot.png").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: folder.appendingPathComponent("app-details.txt").path))
    XCTAssertEqual(
      try Data(contentsOf: folder.appendingPathComponent("recording.mov")), Data([1, 2, 3]))
    let context =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: folder.appendingPathComponent("session.json"))) as! [String: String]
    XCTAssertEqual(context["app_package"], "com.example.app")
  }
  func testAudioPacketShapeRejectsPartialSamples() throws {
    XCTAssertEqual(try DeviceAudioPCM.frameCount(Data(repeating: 0, count: 4096)), 1024)
    XCTAssertThrowsError(try DeviceAudioPCM.frameCount(Data()))
    XCTAssertThrowsError(try DeviceAudioPCM.frameCount(Data(repeating: 0, count: 3)))
    XCTAssertThrowsError(try DeviceAudioPCM.frameCount(Data(repeating: 0, count: 300_000)))
  }
  func testRecordingMuxesRealH264AndPCMIntoReadableMovie() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".mov")
    defer { try? FileManager.default.removeItem(at: url) }
    let done = expectation(description: "movie finished")
    let recording = DeviceRecording()
    recording.onState = { active, message, saved in
      if !active {
        XCTAssertNotNil(saved, message)
        done.fulfill()
      }
    }
    try recording.start(url: url, audio: true)
    let fixture = Data(
      base64Encoded:
        "AAAAAWdCwArZHsBEAAADAAQAAAMACDxImSAAAAABaMuDyyAAAAABZYiEBXxGKAALjMcAAToY4AA2DYA=")!
    let decoder = VideoDecoder()
    for index in 0..<20 {
      let time = UInt64(1_000_000 + index * 33_333)
      let sample = try XCTUnwrap(
        decoder.consume(fixture, config: false, keyframe: true, timestampMicroseconds: time))
      recording.consumeVideo(sample)
      recording.consumeAudio(Data(repeating: 0, count: 4096), timestamp: time)
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    recording.stop()
    await fulfillment(of: [done], timeout: 10)
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.load(.tracks)
    XCTAssertTrue(tracks.contains { $0.mediaType == .video })
    XCTAssertTrue(tracks.contains { $0.mediaType == .audio })
    let duration = try await asset.load(.duration)
    XCTAssertGreaterThan(duration.seconds, 0.5)
    let reader = try AVAssetReader(asset: asset)
    let video = try XCTUnwrap(tracks.first { $0.mediaType == .video })
    let output = AVAssetReaderTrackOutput(
      track: video,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    XCTAssertTrue(reader.startReading())
    XCTAssertNotNil(output.copyNextSampleBuffer())
    reader.cancelReading()
  }
}

private struct FakeDeveloperDevice {
  let root: URL
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "developer tests " + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cli = "#!/bin/sh\nprintf '%s/adb\\n' \"$PWD\"\n"
    try Data(cli.utf8).write(to: root.appendingPathComponent("okestra"))
    let adb = #"""
      #!/usr/bin/python3
      import sys,json,pathlib,shlex
      root=pathlib.Path(__file__).parent
      args=sys.argv[1:]
      with (root/'calls.jsonl').open('a') as out: out.write(json.dumps(args)+'\n')
      assert args[:2]==['-s','PHONE123']
      args=args[2:]
      if args[0]=='install':
          print('Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]' if args[-1].endswith('failure.apk') else 'Success')
      elif args[0]=='shell':
          command=shlex.split(args[1])
          if command[:3]==['pm','list','packages']: print('package:com.example.app')
          elif command[:3]==['cmd','package','resolve-activity']:
              print('No activity found' if command[-1].endswith('nonlaunchable') else command[-1]+'/.MainActivity')
          elif command[:2]==['pm','clear']: print('Failed' if command[-1].endswith('denied') else 'Success')
          else: print('Status: ok')
      elif args[0]=='exec-out': sys.stdout.buffer.write(bytes([137,80,78,71,13,10,26,10]))
      elif args[0]=='reverse':
          path=root/'ports.json'
          ports=json.loads(path.read_text()) if path.exists() else {}
          if args[1]=='--list':
              for k,v in ports.items(): print('UsbFfs '+k+' '+v)
          elif args[1]=='--no-rebind':
              assert args[2] not in ports
              ports[args[2]]=args[3]
          elif args[1]=='--remove': ports.pop(args[2],None)
          path.write_text(json.dumps(ports))
      """#
    try Data(adb.utf8).write(to: root.appendingPathComponent("adb"))
    for name in ["okestra", "adb"] {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent(name).path)
    }
  }
  func device() -> DeveloperDeviceSession {
    DeveloperDeviceSession(
      cli: root.appendingPathComponent("okestra").path, directory: root.path, serial: "PHONE123")
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}
