import AVFoundation
import AppKit
import Combine
import SwiftUI
import VideoToolbox

struct DeviceRotationPresentation: Identifiable {
  let id = UUID()
  let image: NSImage
  let displaySize: CGSize
  let videoSize: CGSize
}

@MainActor
final class DeviceController: ObservableObject {
  let developer = DeveloperController()
  @Published var source =
    DeviceSource(rawValue: UserDefaults.standard.string(forKey: "deviceSource") ?? "server")
    ?? .server
  @Published var localDevices: [LocalAndroidDevice] = []
  @Published var selectedLocalID = UserDefaults.standard.string(forKey: "localDeviceSerial") ?? ""
  @Published var wirelessBusy = false
  @Published var wirelessMessage = ""
  var selectedLocalDevice: LocalAndroidDevice? { localDevices.first { $0.id == selectedLocalID } }
  var deviceTitle: String {
    source == .local
      ? selectedLocalDevice?.title ?? "Choose a phone" : displayedDevice?.name ?? "Remote Android"
  }
  var canConnect: Bool { source == .local ? selectedLocalDevice?.ready == true : isRunning }
  @Published var profile: String? = UserDefaults.standard.string(forKey: "deviceServer")
  @Published var servers: [String] = []
  @Published var devices: [RemoteDeviceProfile] = []
  @Published var selectedDeviceID = ""
  @Published var activeDeviceID = ""
  @Published var remoteDevice = "stopped"
  @Published var localSerial = ""
  @Published var state = "Choose a paired server"
  @Published var connected = false
  @Published var connecting = false
  @Published var busy = false
  @Published var output = ""
  @Published var autoReconnect = true
  @Published var renderedSize = CGSize(width: 720, height: 1280)
  @Published var identity = DeviceIdentity()
  @Published var fps = 0.0
  @Published var megabits = 0.0
  @Published var fpsHistory = Array(repeating: 0.0, count: 40)
  @Published var bitrateHistory = Array(repeating: 0.0, count: 40)
  @Published var interactive = true
  @Published var showSidebar = true
  @Published private(set) var focusMode = false
  @Published private(set) var focusTransitioning = false
  let captures = DeviceScreenshotController()
  @Published var alwaysOnTop = UserDefaults.standard.bool(forKey: "deviceAlwaysOnTop") {
    didSet {
      UserDefaults.standard.set(alwaysOnTop, forKey: "deviceAlwaysOnTop")
      viewerWindow?.level = alwaysOnTop ? .floating : .normal
    }
  }
  weak var viewerWindow: NSWindow? {
    didSet { viewerWindow?.level = alwaysOnTop ? .floating : .normal }
  }
  private var workspaceFrame: CGRect?
  private var workspaceAutosaveName: NSWindow.FrameAutosaveName = ""
  private var focusFullscreenObserver: NSObjectProtocol?
  private var focusKeyMonitor: Any?
  @Published var backingScale = NSScreen.main?.backingScaleFactor ?? 2
  @Published var rotationPresentation: DeviceRotationPresentation?
  @Published var rotationRevealing = false
  private var rotationTask: Task<Void, Never>?
  private var refreshing = false
  private var initialConnect = true
  let workingDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Library/Application Support/Okestra/Device"
  ).path
  var selectedDevice: RemoteDeviceProfile? { devices.first { $0.id == selectedDeviceID } }
  var displayedDevice: RemoteDeviceProfile? {
    guard source == .server else { return nil }
    return devices.first {
      $0.id == activeDeviceID
        && (connected || connecting || remoteDevice == "ready" || remoteDevice == "booting")
    } ?? selectedDevice
  }
  var isRunning: Bool {
    remoteDevice == "ready" || remoteDevice == "booting" || remoteDevice == "running"
  }
  var chassis: DeviceChassis {
    if source == .local {
      return DeviceChassis.resolve(
        identity, videoWidth: renderedSize.width, videoHeight: renderedSize.height)
    }
    guard let device = displayedDevice else { return .pixel7Skin }
    var value = identity
    value.model =
      device.hardware == "pixel_9"
      ? "Pixel 9" : device.hardware == "pixel_7" ? "Pixel 7" : value.model
    return device.hardware == "pixel_9"
      ? DeviceChassis.resolve(
        value, videoWidth: renderedSize.width, videoHeight: renderedSize.height) : .pixel7Skin
  }
  var displaySize: CGSize {
    let profileWidth = displayedDevice?.width ?? 0
    let profileHeight = displayedDevice?.height ?? 0
    let w = identity.nativeWidth > 0 ? identity.nativeWidth : profileWidth > 0 ? profileWidth : 720
    let h =
      identity.nativeHeight > 0 ? identity.nativeHeight : profileHeight > 0 ? profileHeight : 1280
    let short = max(1, min(w, h))
    let long = max(1, max(w, h))
    return renderedSize.width > renderedSize.height
      ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
  }
  @Published var streamMode =
    StreamMode(rawValue: UserDefaults.standard.string(forKey: "streamMode") ?? "automatic")
    ?? .automatic
  @Published var effectiveStreamMode = StreamMode.balanced
  @Published var receivedFPS = 0.0
  @Published var decodeMS = 0.0
  @Published var uiWaitMS = 0.0
  @Published var backlogMS = 0.0
  @Published var skippedFrames = 0
  @Published var hardwareDecoder: Bool?
  private var adaptivePolicy = AdaptiveStreamPolicy()
  private var measurementTime = ProcessInfo.processInfo.systemUptime
  private var captureMailbox: LatestFrameMailbox<PendingVideoFrame>?
  func setStreamMode(_ mode: StreamMode) {
    guard mode != streamMode else { return }
    streamMode = mode
    UserDefaults.standard.set(mode.rawValue, forKey: "streamMode")
    adaptivePolicy.reset()
    if wantsConnection && !sleeping { connect(reset: true) }
  }
  func samplePerformance() {
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = max(0.001, now - measurementTime)
    let sample = session?.measurements.snapshot() ?? StreamMeasurement()
    fps = connected ? Double(sample.delivered) / elapsed : 0
    receivedFPS = connected ? Double(sample.received) / elapsed : 0
    megabits = connected ? Double(sample.bytes) * 8 / elapsed / 1_000_000 : 0
    decodeMS = sample.decodeMS
    uiWaitMS = sample.uiWaitMS
    backlogMS = sample.backlogMS
    skippedFrames = sample.replaced
    if let hardware = sample.hardwareDecoder { hardwareDecoder = hardware }
    fpsHistory = Array((fpsHistory + [fps]).suffix(40))
    bitrateHistory = Array((bitrateHistory + [megabits]).suffix(40))
    measurementTime = now
    if connected, streamMode == .automatic,
      let next = adaptivePolicy.evaluate(sample, now: now)
    {
      output =
        "Adaptive stream switched to \(next.title.lowercased()). Capture reconnects; the Android app keeps running."
      connect(reset: true)
    }
  }
  weak var screen: DeviceScreen?
  private var session: DeviceSession?
  private var retry: Task<Void, Never>?
  private var attempts = 0
  private var wantsConnection = false
  private var sleeping = false
  private var observers: [NSObjectProtocol] = []
  private var actionSession: DeviceSession?
  private var statusSession: DeviceSession?
  private var wirelessSession: DeviceSession?
  var cli: String? {
    let candidates = [
      Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/okestra").path,
      "/opt/homebrew/bin/okestra", "/usr/local/bin/okestra",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
  init() {
    captures.allowsEditor = { [weak self] in self?.developer.videoReview.editor == nil }
    developer.videoReview.onPreview = { [weak self] in self?.captures.dismiss() }
    developer.videoReview.prepareEditor = { [weak self] proceed in
      guard let self else { return }
      if let editor = self.captures.editor {
        editor.requestClose { [weak editor] in
          editor?.onClose()
          proceed()
        }
      } else {
        proceed()
      }
    }
    developer.onAudioChange = { [weak self] in
      guard let self, self.wantsConnection, !self.sleeping else { return }
      self.connect(reset: true)
    }
    developer.onRecordingStart = { [weak self] in self?.send(Data([17])) }
    developer.onVolumeChange = { [weak self] volume in
      guard let self else { return }
      self.session?.setAudioVolume(self.developer.videoReview.editor == nil ? volume : 0)
    }
    developer.videoReview.onEditorVisibility = { [weak self] visible in
      guard let self else { return }
      self.captures.objectWillChange.send()
      self.session?.setAudioVolume(visible ? 0 : self.developer.playbackVolume)
    }
    developer.reportContext = { [weak self] in
      guard let self else { return [:] }
      return [
        "device": self.deviceTitle, "serial": self.localSerial, "source": self.source.rawValue,
        "model": self.identity.model, "stream_mode": self.streamMode.rawValue,
        "video_size": "\(Int(self.renderedSize.width))×\(Int(self.renderedSize.height))",
        "display_size": "\(Int(self.displaySize.width))×\(Int(self.displaySize.height))",
        "fps": String(format: "%.1f", self.fps),
        "megabits_per_second": String(format: "%.2f", self.megabits),
        "audio": self.developer.audioStatus, "state": self.state,
      ]
    }
    let args = ProcessInfo.processInfo.arguments
    if let i = args.firstIndex(of: "--profile"), i + 1 < args.count { profile = args[i + 1] }
    try? FileManager.default.createDirectory(
      atPath: workingDirectory, withIntermediateDirectories: true)
    let center = NSWorkspace.shared.notificationCenter
    observers.append(
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in
          self?.sleeping = true
          self?.closeCapture()
          self?.state = "Mac is sleeping"
        }
      })
    observers.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          self.sleeping = false
          if self.wantsConnection { self.connect(reset: true) }
        }
      })
  }
  func begin() {
    initialConnect = true
    if source == .local { refreshLocalDevices() } else { loadServers() }
  }
  func selectSource(_ value: DeviceSource) {
    guard !busy, !wirelessBusy, value != source else { return }
    disconnect()
    cancelStatusRefresh()
    source = value
    UserDefaults.standard.set(value.rawValue, forKey: "deviceSource")
    identity = DeviceIdentity()
    localSerial = ""
    initialConnect = true
    if value == .local { refreshLocalDevices() } else { loadServers() }
  }
  func selectLocalDevice(_ id: String) {
    guard !busy, !wirelessBusy else { return }
    disconnect()
    selectedLocalID = id
    UserDefaults.standard.set(id, forKey: "localDeviceSerial")
    identity = DeviceIdentity()
    localSerial = id
    if selectedLocalDevice?.ready == true {
      connect(reset: true)
    } else {
      state = selectedLocalDevice?.status ?? "Connect your phone and refresh."
    }
  }
  func refreshLocalDevices() {
    guard source == .local, !busy, !refreshing, !wirelessBusy, let cli else { return }
    refreshing = true
    let operation = DeviceSession(cli: cli, workingDirectory: workingDirectory, profile: nil)
    statusSession = operation
    Task {
      defer {
        if statusSession === operation {
          refreshing = false
          statusSession = nil
        }
      }
      do {
        let found = try await Task.detached { try operation.localDevices() }.value
        guard source == .local, statusSession === operation else { return }
        localDevices = found
        if selectedLocalID.isEmpty {
          selectedLocalID = found.first(where: { $0.ready })?.id ?? found.first?.id ?? ""
        }
        localSerial = selectedLocalID
        if !connected && !connecting {
          state =
            selectedLocalDevice?.ready == true
            ? "Phone ready to connect"
            : selectedLocalDevice?.status ?? "Connect a USB phone or pair over Wi-Fi."
        }
        if initialConnect {
          initialConnect = false
          if selectedLocalDevice?.ready == true { connect(reset: true) }
        }
      } catch {
        guard source == .local, statusSession === operation else { return }
        if !connected { state = error.localizedDescription }
        output = error.localizedDescription
      }
    }
  }
  func wirelessAction(pair: Bool, address: String, code: String = "") {
    guard source == .local, !busy, !wirelessBusy, let cli else { return }
    cancelStatusRefresh()
    wirelessBusy = true
    wirelessMessage = pair ? "Pairing…" : "Connecting…"
    let operation = DeviceSession(cli: cli, workingDirectory: workingDirectory, profile: nil)
    wirelessSession = operation
    Task {
      do {
        let result = try await Task.detached {
          if pair { return try operation.pairWireless(address: address, code: code) }
          return try operation.connectWireless(address: address)
        }.value
        guard wirelessSession === operation else { return }
        wirelessBusy = false
        wirelessSession = nil
        if pair {
          wirelessMessage = result
        } else {
          disconnect()
          wirelessMessage = "Connected to \(result)."
          // Resolve an explicit endpoint even if mDNS reports the same phone under a service name.
          selectedLocalID = result
          UserDefaults.standard.set(result, forKey: "localDeviceSerial")
          initialConnect = true
        }
        refreshLocalDevices()
      } catch {
        guard wirelessSession === operation else { return }
        wirelessBusy = false
        wirelessSession = nil
        wirelessMessage =
          pair
          ? "Pairing failed. Check the address, open a new pairing code on the phone and try again."
          : error.localizedDescription
      }
    }
  }
  func loadServers() {
    guard source == .server, let cli, !busy else { return }
    let directory = workingDirectory
    Task {
      do {
        let result = try await Task.detached { () throws -> PairedDeviceServers in
          let operation = DeviceSession(cli: cli, workingDirectory: directory, profile: nil)
          let data = try operation.invoke(cli, ["android", "servers", "--json"], timeout: 10)
          return try JSONDecoder().decode(PairedDeviceServers.self, from: data)
        }.value
        guard source == .server else { return }
        servers = result.names
        let name =
          profile.flatMap { result.names.contains($0) ? $0 : nil }
          ?? (result.names.contains(result.active) ? result.active : result.names.first)
        if profile != name { profile = name }
        guard let name else {
          state = "Pair a server using the Okestra installer, then refresh."
          devices = []
          return
        }
        if selectedDeviceID.isEmpty {
          selectedDeviceID = UserDefaults.standard.string(forKey: "deviceSelection." + name) ?? ""
        }
        refreshDevices()
      } catch {
        state = error.localizedDescription
        output = state
      }
    }
  }
  func selectServer(_ name: String) {
    guard !busy, !wirelessBusy else { return }
    if source != .server { selectSource(.server) }
    guard !busy, name != profile else { return }
    disconnect()
    statusSession?.stop()
    statusSession = nil
    refreshing = false
    profile = name
    UserDefaults.standard.set(name, forKey: "deviceServer")
    devices = []
    identity = DeviceIdentity()
    activeDeviceID = ""
    remoteDevice = "stopped"
    localSerial = ""
    selectedDeviceID = UserDefaults.standard.string(forKey: "deviceSelection." + name) ?? ""
    initialConnect = true
    refreshDevices()
  }
  func selectDevice(_ id: String) {
    selectedDeviceID = id
    if let profile { UserDefaults.standard.set(id, forKey: "deviceSelection." + profile) }
    if !isRunning {
      identity = DeviceIdentity()
      if let device = selectedDevice, device.width > 0, device.height > 0 {
        renderedSize = CGSize(width: device.width, height: device.height)
      }
    }
  }
  func refreshDevices() {
    if source == .local {
      refreshLocalDevices()
      return
    }
    guard !busy, !refreshing, let cli, let server = profile else { return }
    refreshing = true
    let operation = DeviceSession(cli: cli, workingDirectory: workingDirectory, profile: server)
    statusSession = operation
    Task {
      defer {
        if statusSession === operation {
          refreshing = false
          statusSession = nil
        }
      }
      do {
        let value = try await Task.detached { () throws -> RemoteDeviceStatus in
          let data = try operation.invoke(
            cli, operation.cliArguments(["android", "status", "--json"]), timeout: 25)
          return try JSONDecoder().decode(RemoteDeviceStatus.self, from: data)
        }.value
        guard statusSession === operation, profile == server else { return }
        if let error = value.checks?["profiles"] {
          state = error
          output = error
          return
        }
        guard let profiles = value.profiles else {
          state = value.checks?["profiles"] ?? "Update the server to this device-profile release."
          devices = []
          return
        }
        devices = profiles
        remoteDevice = value.device
        activeDeviceID = value.active_profile ?? ""
        localSerial = value.local_serial ?? ""
        if !devices.contains(where: { $0.id == selectedDeviceID }) {
          selectDevice(
            devices.first(where: { $0.id == activeDeviceID })?.id ?? devices.first?.id ?? "")
        }
        if !value.enabled {
          state = "Enable Android on this server with the device installer."
        } else if !isRunning && !connecting {
          state =
            devices.isEmpty
            ? "Create a device profile to get started." : "Start a device to connect."
        }
        if initialConnect {
          initialConnect = false
          if isRunning { connect(reset: true) }
        }
      } catch {
        guard statusSession === operation, profile == server else { return }
        if !connected { state = error.localizedDescription }
        output = error.localizedDescription
      }
    }
  }
  func openURL(_ url: URL) {
    guard url.scheme == "okestra-device", url.host == "open",
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return }
    if let server = items.first(where: { $0.name == "server" || $0.name == "profile" })?.value {
      selectServer(server)
    }
    if let id = items.first(where: { $0.name == "device" })?.value { selectDevice(id) }
    begin()
  }
  func action(_ name: String) {
    guard source == .server else { return }
    guard !busy, let cli, let server = profile else { return }
    var args = ["android", name]
    if name == "start" {
      guard let selectedDevice else {
        state = "Choose a device profile first."
        return
      }
      args += ["--device", selectedDevice.id]
    }
    cancelStatusRefresh()
    busy = true
    let operation = DeviceSession(cli: cli, workingDirectory: workingDirectory, profile: server)
    actionSession = operation
    let arguments = operation.cliArguments(args)
    Task {
      let result = await Task.detached { () -> (Bool, String) in
        do {
          return (
            true,
            String(decoding: try operation.invoke(cli, arguments, timeout: 180), as: UTF8.self)
          )
        } catch { return (false, error.localizedDescription) }
      }.value
      guard actionSession === operation else { return }
      busy = false
      actionSession = nil
      output = result.1
      if result.0 {
        if name == "start" {
          remoteDevice = "booting"
          activeDeviceID = selectedDeviceID
          identity = DeviceIdentity()
          connect(reset: true)
        }
        if name == "device-stop" {
          disconnect()
          remoteDevice = "stopped"
        }
      }
      refreshDevices()
    }
  }
  func saveDevice(
    existing: RemoteDeviceProfile?, name: String, hardware: String, cores: Int, memory: Int
  ) {
    guard source == .server, !busy, let cli, let server = profile else { return }
    cancelStatusRefresh()
    busy = true
    let operation = DeviceSession(cli: cli, workingDirectory: workingDirectory, profile: server)
    actionSession = operation
    var args = [
      "android", existing == nil ? "profile-create" : "profile-update", "--name", name,
      "--hardware", hardware, "--cores", String(cores), "--memory", String(memory),
    ]
    if let existing { args += ["--device", existing.id] }
    let arguments = operation.cliArguments(args)
    Task {
      do {
        let value = try await Task.detached { () throws -> RemoteDeviceProfile in
          let data = try operation.invoke(cli, arguments, timeout: 180)
          return try JSONDecoder().decode(RemoteDeviceProfile.self, from: data)
        }.value
        guard actionSession === operation else { return }
        busy = false
        actionSession = nil
        selectDevice(value.id)
        output = "Saved device profile: \(value.name)"
        refreshDevices()
      } catch {
        guard actionSession === operation else { return }
        busy = false
        actionSession = nil
        output = error.localizedDescription
        state = output
      }
    }
  }
  private func cancelStatusRefresh() {
    statusSession?.stop()
    statusSession = nil
    refreshing = false
  }
  func connect(reset: Bool = false) {
    // Retries retain the chosen serial even while discovery temporarily reports it missing.
    // The transport checks presence and authorization before sending any capture commands.
    guard source == .local ? !selectedLocalID.isEmpty : profile != nil, !sleeping else {
      return
    }
    closeCapture()
    wantsConnection = true
    if reset { attempts = 0 }
    guard let cli else {
      state = "Reinstall Okestra Device: its CLI is missing"
      return
    }
    connecting = true
    state = "Connecting…"
    effectiveStreamMode = streamMode == .automatic ? adaptivePolicy.level : streamMode
    let session = DeviceSession(
      cli: cli, workingDirectory: workingDirectory, profile: profile,
      configuration: effectiveStreamMode.configuration,
      targetSerial: source == .local ? selectedLocalID : nil,
      audioEnabled: developer.audioEnabled, audioVolume: developer.playbackVolume)
    let mailbox = LatestFrameMailbox<PendingVideoFrame>()
    captureMailbox = mailbox
    self.session = session
    let targetScope =
      source == .local
      ? "local:\(selectedLocalID)"
      : "server:\(profile ?? ""):\(activeDeviceID.isEmpty ? selectedDeviceID : activeDeviceID)"
    let targetName = deviceTitle
    let recording = developer.recording
    session.onEncodedFrame = { recording.consumeVideo($0) }
    session.onAudioFrame = { recording.consumeAudio($0, timestamp: $1) }
    session.onTarget = { [weak self, weak session] serial in
      DispatchQueue.main.async {
        guard let self, self.session === session else { return }
        self.localSerial = serial
        self.developer.configure(
          cli: cli, directory: self.workingDirectory,
          target: DeveloperTarget(serial: serial, scope: targetScope, name: targetName))
      }
    }
    session.onAudioState = { [weak self, weak session] text in
      DispatchQueue.main.async {
        guard let self, self.session === session else { return }
        self.developer.audioStatus = text
      }
    }
    session.onProfile = { [weak self, weak session] profile in
      DispatchQueue.main.sync {
        guard let self, self.session === session else { return }
        self.profile = profile
      }
    }
    session.onClipboard = { [weak self, weak session] text in
      DispatchQueue.main.async {
        guard let self, self.session === session else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        self.output = "Copied Android clipboard to the Mac."
      }
    }
    session.onState = { [weak self, weak session] text in
      DispatchQueue.main.async {
        guard let self, self.session === session else { return }
        self.state = text
      }
    }
    session.onIdentity = { [weak self, weak session] value in
      DispatchQueue.main.async {
        guard let self, self.session === session else { return }
        self.identity = value
      }
    }
    session.onFrame = { [weak self, weak session] sample in
      guard let session, !session.isCancelled else { return }
      let result = mailbox.offer(
        PendingVideoFrame(sample: sample, arrived: ProcessInfo.processInfo.systemUptime))
      if result.replaced { session.measurements.replaced() }
      guard result.schedule else { return }
      DispatchQueue.main.async { [weak self, weak session] in
        guard let self, let session, self.session === session, let pending = mailbox.take() else {
          return
        }
        if self.screen?.display(pending.sample) == true {
          session.measurements.delivered(
            waitMS: (ProcessInfo.processInfo.systemUptime - pending.arrived) * 1000)
        } else {
          session.measurements.replaced()
        }
        if !self.connected { self.connected = true }
        if self.connecting { self.connecting = false }
        self.attempts = 0
        if self.state != "Connected" { self.state = "Connected" }
      }
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self, weak session] in
      guard let session else { return }
      do { try session.stream() } catch {
        DispatchQueue.main.async {
          guard let self, self.session === session else { return }
          self.connected = false
          self.connecting = false
          self.screen?.reset()
          self.developer.detach()
          self.state = error.localizedDescription
          self.output = error.localizedDescription
          if self.autoReconnect && self.wantsConnection && !self.sleeping && self.attempts < 5 {
            self.attempts += 1
            let delay = min(15, self.attempts * 3)
            self.state = "\(error.localizedDescription) · Retry \(self.attempts)/5 in \(delay)s"
            self.retry = Task {
              try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
              guard !Task.isCancelled else { return }
              self.connect()
            }
          }
        }
      }
    }
  }
  private func closeCapture() {
    captures.cancelCapture()
    developer.detach()
    clearRotation()
    screen?.cancelTouches()
    retry?.cancel()
    retry = nil
    captureMailbox?.close()
    captureMailbox = nil
    session?.stop()
    session = nil
    screen?.reset()
    connected = false
    connecting = false
  }
  func disconnect() {
    wantsConnection = false
    closeCapture()
    state = "Viewer disconnected"
  }
  func shutdown() {
    developer.videoReview.editor?.shutdown()
    if let monitor = focusKeyMonitor { NSEvent.removeMonitor(monitor) }
    focusKeyMonitor = nil
    if let observer = focusFullscreenObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    focusFullscreenObserver = nil
    disconnect()
    actionSession?.stop()
    statusSession?.stop()
    wirelessSession?.stop()
    for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
  }
  func send(_ data: Data) { if connected { session?.send(data) } }
  func rotateDevice() {
    guard connected, interactive, !busy, rotationPresentation == nil else { return }
    screen?.cancelTouches()
    send(Data([11]))
  }
  func beginRotation(image: NSImage, videoSize: CGSize) {
    guard connected else { return }
    rotationTask?.cancel()
    screen?.cancelTouches()
    rotationRevealing = false
    rotationPresentation = DeviceRotationPresentation(
      image: image, displaySize: displaySize, videoSize: videoSize)
    let delay: UInt64 = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 480_000_000
    rotationTask = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: delay) } catch { return }
      guard let self, !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.12)) { self.rotationRevealing = true }
      do { try await Task.sleep(nanoseconds: 140_000_000) } catch { return }
      guard !Task.isCancelled else { return }
      self.rotationPresentation = nil
      self.rotationRevealing = false
      self.rotationTask = nil
    }
  }
  private func clearRotation() {
    rotationTask?.cancel()
    rotationTask = nil
    rotationPresentation = nil
    rotationRevealing = false
  }
  func key(_ code: UInt32) {
    send(ControlPacket.key(code, down: true))
    send(ControlPacket.key(code, down: false))
  }
  func toggleFocusMode() { setFocusMode(!focusMode) }
  func setFocusMode(_ enabled: Bool) {
    guard enabled != focusMode, !focusTransitioning, let window = viewerWindow ?? screen?.window
    else { return }
    if enabled && window.styleMask.contains(.fullScreen) {
      focusTransitioning = true
      focusFullscreenObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          if let observer = self.focusFullscreenObserver {
            NotificationCenter.default.removeObserver(observer)
          }
          self.focusFullscreenObserver = nil
          self.focusTransitioning = false
          self.setFocusMode(true)
        }
      }
      window.toggleFullScreen(nil)
      return
    }
    screen?.cancelTouches()
    if enabled {
      workspaceFrame = window.frame
      workspaceAutosaveName = window.frameAutosaveName
      if !workspaceAutosaveName.isEmpty { window.saveFrame(usingName: workspaceAutosaveName) }
      window.setFrameAutosaveName("")
      focusMode = true
      focusKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
        [weak self, weak window] event in
        guard let self, self.focusMode, self.captures.editor == nil,
          self.developer.videoReview.editor == nil, event.window === window,
          event.keyCode == 53,
          window?.attachedSheet == nil
        else { return event }
        self.setFocusMode(false)
        return nil
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.focusMode else { return }
        window.contentMinSize = NSSize(width: 220, height: 320)
        self.resizeFocusWindow()
      }
    } else {
      if let monitor = focusKeyMonitor { NSEvent.removeMonitor(monitor) }
      focusKeyMonitor = nil
      focusMode = false
      let savedFrame = workspaceFrame
      let savedAutosave = workspaceAutosaveName
      workspaceFrame = nil
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.focusMode else { return }
        window.contentMinSize = NSSize(width: self.showSidebar ? 810 : 460, height: 660)
        if let savedFrame {
          window.setFrame(
            savedFrame, display: true,
            animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        window.setFrameAutosaveName(savedAutosave)
      }
    }
  }
  func resizeFocusWindow() {
    guard focusMode, let window = viewerWindow ?? screen?.window else { return }
    let visible =
      (window.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    let framed = UserDefaults.standard.object(forKey: "studioFrame") as? Bool ?? true
    let layout = chassis.layout(
      videoWidth: displaySize.width, videoHeight: displaySize.height,
      availableWidth: 1000, availableHeight: 1000, framed: framed)
    let frame = FocusWindowGeometry.frame(
      deviceSize: CGSize(width: layout.width, height: layout.height),
      screen: visible, anchor: window.frame)
    window.setFrame(
      frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
  }
  func screenshot() {
    guard connected, !busy, !localSerial.isEmpty, let cli else { return }
    captures.onStatus = { [weak self] in self?.output = $0 }
    captures.capture(cli: cli, directory: workingDirectory, serial: localSerial)
  }
  func diagnostics() {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Logs/Okestra")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    NSWorkspace.shared.open(url)
  }
}

final class DeviceScreen: NSView {
  let displayLayer = AVSampleBufferDisplayLayer()
  weak var controller: DeviceController?
  var inputEnabled = true { didSet { if !inputEnabled { cancelTouches() } } }
  var videoSize = CGSize(width: 720, height: 1280)
  private var touching = false
  private var scrollPoint: CGPoint?
  private var scrollEnd: DispatchWorkItem?
  private var canvasPan: (start: CGPoint, origin: CGPoint)?
  private var lastPicture: CVPixelBuffer?
  override var acceptsFirstResponder: Bool { true }
  // The frameless video has no opaque chassis ancestor to stop background window dragging.
  // Always keep pointer drags on this native view available for Android touch input.
  override var mouseDownCanMoveWindow: Bool { false }
  override var isFlipped: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    displayLayer.videoGravity = .resizeAspect
    layer?.addSublayer(displayLayer)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    controller?.backingScale = window?.backingScaleFactor ?? 2
  }
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    controller?.backingScale = window?.backingScaleFactor ?? 2
  }
  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    displayLayer.frame = bounds
    CATransaction.commit()
  }
  @discardableResult func display(_ sample: CMSampleBuffer) -> Bool {
    guard let format = CMSampleBufferGetFormatDescription(sample) else { return false }
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    if dimensions.width > 0 && dimensions.height > 0 {
      let size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
      if (size.width > size.height) != (videoSize.width > videoSize.height),
        controller?.connected == true, let picture = lastPicture
      {
        var image: CGImage?
        if VTCreateCGImageFromCVPixelBuffer(picture, options: nil, imageOut: &image) == noErr,
          let image
        {
          controller?.beginRotation(
            image: NSImage(cgImage: image, size: videoSize), videoSize: videoSize)
        }
      }
      videoSize = size
      if controller?.renderedSize != size { controller?.renderedSize = size }
    }
    if #available(macOS 14.0, *) {
      let renderer = displayLayer.sampleBufferRenderer
      if renderer.status == .failed {
        renderer.flush(removingDisplayedImage: false, completionHandler: nil)
        controller?.send(Data([17]))
      }
      guard renderer.isReadyForMoreMediaData else { return false }
      renderer.enqueue(sample)
    } else {
      if displayLayer.status == .failed {
        displayLayer.flush()
        controller?.send(Data([17]))
      }
      guard displayLayer.isReadyForMoreMediaData else { return false }
      displayLayer.enqueue(sample)
    }
    lastPicture = CMSampleBufferGetImageBuffer(sample)
    return true
  }
  func reset() {
    lastPicture = nil
    scrollEnd?.cancel()
    scrollEnd = nil
    touching = false
    scrollPoint = nil
    if #available(macOS 14.0, *) {
      displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    } else {
      displayLayer.flushAndRemoveImage()
    }
  }
  func point(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
    let p = convert(event.locationInWindow, from: nil)
    let (x, y, w, h) = ScreenGeometry.fitted(
      containerWidth: bounds.width, containerHeight: bounds.height, videoWidth: videoSize.width,
      videoHeight: videoSize.height)
    guard w > 0, h > 0, clamp || CGRect(x: x, y: y, width: w, height: h).contains(p) else {
      return nil
    }
    return CGPoint(
      x: min(videoSize.width - 1, max(0, (p.x - x) * videoSize.width / w)),
      y: min(videoSize.height - 1, max(0, (p.y - y) * videoSize.height / h)))
  }
  private func touch(_ action: UInt8, _ p: CGPoint) {
    controller?.send(
      ControlPacket.touch(
        action: action, x: Int(p.x), y: Int(p.y), width: Int(videoSize.width),
        height: Int(videoSize.height)))
  }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    if event.modifierFlags.contains(.option), let scroll = enclosingScrollView {
      cancelTouches()
      canvasPan = (event.locationInWindow, scroll.contentView.bounds.origin)
      NSCursor.closedHand.push()
      return
    }
    guard inputEnabled, let p = point(event) else { return }
    touching = true
    touch(0, p)
  }
  override func mouseDragged(with event: NSEvent) {
    if let pan = canvasPan, let scroll = enclosingScrollView {
      let delta = CGPoint(
        x: event.locationInWindow.x - pan.start.x, y: event.locationInWindow.y - pan.start.y)
      let origin = CGPoint(
        x: pan.origin.x - delta.x,
        y: pan.origin.y + (scroll.documentView?.isFlipped == true ? delta.y : -delta.y))
      let bounds = scroll.contentView.constrainBoundsRect(
        CGRect(origin: origin, size: scroll.contentView.bounds.size))
      scroll.contentView.scroll(to: bounds.origin)
      scroll.reflectScrolledClipView(scroll.contentView)
      return
    }
    if inputEnabled, touching, let p = point(event, clamp: true) { touch(2, p) }
  }
  override func mouseUp(with event: NSEvent) {
    if canvasPan != nil {
      canvasPan = nil
      NSCursor.pop()
      return
    }
    if inputEnabled, touching, let p = point(event, clamp: true) { touch(1, p) }
    touching = false
  }
  override func rightMouseDown(with event: NSEvent) { if inputEnabled { controller?.key(4) } }
  override func scrollWheel(with event: NSEvent) {
    if event.modifierFlags.contains(.option), let scroll = enclosingScrollView {
      scroll.scrollWheel(with: event)
      return
    }
    guard inputEnabled else { return }
    guard let p = point(event) else { return }
    scrollEnd?.cancel()
    if scrollPoint == nil {
      scrollPoint = p
      touch(0, p)
    }
    if var position = scrollPoint {
      position.y = min(videoSize.height - 1, max(0, position.y + event.scrollingDeltaY * 4))
      position.x = min(videoSize.width - 1, max(0, position.x + event.scrollingDeltaX * 4))
      scrollPoint = position
      touch(2, position)
    }
    let end = DispatchWorkItem { [weak self] in
      guard let self, let p = self.scrollPoint else { return }
      self.touch(1, p)
      self.scrollPoint = nil
    }
    scrollEnd = end
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: end)
  }
  override func keyDown(with event: NSEvent) {
    if let video = controller?.developer.videoReview.editor {
      if event.keyCode == 53 { video.requestClose() }
      return
    }
    if let editor = controller?.captures.editor {
      if event.keyCode == 53 { editor.requestClose() }
      return
    }
    if event.keyCode == 53, controller?.focusMode == true {
      controller?.setFocusMode(false)
      return
    }
    guard inputEnabled else { return }
    if event.modifierFlags.contains(.command) {
      if event.charactersIgnoringModifiers == "v",
        let text = NSPasteboard.general.string(forType: .string)
      {
        controller?.send(ControlPacket.paste(text))
      }
      return
    }
    let keys: [UInt16: UInt32] = [
      36: 66, 51: 67, 48: 61, 53: 4, 123: 21, 124: 22, 125: 20, 126: 19, 117: 112,
    ]
    if let key = keys[event.keyCode] {
      controller?.key(key)
    } else if let text = event.characters, !text.isEmpty {
      controller?.send(ControlPacket.text(text))
    }
  }
  func cancelTouches() {
    if canvasPan != nil {
      canvasPan = nil
      NSCursor.pop()
    }
    if touching || scrollPoint != nil {
      controller?.send(
        ControlPacket.touch(
          action: 3, x: 0, y: 0, width: Int(videoSize.width), height: Int(videoSize.height)))
    }
    touching = false
    scrollEnd?.cancel()
    scrollEnd = nil
    scrollPoint = nil
  }
  override func resignFirstResponder() -> Bool {
    cancelTouches()
    return true
  }
  @objc func paste(_ sender: Any?) {
    guard inputEnabled else { return }
    if let text = NSPasteboard.general.string(forType: .string) {
      controller?.send(ControlPacket.paste(text))
    }
  }
}
struct DeviceSurface: NSViewRepresentable {
  @ObservedObject var controller: DeviceController
  var cornerRadius: CGFloat = 2
  func makeNSView(context: Context) -> DeviceScreen {
    let view = DeviceScreen()
    view.layer?.cornerRadius = cornerRadius
    view.layer?.masksToBounds = true
    view.controller = controller
    controller.screen = view
    return view
  }
  func updateNSView(_ nsView: DeviceScreen, context: Context) {
    nsView.layer?.cornerRadius = cornerRadius
    nsView.controller = controller
    nsView.inputEnabled = controller.interactive && controller.rotationPresentation == nil
    controller.screen = nsView
  }
}

