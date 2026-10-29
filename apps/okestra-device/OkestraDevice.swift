import AVFoundation
import AppKit
import Combine
import SwiftUI

@MainActor
final class DeviceController: ObservableObject {
  @Published var folder = UserDefaults.standard.string(forKey: "projectFolder") ?? ""
  @Published var profile: String?
  @Published var state = "Choose a mobile project"
  @Published var framework = "flutter"
  @Published var appState = "stopped"
  private var refreshingSession = false
  @Published var connected = false
  @Published var connecting = false
  @Published var busy = false
  @Published var output = ""
  @Published var avd = "okestra-pixel"
  @Published var autoReconnect = true
  @Published var syncOnSave = false
  weak var screen: DeviceScreen?
  private var session: DeviceSession?
  private var retry: Task<Void, Never>?
  private var attempts = 0
  private var wantsConnection = false
  private var sleeping = false
  private var observers: [NSObjectProtocol] = []
  private var actionSession: DeviceSession?
  private var statusSession: DeviceSession?
  var cli: String? {
    let candidates = [
      Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/okestra").path,
      "/opt/homebrew/bin/okestra", "/usr/local/bin/okestra",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
  init() {
    let args = ProcessInfo.processInfo.arguments
    if let i = args.firstIndex(of: "--project"), i + 1 < args.count { folder = args[i + 1] }
    if let i = args.firstIndex(of: "--profile"), i + 1 < args.count { profile = args[i + 1] }
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
  func choose() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.message = "Choose the Flutter or Expo development-build project containing okestra.json"
    if panel.runModal() == .OK, let url = panel.url { open(folder: url.path, profile: profile) }
  }
  func open(folder: String, profile: String?) {
    disconnect()
    actionSession?.stop()
    statusSession?.stop()
    statusSession = nil
    refreshingSession = false
    busy = false
    self.folder = folder
    self.profile = profile
    syncOnSave = false
    UserDefaults.standard.set(folder, forKey: "projectFolder")
    state = "Project selected"
    output = ""
    connect(reset: true)
  }
  func openURL(_ url: URL) {
    guard url.scheme == "okestra-device", url.host == "open",
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
      let path = items.first(where: { $0.name == "project" })?.value, path.hasPrefix("/")
    else { return }
    open(folder: path, profile: items.first(where: { $0.name == "profile" })?.value)
  }
  func connect(reset: Bool = false) {
    loadProjectFramework()
    guard !folder.isEmpty, !sleeping else { return }
    closeCapture()
    wantsConnection = true
    if reset { attempts = 0 }
    guard let cli else {
      state = "Reinstall Okestra Device: its CLI is missing"
      return
    }
    guard FileManager.default.fileExists(atPath: folder + "/okestra.json") else {
      state = "Configure this project first"
      return
    }
    connecting = true
    state = "Connecting…"
    let session = DeviceSession(cli: cli, folder: folder, profile: profile)
    self.session = session
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
    session.onFrame = { [weak self, weak session] sample in
      DispatchQueue.main.sync {
        guard let self, self.session === session else { return }
        self.screen?.display(sample)
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
    screen?.cancelTouches()
    retry?.cancel()
    retry = nil
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
    disconnect()
    actionSession?.stop()
    statusSession?.stop()
    for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
  }
  func send(_ data: Data) { if connected { session?.send(data) } }
  func key(_ code: UInt32) {
    send(ControlPacket.key(code, down: true))
    send(ControlPacket.key(code, down: false))
  }
  func action(_ name: String) {
    guard !busy, let cli, !folder.isEmpty else { return }
    busy = true
    let operation = DeviceSession(cli: cli, folder: folder, profile: profile)
    actionSession = operation
    var args = ["android", name]
    if name == "init" { args += ["--avd", avd, "--framework", framework] }
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
        if name == "watch" { syncOnSave = true }
        if name == "unwatch" { syncOnSave = false }
        if name == "start" { connect(reset: true) }
        if name == "init" { state = "Project configured. Start the device to continue." }
      }
    }
  }

  func loadProjectFramework() {
    guard !folder.isEmpty else { return }
    if let data = try? Data(contentsOf: URL(fileURLWithPath: folder + "/okestra.json")),
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let android = object["android"] as? [String: Any]
    {
      framework = android["framework"] as? String ?? "flutter"
    } else if let data = try? Data(contentsOf: URL(fileURLWithPath: folder + "/package.json")),
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let dependencies = object["dependencies"] as? [String: Any], dependencies["expo"] != nil
    {
      framework = "expo"
    }
  }
  func refreshSessionStatus() {
    guard !refreshingSession, !folder.isEmpty, let cli else { return }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: folder + "/okestra.json")),
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let name = object["name"] as? String
    else { return }
    refreshingSession = true
    let currentFolder = folder
    let currentProfile = profile
    let operation = DeviceSession(cli: cli, folder: folder, profile: profile)
    statusSession = operation
    Task {
      let data = try? await Task.detached {
        try operation.invoke(
          cli, operation.cliArguments(["android", "status", "--json"]), timeout: 15)
      }.value
      guard statusSession === operation else { return }
      statusSession = nil
      refreshingSession = false
      guard folder == currentFolder, profile == currentProfile, let data,
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let sessions = object["sessions"] as? [String: String]
      else { return }
      let value = sessions[name] ?? "stopped"
      if appState != value { appState = value }
    }
  }
  func screenshot() {
    guard connected, !busy, let cli else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Okestra Android.png"
    panel.allowedContentTypes = [.png]
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    busy = true
    let folder = self.folder
    let profile = self.profile
    let operation = DeviceSession(cli: cli, folder: folder, profile: profile)
    actionSession = operation
    Task {
      do {
        let bytes = try await Task.detached { () throws -> Data in
          let status = try operation.invoke(
            cli, operation.cliArguments(["android", "status", "--json"]))
          guard let obj = try JSONSerialization.jsonObject(with: status) as? [String: Any],
            let serial = obj["local_serial"] as? String, !serial.isEmpty
          else { throw DeviceError.message("Device disconnected") }
          let adb = String(
            decoding: try operation.invoke(cli, ["android", "adb-path"]), as: UTF8.self
          ).trimmingCharacters(in: .whitespacesAndNewlines)
          return try operation.invoke(adb, ["-s", serial, "exec-out", "screencap", "-p"])
        }.value
        guard bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
          throw DeviceError.message("Device did not return a PNG screenshot")
        }
        try bytes.write(to: destination, options: .atomic)
        output = "Saved screenshot to \(destination.path)"
      } catch { output = error.localizedDescription }
      if actionSession === operation {
        busy = false
        actionSession = nil
      }
    }
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
  var videoSize = CGSize(width: 720, height: 1280)
  private var touching = false
  private var scrollPoint: CGPoint?
  private var scrollEnd: DispatchWorkItem?
  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    displayLayer.videoGravity = .resizeAspect
    layer?.addSublayer(displayLayer)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    displayLayer.frame = bounds
    CATransaction.commit()
  }
  func display(_ sample: CMSampleBuffer) {
    guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    if dimensions.width > 0 && dimensions.height > 0 {
      videoSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
    }
    if #available(macOS 14.0, *) {
      let renderer = displayLayer.sampleBufferRenderer
      if renderer.status == .failed {
        renderer.flush(removingDisplayedImage: false, completionHandler: nil)
        controller?.send(Data([17]))
      }
      renderer.enqueue(sample)
    } else {
      if displayLayer.status == .failed {
        displayLayer.flush()
        controller?.send(Data([17]))
      }
      displayLayer.enqueue(sample)
    }
  }
  func reset() {
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
    guard let p = point(event) else { return }
    touching = true
    touch(0, p)
  }
  override func mouseDragged(with event: NSEvent) {
    if touching, let p = point(event, clamp: true) { touch(2, p) }
  }
  override func mouseUp(with event: NSEvent) {
    if touching, let p = point(event, clamp: true) { touch(1, p) }
    touching = false
  }
  override func rightMouseDown(with event: NSEvent) { controller?.key(4) }
  override func scrollWheel(with event: NSEvent) {
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
    if let text = NSPasteboard.general.string(forType: .string) {
      controller?.send(ControlPacket.paste(text))
    }
  }
}
struct DeviceSurface: NSViewRepresentable {
  @ObservedObject var controller: DeviceController
  func makeNSView(context: Context) -> DeviceScreen {
    let view = DeviceScreen()
    view.controller = controller
    controller.screen = view
    return view
  }
  func updateNSView(_ nsView: DeviceScreen, context: Context) {
    nsView.controller = controller
    controller.screen = nsView
  }
}

