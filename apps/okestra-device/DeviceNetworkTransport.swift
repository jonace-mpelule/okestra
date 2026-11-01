import Foundation

#if canImport(DeviceCore)
  import DeviceCore
#endif

// A separate, small ADB reader leaves capture/control independent of statistics.
// Only this session's process and stdin are closed; the shared ADB server is retained.
final class DeviceNetworkSession: @unchecked Sendable {
  private let operation: DeviceSession
  private let serial: String
  private let lock = NSLock()
  private var process: Process?
  private var stdin: Pipe?
  private var cancelled = false
  private var timedOut = false
  private var lastReading = ProcessInfo.processInfo.systemUptime
  init(cli: String, directory: String, serial: String) {
    self.serial = serial
    operation = DeviceSession(cli: cli, workingDirectory: directory, profile: nil)
  }
  func stream(helper: URL, onSample: @escaping (DeviceNetworkSnapshot) -> Void) throws {
    defer { stop() }
    guard !serial.isEmpty, FileManager.default.fileExists(atPath: helper.path) else {
      throw DeviceError.message("Network monitor component is missing. Reinstall Okestra Device.")
    }
    let adb = try operation.adbPath()
    let remote = "/data/local/tmp/okestra-network-monitor-v1.jar"
    _ = try operation.invoke(adb, ["-s", serial, "push", helper.path, remote], timeout: 20)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: adb)
    task.arguments = [
      "-s", serial, "shell", "-T", "CLASSPATH=" + remote, "app_process", "/",
      "dev.okestra.device.NetworkMonitor",
    ]
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "ADB_SERVER_SOCKET")
    env.removeValue(forKey: "ANDROID_SERIAL")
    task.environment = env
    let pipe = Pipe()
    let input = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    task.standardInput = input
    lock.lock()
    guard !cancelled else {
      lock.unlock()
      throw DeviceError.message("Network monitor cancelled.")
    }
    process = task
    stdin = input
    lastReading = ProcessInfo.processInfo.systemUptime
    do { try task.run() } catch {
      lock.unlock()
      throw error
    }
    lock.unlock()
    let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    watchdog.schedule(deadline: .now() + 2, repeating: 2)
    watchdog.setEventHandler { [weak self] in
      guard let self else { return }
      self.lock.lock()
      let stalled = !self.cancelled && ProcessInfo.processInfo.systemUptime - self.lastReading > 10
      if stalled { self.timedOut = true }
      self.lock.unlock()
      if stalled { self.stop() }
    }
    watchdog.resume()
    defer { watchdog.cancel() }
    var pending = Data()
    var diagnostics = ""
    while true {
      let bytes = pipe.fileHandleForReading.availableData
      if bytes.isEmpty { break }
      pending.append(bytes)
      guard pending.count <= 64 * 1024 else {
        throw DeviceError.message("Network monitor returned an oversized reading.")
      }
      while let newline = pending.firstIndex(of: 10) {
        let line = Data(pending[..<newline])
        pending.removeSubrange(...newline)
        guard line.first == 123 else {
          diagnostics = String((diagnostics + String(decoding: line, as: UTF8.self)).suffix(1024))
          continue
        }
        let sample = try DeviceNetworkSnapshot(data: line)
        lock.lock()
        lastReading = ProcessInfo.processInfo.systemUptime
        let active = !cancelled
        lock.unlock()
        if active { onSample(sample) }
      }
    }
    task.waitUntilExit()
    try? pipe.fileHandleForReading.close()
    lock.lock()
    let stalled = timedOut
    let wasCancelled = cancelled
    lock.unlock()
    if stalled { throw DeviceError.message("Android stopped returning network readings.") }
    if !wasCancelled {
      throw DeviceError.message(
        diagnostics.isEmpty ? "The device network reader disconnected." : diagnostics)
    }
  }
  func stop() {
    lock.lock()
    cancelled = true
    let task = process
    let input = stdin
    stdin = nil
    lock.unlock()
    operation.stop()
    try? input?.fileHandleForWriting.close()
    if let task, task.isRunning {
      task.terminate()
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
        if task.isRunning { kill(task.processIdentifier, SIGKILL) }
      }
    }
  }
  deinit { stop() }
}
