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
      host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: Self.parameters())
  }
  private static func parameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: nil, tcp: tcp)
    parameters.serviceClass = .interactiveVideo
    return parameters
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
  let cli: String, workingDirectory: String, profile: String?
  let configuration: StreamConfiguration
  let targetSerial: String?
  let measurements = StreamMeasurements()
  let audioEnabled: Bool
  private let audioPlayer: DeviceAudioPlayer
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
  var onIdentity: (DeviceIdentity) -> Void = { _ in }
  var onTarget: (String) -> Void = { _ in }
  var onAudioState: (String) -> Void = { _ in }
  var onEncodedFrame: (CMSampleBuffer) -> Void = { _ in }
  var onAudioFrame: (Data, UInt64) -> Void = { _, _ in }
  init(
    cli: String, workingDirectory: String, profile: String?,
    configuration: StreamConfiguration = StreamMode.balanced.configuration,
    targetSerial: String? = nil, audioEnabled: Bool = false, audioVolume: Float = 1
  ) {
    self.cli = cli
    self.workingDirectory = workingDirectory
    self.profile = profile
    self.configuration = configuration
    self.targetSerial = targetSerial
    self.audioEnabled = audioEnabled
    audioPlayer = DeviceAudioPlayer(volume: audioVolume)
  }
  func stop() {
    audioPlayer.stop()
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
  func setAudioVolume(_ volume: Float) { audioPlayer.setVolume(volume) }
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
    args + ((profile ?? resolvedProfile).map { ["--profile", $0] } ?? [])
  }
  func invoke(_ executable: String, _ args: [String], timeout: Double = 60, input: Data? = nil)
    throws -> Data
  {
    if isCancelled { throw DeviceError.message("Cancelled") }
    let process = Process()
    let pipe = Pipe()
    let stdin = input.map { _ in Pipe() }
    if let stdin {
      process.standardInput = stdin
    } else {
      process.standardInput = FileHandle.nullDevice
    }
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
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
    if let stdin, let input {
      try? stdin.fileHandleForWriting.write(contentsOf: input)
      try? stdin.fileHandleForWriting.close()
    }
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
  func adbPath() throws -> String {
    String(decoding: try invoke(cli, ["android", "adb-path"], timeout: 10), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  func localDevices() throws -> [LocalAndroidDevice] {
    let path = try adbPath()
    return LocalAndroidDevice.parse(
      String(decoding: try invoke(path, ["devices", "-l"], timeout: 10), as: UTF8.self))
  }
  func pairWireless(address: String, code: String) throws -> String {
    let endpoint = try WirelessDeviceAddress.validate(address)
    let code = try WirelessDeviceAddress.validateCode(code)
    let path = try adbPath()
    let data = try invoke(path, ["pair", endpoint], timeout: 30, input: Data((code + "\n").utf8))
    let result = String(decoding: data, as: UTF8.self)
    guard result.lowercased().contains("successfully paired") else {
      throw DeviceError.message(
        "Pairing failed. Check the pairing address and generate a new code on the phone.")
    }
    return
      "Paired with \(endpoint). Now enter the connection address from the main Wireless debugging screen."
  }
  func connectWireless(address: String) throws -> String {
    let endpoint = try WirelessDeviceAddress.validate(address)
    let path = try adbPath()
    let result = String(
      decoding: try invoke(path, ["connect", endpoint], timeout: 15), as: UTF8.self)
    guard result.contains("connected to ") else {
      throw DeviceError.message(result.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return endpoint
  }
  func stream() throws {
    defer { cleanup() }
    if let targetSerial {
      guard let device = try localDevices().first(where: { $0.id == targetSerial }) else {
        throw DeviceError.message(
          "Phone disconnected. Reconnect USB or refresh its Wi-Fi connection.")
      }
      guard device.ready else { throw DeviceError.message(device.status) }
      serial = device.id
    } else {
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
          throw DeviceError.message(
            "Android is \(device). Start the device or inspect device logs.")
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
    }
    adb = try adbPath()
    onTarget(serial)
    guard let jar = Bundle.main.path(forResource: "scrcpy-server-3.3.4", ofType: "jar") else {
      throw DeviceError.message("Capture component missing. Reinstall Okestra Device.")
    }
    // Probe the actual guest display. Failure to read cosmetic metadata must not stop capture.
    let model =
      (try? adbCommand(["shell", "getprop", "ro.product.model"], timeout: 5)).map {
        String(decoding: $0, as: UTF8.self)
      } ?? "Android"
    let avd =
      (try? adbCommand(["shell", "getprop", "ro.boot.qemu.avd_name"], timeout: 5)).map {
        String(decoding: $0, as: UTF8.self)
      } ?? ""
    let size =
      (try? adbCommand(["shell", "wm", "size"], timeout: 5)).map {
        String(decoding: $0, as: UTF8.self)
      } ?? ""
    onIdentity(DeviceIdentity.parse(model: model, avd: avd, size: size))
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
    process.arguments =
      [
        "-s", serial, "shell", "CLASSPATH=/data/local/tmp/okestra-scrcpy-3.3.4.jar", "app_process",
        "/", "com.genymobile.scrcpy.Server", "3.3.4", "scid=" + String(format: "%08x", scid),
        "audio=\(audioEnabled)", "audio_codec=raw", "tunnel_forward=true", "control=true", "video_codec=h264",
        "send_device_meta=false", "send_codec_meta=true",
        "send_frame_meta=true", "clipboard_autosync=false",
      ] + configuration.serverArguments
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
    // The pinned server accepts sockets in video → audio → control order.
    // Audio failure must leave video and device input running.
    var audio: DeviceSocket?
    if audioEnabled {
      let socket = DeviceSocket(port: portNumber)
      try add(socket)
      try socket.start()
      audio = socket
    }
    let control = DeviceSocket(port: portNumber)
    try add(control)
    try control.start()
    lock.lock()
    self.control = control
    lock.unlock()
    if let audio {
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let codec = try audio.read(4, timeout: 15).unsigned(at: 0, bytes: 4)
          guard codec == 0x0072_6177 else {
            self.onAudioState(codec == 0 ? "Audio unavailable on this device. Video continues." : "Audio format unavailable. Video continues.")
            audio.close()
            return
          }
          self.onAudioState("Playing Android audio through the Mac output")
          while !self.isCancelled {
            let packet = try VideoPacket(header: audio.read(12))
            let data = try audio.read(packet.length)
            guard !packet.config else { continue }
            _ = try DeviceAudioPCM.frameCount(data)
            self.onAudioFrame(data, packet.timestampMicroseconds)
            self.audioPlayer.play(data) { self.onAudioState($0) }
          }
        } catch {
          if !self.isCancelled { self.onAudioState("Audio stopped: \(error.localizedDescription). Video continues.") }
        }
        self.audioPlayer.stop()
        audio.close()
      }
    }
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
    let renderer = RealtimeVideoDecoder()
    var backlog = StreamBacklogEstimator()
    while !isCancelled {
      let packet = try VideoPacket(header: video.read(12))
      let data = try video.read(packet.length)
      let arrival = ProcessInfo.processInfo.systemUptime
      let pendingMS =
        packet.config
        ? 0 : backlog.observe(microseconds: packet.timestampMicroseconds, arrival: arrival)
      if let sample = try decoder.consume(
        data, config: packet.config, keyframe: packet.keyframe,
        timestampMicroseconds: packet.timestampMicroseconds)
      {
        onEncodedFrame(sample)
        let decoded = try renderer.decode(sample)
        let decodeMS = (ProcessInfo.processInfo.systemUptime - arrival) * 1000
        measurements.received(
          bytes: data.count + 12, decodeMS: decodeMS, backlogMS: pendingMS,
          hardware: renderer.hardwareAccelerated)
        if let decoded { onFrame(decoded) }
      }
    }
  }
  private func cleanup() {
    audioPlayer.stop()
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
