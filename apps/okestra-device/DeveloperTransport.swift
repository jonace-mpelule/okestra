import Foundation

#if canImport(DeviceCore)
  import DeviceCore
#endif

// Each operation owns an immutable serial. A device switch can cancel an operation,
// but can never redirect it to a different phone or the default ADB device.
final class DeveloperDeviceSession: @unchecked Sendable {
  let serial: String
  private let operation: DeviceSession
  private var adb = ""
  init(cli: String, directory: String, serial: String) {
    self.serial = serial
    operation = DeviceSession(cli: cli, workingDirectory: directory, profile: nil)
  }
  func stop() { operation.stop() }
  func adbPath() throws -> String {
    if adb.isEmpty { adb = try operation.adbPath() }
    return adb
  }
  func run(_ args: [String], timeout: Double = 30) throws -> Data {
    guard !serial.isEmpty else { throw DeviceError.message("Connect a device first.") }
    return try operation.invoke(adbPath(), ["-s", serial] + args, timeout: timeout)
  }
  func shell(_ args: [String], timeout: Double = 30) throws -> String {
    let value = String(
      decoding: try run(["shell", AndroidTooling.shell(args)], timeout: timeout), as: UTF8.self
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    try AndroidTooling.checkResult(value)
    return value
  }
  func applications() throws -> [String] {
    AndroidTooling.packages(try shell(["pm", "list", "packages", "-3"]))
  }
  func launch(_ package: String) throws -> String {
    let package = try AndroidTooling.package(package)
    let resolution = try shell([
      "cmd", "package", "resolve-activity", "--brief", "-a",
      "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", package,
    ])
    guard let component = resolution.split(separator: "\n").last.map(String.init),
      component.hasPrefix(package + "/"), !component.contains(where: { $0.isWhitespace })
    else {
      throw DeviceError.message(
        "This app has no launchable activity. Open a saved deep link instead.")
    }
    return try shell(["am", "start", "-W", "-n", component])
  }
  func restart(_ package: String) throws -> String {
    _ = try shell(["am", "force-stop", AndroidTooling.package(package)])
    return try launch(package)
  }
  func clearData(_ package: String) throws -> String {
    let value = try shell(["pm", "clear", AndroidTooling.package(package)])
    guard value == "Success" else { throw DeviceError.message(value) }
    return "Cleared app storage."
  }
  func install(_ url: URL) throws -> String {
    guard url.isFileURL, url.pathExtension.lowercased() == "apk",
      (try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])).isRegularFile == true,
      ((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) > 0
    else {
      throw DeviceError.message("Choose a nonempty APK file.")
    }
    let text = String(decoding: try run(["install", "-r", url.path], timeout: 240), as: UTF8.self)
    try AndroidTooling.checkResult(text)
    guard
      text.split(separator: "\n").contains(where: {
        $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Success"
      })
    else {
      throw DeviceError.message(text.isEmpty ? "Android did not confirm installation." : text)
    }
    return "Installed \(url.lastPathComponent)."
  }
  func open(_ link: SavedDeviceLink) throws -> String {
    var args = [
      "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d",
      try AndroidTooling.link(link.url),
    ]
    if !link.package.isEmpty { args += ["-p", try AndroidTooling.package(link.package)] }
    return try shell(args)
  }
  func mappings() throws -> [Int: String] {
    let text = String(decoding: try run(["reverse", "--list"]), as: UTF8.self)
    var result: [Int: String] = [:]
    for line in text.split(separator: "\n") {
      let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
      if fields.count >= 3, fields[fields.count - 2].hasPrefix("tcp:"),
        let port = Int(fields[fields.count - 2].dropFirst(4))
      {
        result[port] = fields.last!
      }
    }
    return result
  }
  func apply(_ port: SavedDevicePort) throws -> String {
    _ = try AndroidTooling.port(String(port.devicePort))
    _ = try AndroidTooling.port(String(port.macPort))
    if let existing = try mappings()[port.devicePort] {
      guard existing == "tcp:\(port.macPort)" else {
        throw DeviceError.message(
          "Device port \(port.devicePort) already maps to \(existing). Remove that mapping explicitly before replacing it."
        )
      }
      return "\(port.name) is already connected."
    }
    _ = try run(["reverse", "--no-rebind", "tcp:\(port.devicePort)", "tcp:\(port.macPort)"])
    return "Device localhost:\(port.devicePort) → Mac localhost:\(port.macPort)"
  }
  func remove(_ port: SavedDevicePort) throws -> String {
    guard let existing = try mappings()[port.devicePort] else {
      return "Mapping is already inactive."
    }
    guard existing == "tcp:\(port.macPort)" else {
      throw DeviceError.message(
        "This port now belongs to a different mapping; it was left unchanged.")
    }
    _ = try run(["reverse", "--remove", "tcp:\(port.devicePort)"])
    return "Removed \(port.name) mapping."
  }
  func archive(folder: URL, to url: URL) throws {
    _ = try operation.invoke(
      "/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, url.path], timeout: 120)
  }
}

final class DeviceLogStream: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var stopped = false
  private let queue = DispatchQueue(label: "dev.okestra.logcat")
  func start(
    adb: String, serial: String, onLines: @escaping ([String]) -> Void,
    onExit: @escaping (String) -> Void
  ) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: adb)
    task.arguments = ["-s", serial, "logcat", "-v", "threadtime", "-T", "1"]
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "ADB_SERVER_SOCKET")
    env.removeValue(forKey: "ANDROID_SERIAL")
    task.environment = env
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    task.standardInput = FileHandle.nullDevice
    lock.lock()
    defer { lock.unlock() }
    guard !stopped else { throw DeviceError.message("Log capture cancelled.") }
    process = task
    try task.run()
    queue.async {
      var pending = Data()
      while true {
        let chunk = pipe.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 10) {
          lines.append(String(decoding: pending[..<newline], as: UTF8.self))
          pending.removeSubrange(...newline)
        }
        if pending.count > 64 * 1024 {
          lines.append(
            String(decoding: pending.prefix(16_384), as: UTF8.self) + " [line truncated]")
          pending.removeAll(keepingCapacity: true)
        }
        if !lines.isEmpty { onLines(lines) }
      }
      if !pending.isEmpty { onLines([String(decoding: pending, as: UTF8.self)]) }
      task.waitUntilExit()
      try? pipe.fileHandleForReading.close()
      self.lock.lock()
      let wasStopped = self.stopped
      self.process = nil
      self.lock.unlock()
      if !wasStopped {
        onExit(
          "Logcat ended (\(task.terminationStatus)). Reconnect the device and start logs again.")
      }
    }
  }
  func stop() {
    lock.lock()
    stopped = true
    let task = process
    lock.unlock()
    if let task, task.isRunning {
      task.terminate()
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
        if task.isRunning { kill(task.processIdentifier, SIGKILL) }
      }
    }
  }
  deinit { stop() }
}

