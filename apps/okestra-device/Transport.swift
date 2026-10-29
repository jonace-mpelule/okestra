import AVFoundation
import Foundation
import Network

#if canImport(DeviceCore)
  import DeviceCore
#endif

// The packet format is pinned to the bundled scrcpy 3.3.4 server.
final class DeviceSocket: @unchecked Sendable {
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "dev.okestra.device.socket")
  init(port: UInt16) {
    connection = NWConnection(
      host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
  }
  func start() throws {
    let ready = DispatchSemaphore(value: 0)
    let state = SocketResult()
    connection.stateUpdateHandler = { value in
      switch value {
      case .ready:
        state.finish(Data())
        ready.signal()
      case .failed(let error):
        state.fail(error)
        ready.signal()
      case .cancelled:
        state.fail(DeviceError.message("Connection closed"))
        ready.signal()
      default: break
      }
    }
    connection.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success else {
      close()
      throw DeviceError.message("Device connection timed out")
    }
    _ = try state.value()
  }
  func read(_ count: Int, timeout: Double? = nil) throws -> Data {
    guard count > 0, count <= 8 * 1024 * 1024 else {
      throw DeviceError.message("Invalid device read size")
    }
    let ready = DispatchSemaphore(value: 0)
    let state = SocketResult()
    connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
      if let error {
        state.fail(error)
      } else if let data, data.count == count {
        state.finish(data)
      } else {
        state.fail(DeviceError.message("Device stream ended"))
      }
      ready.signal()
    }
    if let timeout {
      guard ready.wait(timeout: .now() + timeout) == .success else {
        close()
        throw DeviceError.message("Device handshake timed out")
      }
    } else {
      ready.wait()
    }
    return try state.value()
  }
  func send(_ data: Data) {
    connection.send(
      content: data,
      completion: .contentProcessed { [weak self] error in if error != nil { self?.close() } })
  }
  func close() { connection.cancel() }
  deinit { close() }
}
private final class SocketResult: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Data, Error>?
  func finish(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    if result == nil { result = .success(data) }
  }
  func fail(_ error: Error) {
    lock.lock()
    defer { lock.unlock() }
    if result == nil { result = .failure(error) }
  }
  func value() throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard let result else { throw DeviceError.message("Incomplete device connection") }
    return try result.get()
  }
}