final class DeviceAppDelegate: NSObject, NSApplicationDelegate {
  var controller: DeviceController?
  private var awaitingRecordingTermination = false
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if let video = controller?.developer.videoReview.editor, video.hasPendingWork {
      video.requestClose { [weak controller] in
        controller?.developer.videoReview.editor?.onClose()
        DispatchQueue.main.async { sender.terminate(nil) }
      }
      return .terminateCancel
    }
    if let editor = controller?.captures.editor,
      editor.needsExport || editor.exporting || editor.draft != nil
    {
      editor.requestClose { [weak controller] in
        controller?.captures.editor?.onClose()
        DispatchQueue.main.async { sender.terminate(nil) }
      }
      return .terminateCancel
    }
    guard let tools = controller?.developer, tools.isRecording else { return .terminateNow }
    if !awaitingRecordingTermination {
      awaitingRecordingTermination = true
      tools.recording.stop()
      Task { @MainActor in
        // Finalize the movie before the process exits, including when the last
        // window closes while the recording writer is still flushing to disk.
        while tools.isRecording { try? await Task.sleep(nanoseconds: 50_000_000) }
        sender.reply(toApplicationShouldTerminate: true)
      }
    }
    return .terminateLater
  }
  func applicationWillTerminate(_ notification: Notification) { controller?.shutdown() }
}
@main
struct OkestraDeviceApp: App {
  @StateObject private var controller = DeviceController()
  @NSApplicationDelegateAdaptor(DeviceAppDelegate.self) var delegate
  var body: some Scene {
    Window("Okestra Device", id: "device") {
      DeviceWindow(model: controller).onAppear { delegate.controller = controller }
    }.defaultSize(width: 1120, height: 880).windowStyle(.hiddenTitleBar)
      .commands {
        DeviceDeveloperCommands(model: controller, tools: controller.developer)
        CommandGroup(replacing: .newItem) {
          ScreenshotOpenCommand(captures: controller.captures, window: { controller.viewerWindow })
          OpenRecordingCommand(
            reviews: controller.developer.videoReview, window: { controller.viewerWindow })
          Divider()
          Button("Refresh device profiles") { controller.loadServers() }.keyboardShortcut("o")
          Button("Reconnect") { controller.connect(reset: true) }.keyboardShortcut("r")
        }
        CommandGroup(after: .windowArrangement) {
          Toggle("Always on Top", isOn: $controller.alwaysOnTop)
          Button(controller.focusMode ? "Exit Focus Mode" : "Enter Focus Mode") {
            controller.toggleFocusMode()
          }
          .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(
            controller.focusTransitioning)
          Button("Show or hide sidebar") { controller.showSidebar.toggle() }
            .keyboardShortcut("s", modifiers: [.command, .control]).disabled(controller.focusMode)
          ShowToolsCommand()
        }
      }
    Window("Device Tools", id: "tools") {
      DeviceToolsWindow(model: controller)
    }.defaultSize(width: 340, height: 670).defaultPosition(.trailing).windowStyle(.hiddenTitleBar)
  }
}

private struct PendingVideoFrame: @unchecked Sendable {
  let sample: CMSampleBuffer
  let arrived: Double
}