struct DeviceWindow: View {
  @ObservedObject var model: DeviceController
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "iphone").font(.title2).foregroundStyle(.green)
        VStack(alignment: .leading, spacing: 3) {
          Text("Okestra Device").font(.headline)
          Text(
            model.folder.isEmpty
              ? "Remote Android workspace" : URL(fileURLWithPath: model.folder).lastPathComponent
          ).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Choose project") { model.choose() }
        if model.connected {
          Button("Disconnect") { model.disconnect() }
        } else {
          Button(model.connecting ? "Reconnect" : "Connect") { model.connect(reset: true) }
            .disabled(model.folder.isEmpty)
        }
      }.padding(14)
      Divider()
      ZStack {
        Color.black
        DeviceSurface(controller: model)
        if !model.connected {
          VStack(spacing: 14) {
            Image(
              systemName: model.connecting ? "antenna.radiowaves.left.and.right" : "iphone.slash"
            ).font(.system(size: 36))
            Text(model.connecting ? "Connecting to Android" : "Device preview").font(
              .title3.weight(.semibold))
            Text(model.state).font(.callout).multilineTextAlignment(.center).frame(maxWidth: 420)
            if model.connecting { ProgressView().controlSize(.small) }
            HStack {
              Button("Check setup") { model.action("doctor") }.disabled(
                model.folder.isEmpty || model.busy)
              Button("Start device") { model.action("start") }.disabled(
                model.folder.isEmpty || model.busy)
            }
            if !model.folder.isEmpty
              && !FileManager.default.fileExists(atPath: model.folder + "/okestra.json")
            {
              VStack(spacing: 10) {
                Picker("Framework", selection: $model.framework) {
                  Text("Flutter").tag("flutter")
                  Text("Expo development build").tag("expo")
                }.frame(width: 270)
                HStack {
                  TextField("Installed AVD name", text: $model.avd).frame(width: 160)
                  Button("Configure project") { model.action("init") }
                }
              }
            }
          }.padding(28).foregroundStyle(.white)
        }
      }.frame(minWidth: 400, minHeight: 480)
      Divider()
      HStack(spacing: 18) {
        Button {
          model.key(4)
        } label: {
          Image(systemName: "chevron.backward")
        }.help("Back")
        Button {
          model.key(3)
        } label: {
          Image(systemName: "circle")
        }.help("Home")
        Button {
          model.key(187)
        } label: {
          Image(systemName: "square")
        }.help("Recent apps")
        Button {
          model.send(Data([11]))
        } label: {
          Image(systemName: "rotate.right")
        }.help("Rotate device")
        Spacer()
        Button {
          model.screenshot()
        } label: {
          Image(systemName: "camera")
        }.help("Save screenshot")
      }.buttonStyle(.borderless).disabled(!model.connected || model.busy).padding(12)
      HStack(spacing: 10) {
        Button("Run app") { model.action("run") }.disabled(
          ["installing", "building", "starting", "running", "stopping", "needs_rebuild"].contains(
            model.appState))
        Button("Reload") { model.action("reload") }
        Button(model.framework == "expo" ? "Rebuild" : "Restart") { model.action("restart") }
        Menu("More") {
          if model.framework == "expo" {
            Button("Open development menu") { model.action("dev-menu") }.disabled(
              model.appState != "running")
          }
          Button(model.syncOnSave ? "Stop sync on save" : "Enable sync on save") {
            model.action(model.syncOnSave ? "unwatch" : "watch")
          }
          Button("App logs") { model.action("logs") }
          Button("Device logs") { model.action("device-logs") }
          Button("Sync logs") { model.action("watch-logs") }
          Button("Check setup") { model.action("doctor") }.disabled(
            model.folder.isEmpty || model.busy)
          Button("Copy Android clipboard") { model.send(Data([8, 1])) }.disabled(!model.connected)
          Button("Paste Mac clipboard") {
            if let text = NSPasteboard.general.string(forType: .string) {
              model.send(ControlPacket.paste(text))
            }
          }.disabled(!model.connected)
          Button("Open viewer diagnostics") { model.diagnostics() }
          Toggle("Reconnect automatically", isOn: $model.autoReconnect)
          Divider()
          Button("Stop app") { model.action("stop") }
          Button("Stop device") {
            model.disconnect()
            model.action("device-stop")
          }
        }
        if model.busy { ProgressView().controlSize(.small) }
      }.disabled(model.folder.isEmpty || model.busy).padding(.horizontal, 12).padding(.bottom, 10)
      if !model.output.isEmpty {
        DisclosureGroup("Activity") {
          ScrollView {
            Text(model.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }.frame(height: 130)
        }.padding(.horizontal, 14).padding(.bottom, 10)
      }
      HStack {
        Circle().fill(model.connected ? Color.green : .orange).frame(width: 6, height: 6)
        Text(model.state).lineLimit(2)
        Spacer()
        Text("\(model.framework == "expo" ? "Expo" : "Flutter"): \(model.appState)")
          .foregroundStyle(.secondary)
      }.font(.caption2).padding(10).background(.bar)
    }.frame(minWidth: 500, minHeight: 700)
      .onAppear { if !model.folder.isEmpty { model.connect(reset: true) } }
      .onOpenURL { model.openURL($0) }
      .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
        model.refreshSessionStatus()
      }
  }
}

final class DeviceAppDelegate: NSObject, NSApplicationDelegate {
  var controller: DeviceController?
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationWillTerminate(_ notification: Notification) { controller?.shutdown() }
}
@main
struct OkestraDeviceApp: App {
  @StateObject private var controller = DeviceController()
  @NSApplicationDelegateAdaptor(DeviceAppDelegate.self) var delegate
  var body: some Scene {
    WindowGroup("Okestra Device") {
      DeviceWindow(model: controller).onAppear { delegate.controller = controller }
    }.defaultSize(width: 520, height: 880)
      .commands {
        CommandGroup(replacing: .newItem) {
          Button("Choose project…") { controller.choose() }.keyboardShortcut("o")
          Button("Reconnect") { controller.connect(reset: true) }.keyboardShortcut("r")
        }
      }
  }
}