final class DeviceSession: @unchecked Sendable {
  let cli: String, folder: String, profile: String?
  private let lock = NSLock()
  private var cancelled = false
  private var sockets: [DeviceSocket] = []
  private var command: Process?, server: Process?
  private var control: DeviceSocket?
  private var heartbeat: DispatchSourceTimer?
  private var serial = "", port = "", adb = ""
  private var resolvedProfile: String?
  var onProfile: (String) -> Void = { _ in }
  var onClipboard: (String) -> Void = { _ in }
  var onState: (String) -> Void = { _ in }
  var onFrame: (CMSampleBuffer) -> Void = { _ in }
  init(cli: String, folder: String, profile: String?) {
    self.cli = cli
    self.folder = folder
    self.profile = profile
  }
  func stop() {
    lock.lock()
    cancelled = true
    let sockets = self.sockets
    let command = self.command
    let server = self.server
    lock.unlock()
    for socket in sockets { socket.close() }
    if let command, command.isRunning { command.terminate() }
    if let server, server.isRunning { server.terminate() }
  }
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
  func send(_ data: Data) {
    lock.lock()
    let target = control
    lock.unlock()
    target?.send(data)
  }
  private func add(_ socket: DeviceSocket) throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled {
      socket.close()
      throw DeviceError.message("Cancelled")
    }
    sockets.append(socket)
  }
  func cliArguments(_ args: [String]) -> [String] {
    args + ["-f", folder + "/okestra.json"]
      + ((profile ?? resolvedProfile).map { ["--profile", $0] } ?? [])
  }
  func invoke(_ executable: String, _ args: [String], timeout: Double = 60) throws -> Data {
    if isCancelled { throw DeviceError.message("Cancelled") }
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: folder)
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "ADB_SERVER_SOCKET")
    env.removeValue(forKey: "ANDROID_SERIAL")
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
    process.environment = env
    process.standardOutput = pipe
    process.standardError = pipe
    lock.lock()
    if cancelled {
      lock.unlock()
      throw DeviceError.message("Cancelled")
    }
    command = process
    do { try process.run() } catch {
      command = nil
      lock.unlock()
      throw error
    }
    lock.unlock()
    let timer = DispatchWorkItem {
      if process.isRunning {
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
          if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
      }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timer.cancel()
    lock.lock()
    command = nil
    lock.unlock()
    guard process.terminationStatus == 0 else {
      throw DeviceError.message(
        String(decoding: data.suffix(4096), as: UTF8.self).trimmingCharacters(
          in: .whitespacesAndNewlines))
    }
    return data
  }
  private func adbCommand(_ args: [String], timeout: Double = 30) throws -> Data {
    try invoke(adb, ["-s", serial] + args, timeout: timeout)
  }
  func stream() throws {
    defer { cleanup() }
    if profile == nil {
      resolvedProfile = String(
        decoding: try invoke(cli, ["android", "active-profile"]), as: UTF8.self
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      if let resolvedProfile { onProfile(resolvedProfile) }
    }
    onState("Checking Android…")
    let bootDeadline = Date().addingTimeInterval(180)
    while true {
      let bytes = try invoke(cli, cliArguments(["android", "status", "--json"]))
      guard let obj = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
        let device = obj["device"] as? String
      else { throw DeviceError.message("Invalid Android status") }
      if device == "ready" { break }
      guard device == "booting", Date() < bootDeadline else {
        throw DeviceError.message("Android is \(device). Start the device or inspect device logs.")
      }
      onState("Android is booting…")
      if isCancelled { throw DeviceError.message("Cancelled") }
      Thread.sleep(forTimeInterval: 2)
    }
    onState("Connecting through Okestra…")
    _ = try invoke(cli, cliArguments(["android", "connect"]))
    let status = try invoke(cli, cliArguments(["android", "status", "--json"]))
    guard let obj = try JSONSerialization.jsonObject(with: status) as? [String: Any],
      let serial = obj["local_serial"] as? String, !serial.isEmpty
    else { throw DeviceError.message("No connected Android device") }
    self.serial = serial
    adb = String(decoding: try invoke(cli, ["android", "adb-path"]), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let jar = Bundle.main.path(forResource: "scrcpy-server-3.3.4", ofType: "jar") else {
      throw DeviceError.message("Capture component missing. Reinstall Okestra Device.")
    }
    onState("Preparing device capture…")
    _ = try adbCommand(["push", jar, "/data/local/tmp/okestra-scrcpy-3.3.4.jar"])
    let scid = UInt32.random(in: 1...0x7fff_ffff)
    let socketName = String(format: "scrcpy_%08x", scid)
    port = String(
      decoding: try adbCommand(["forward", "tcp:0", "localabstract:" + socketName]), as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let portNumber = UInt16(port), portNumber > 0 else {
      throw DeviceError.message("ADB did not reserve a local capture port")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: adb)
    process.arguments = [
      "-s", serial, "shell", "CLASSPATH=/data/local/tmp/okestra-scrcpy-3.3.4.jar", "app_process",
      "/", "com.genymobile.scrcpy.Server", "3.3.4", "scid=" + String(format: "%08x", scid),
      "audio=false", "tunnel_forward=true", "control=true", "video_codec=h264", "max_size=1280",
      "max_fps=30", "video_bit_rate=4000000", "send_device_meta=false", "send_codec_meta=true",
      "send_frame_meta=true", "clipboard_autosync=false",
    ]
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "ADB_SERVER_SOCKET")
    env.removeValue(forKey: "ANDROID_SERIAL")
    process.environment = env
    let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Logs/Okestra")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let logURL = logs.appendingPathComponent("device-capture.log")
    if !FileManager.default.fileExists(atPath: logURL.path) {
      FileManager.default.createFile(
        atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    let log = try FileHandle(forWritingTo: logURL)
    try log.truncate(atOffset: 0)
    defer { try? log.close() }
    process.standardOutput = log
    process.standardError = log
    lock.lock()
    if cancelled {
      lock.unlock()
      throw DeviceError.message("Cancelled")
    }
    server = process
    do { try process.run() } catch {
      lock.unlock()
      throw error
    }
    lock.unlock()
    var video: DeviceSocket?
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
      if isCancelled { throw DeviceError.message("Cancelled") }
      let candidate = DeviceSocket(port: portNumber)
      try add(candidate)
      do {
        try candidate.start()
        let dummy = try candidate.read(1, timeout: 3)
        guard dummy[0] == 0 else { throw DeviceError.message("Unexpected capture handshake") }
        video = candidate
        break
      } catch {
        candidate.close()
        if !process.isRunning {
          throw DeviceError.message(
            "Capture process stopped. Open diagnostics for device-capture.log.")
        }
        Thread.sleep(forTimeInterval: 0.1)
      }
    }
    guard let video else {
      throw DeviceError.message("Capture did not start within its connection deadline")
    }
    let control = DeviceSocket(port: portNumber)
    try add(control)
    try control.start()
    lock.lock()
    self.control = control
    lock.unlock()
    // Consume control replies so Android clipboard acknowledgement writes cannot block capture.
    DispatchQueue.global().async {
      while !self.isCancelled {
        do {
          let kind = try control.read(1)[0]
          switch kind {
          case 0:
            let length = Int(try control.read(4).unsigned(at: 0, bytes: 4))
            guard length <= 256 * 1024 else {
              throw DeviceError.message("Device clipboard exceeds size limit")
            }
            let bytes = length > 0 ? try control.read(length) : Data()
            guard let text = String(data: bytes, encoding: .utf8) else {
              throw DeviceError.message("Invalid device clipboard text")
            }
            self.onClipboard(text)
          case 1: _ = try control.read(8)
          default: throw DeviceError.message("Unsupported device control reply")
          }
        } catch {
          control.close()
          video.close()
          return
        }
      }
    }
    let heartbeat = DispatchSource.makeTimerSource(
      queue: DispatchQueue(label: "dev.okestra.device.heartbeat"))
    heartbeat.schedule(deadline: .now() + 8, repeating: 8)
    heartbeat.setEventHandler { [weak self, weak video, weak control] in
      guard let self, !self.isCancelled else { return }
      do { _ = try self.adbCommand(["shell", "true"], timeout: 5) } catch {
        video?.close()
        control?.close()
      }
    }
    lock.lock()
    self.heartbeat = heartbeat
    lock.unlock()
    heartbeat.resume()
    let metadata = try video.read(12, timeout: 10)
    guard try metadata.unsigned(at: 0, bytes: 4) == 0x6832_3634 else {
      throw DeviceError.message("Device does not support H.264 capture")
    }
    let decoder = VideoDecoder()
    while !isCancelled {
      let packet = try VideoPacket(header: video.read(12))
      let data = try video.read(packet.length)
      if let sample = try decoder.consume(data, config: packet.config, keyframe: packet.keyframe) {
        onFrame(sample)
      }
    }
  }
  private func cleanup() {
    lock.lock()
    cancelled = true
    heartbeat?.cancel()
    heartbeat = nil
    let sockets = self.sockets
    let server = self.server
    self.control = nil
    self.sockets = []
    lock.unlock()
    for socket in sockets { socket.close() }
    if let server, server.isRunning {
      server.terminate()
      let pid = server.processIdentifier
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
        if server.isRunning { kill(pid, SIGKILL) }
      }
    }
    if !adb.isEmpty && !port.isEmpty {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: adb)
      process.arguments = ["-s", serial, "forward", "--remove", "tcp:" + port]
      var env = ProcessInfo.processInfo.environment
      env.removeValue(forKey: "ADB_SERVER_SOCKET")
      process.environment = env
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      if (try? process.run()) != nil {
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
          if process.isRunning { kill(pid, SIGKILL) }
        }
        process.waitUntilExit()
      }
    }
  }
}