enum DeveloperBugReport {
  static func export(
    session: DeveloperDeviceSession, destination: URL,
    context: [String: String], package: String, notes: String, logs: String, recording: URL?
  ) throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("okestra-report-" + UUID().uuidString)
    let folder = root.appendingPathComponent("Okestra Bug Report")
    try fm.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }
    try JSONSerialization.data(withJSONObject: context, options: [.prettyPrinted, .sortedKeys])
      .write(to: folder.appendingPathComponent("session.json"))
    try notes.write(
      to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try logs.write(
      to: folder.appendingPathComponent("logcat.txt"), atomically: true, encoding: .utf8)
    var warnings: [String] = []
    do {
      let png = try session.run(["exec-out", "screencap", "-p"])
      guard png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
        throw DeviceError.message("No PNG screenshot returned.")
      }
      try png.write(to: folder.appendingPathComponent("screenshot.png"))
    } catch { warnings.append("Screenshot: " + error.localizedDescription) }
    if !package.isEmpty {
      do {
        let info = try session.shell(["dumpsys", "package", AndroidTooling.package(package)])
        try info.write(
          to: folder.appendingPathComponent("app-details.txt"), atomically: true, encoding: .utf8)
      } catch { warnings.append("App details: " + error.localizedDescription) }
    }
    if let recording, fm.fileExists(atPath: recording.path) {
      do {
        try fm.copyItem(at: recording, to: folder.appendingPathComponent("recording.mov"))
      } catch { warnings.append("Recording: " + error.localizedDescription) }
    }
    let readme =
      "Okestra developer bug report\n\nLogcat contains the current visible filter's buffered logs. Start logs before reproducing an issue.\n\n"
      + warnings.joined(separator: "\n")
    try readme.write(
      to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    let zip = root.appendingPathComponent("report.zip")
    try session.archive(folder: folder, to: zip)
    let staged = destination.deletingLastPathComponent().appendingPathComponent(
      ".okestra-report-" + UUID().uuidString + ".zip")
    defer { try? fm.removeItem(at: staged) }
    try fm.copyItem(at: zip, to: staged)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
    guard rename(staged.path, destination.path) == 0 else {
      throw DeviceError.message("Cannot save the bug report: \(String(cString: strerror(errno)))")
    }
  }
}
