import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct DeveloperTarget: Equatable, Sendable {
  let serial: String
  let scope: String
  let name: String
}
enum DeveloperTab: String, CaseIterable, Identifiable {
  case apps = "Apps"
  case logs = "Logs"
  case links = "Links & ports"
  case capture = "Capture"
  var id: String { rawValue }
}

@MainActor
final class DeveloperController: ObservableObject {
  @Published var showTools = false
  @Published var showPalette = false
  @Published var tab = DeveloperTab.apps
  @Published private(set) var target: DeveloperTarget?
  @Published private(set) var apps: [String] = []
  @Published var presets = DeviceDeveloperPresets()
  @Published private(set) var operationBusy = false
  @Published var status = "Connect a device to use developer tools."
  @Published private(set) var failed = false
  @Published private(set) var logs: [DeviceLogEntry] = []
  @Published private(set) var crashes: [DeviceLogEntry] = []
  @Published private(set) var unreadCrash = false
  @Published private(set) var logsRunning = false
  @Published var logStatus = "Logs are stopped."
  @Published var logQuery = ""
  @Published var minimumLogLevel = "V"
  @Published var appLogsOnly = true
  @Published private(set) var appPIDs: Set<Int> = []
  @Published private(set) var activePorts: [Int: String] = [:]
  @Published private(set) var isRecording = false
  @Published var recordingStatus = "Recording is stopped."
  @Published private(set) var lastRecording: URL?
  @Published var reportNotes = ""
  @Published var includeRecordingInReport = true
  @Published private(set) var audioEnabled = UserDefaults.standard.bool(
    forKey: "deviceAudioEnabled")
  @Published var audioMuted = UserDefaults.standard.bool(forKey: "deviceAudioMuted") {
    didSet {
      UserDefaults.standard.set(audioMuted, forKey: "deviceAudioMuted")
      onVolumeChange(playbackVolume)
    }
  }
  @Published var audioVolume =
    UserDefaults.standard.object(forKey: "deviceAudioVolume") as? Double ?? 1
  {
    didSet {
      UserDefaults.standard.set(audioVolume, forKey: "deviceAudioVolume")
      onVolumeChange(playbackVolume)
    }
  }
  @Published var audioStatus = "Audio routing is off."
  var playbackVolume: Float { audioMuted ? 0 : Float(min(1, max(0, audioVolume))) }
  var onAudioChange: () -> Void = {}
  var onRecordingStart: () -> Void = {}
  var onVolumeChange: (Float) -> Void = { _ in }
  var reportContext: () -> [String: String] = { [:] }
  let recording = DeviceRecording()
  let videoReview = VideoReviewController()
  let network = DeviceNetworkController()
  let battery = DeviceBatteryController()
  private var cli = "", directory = "", scope = ""
  private var store = DeveloperPresetStore()
  private var storeLoadFailed = false
  private var operation: DeveloperDeviceSession?
  private var generation = UUID()
  private var logGeneration = UUID()
  private var logStream: DeviceLogStream?
  private var logOperation: DeveloperDeviceSession?
  private var pidTask: Task<Void, Never>?
  private var wantsLogs = false
  private var buffer = DeviceLogBuffer()
  private var recordingScope = ""
  private var lastRecordingScope = ""
  private var storeURL: URL {
    URL(fileURLWithPath: directory).appendingPathComponent("developer-presets.json")
  }
  init() {
    recording.onState = { [weak self] active, message, url in
      DispatchQueue.main.async {
        guard let self else { return }
        self.isRecording = active
        self.recordingStatus = message
        if let url {
          self.lastRecording = url
          self.lastRecordingScope = self.recordingScope
          self.showTools = false
          self.showPalette = false
          self.videoReview.recorded(url)
        }
      }
    }
  }
  func configure(cli: String, directory: String, target: DeveloperTarget) {
    guard self.target != target else { return }
    detach()
    self.cli = cli
    self.directory = directory
    self.target = target
    if scope != target.scope {
      buffer.clear()
      logs = []
      crashes = []
      unreadCrash = false
      apps = []
      appPIDs = []
      activePorts = [:]
      scope = target.scope
    }
    do {
      store = try DeveloperPresetStore.load(from: storeURL)
      storeLoadFailed = false
      presets = store.devices[scope] ?? DeviceDeveloperPresets()
      status = "Developer tools connected to \(target.name)."
      failed = false
    } catch {
      storeLoadFailed = true
      presets = DeviceDeveloperPresets()
      fail(
        "Could not load saved links and ports: \(error.localizedDescription). Your settings file was left unchanged."
      )
    }
    network.start(cli: cli, directory: directory, serial: target.serial)
    battery.start(cli: cli, directory: directory, serial: target.serial)
    refreshApps()
    if wantsLogs { startLogs() }
  }
  func detach() {
    network.stop()
    battery.stop()
    generation = UUID()
    operation?.stop()
    operation = nil
    operationBusy = false
    stopLogs(preserveIntent: true)
    recording.stop(note: "Device stream ended.")
    target = nil
    activePorts = [:]
    audioStatus = audioEnabled ? "Audio waits for the device connection." : "Audio routing is off."
  }
  func open(_ selectedTab: DeveloperTab) {
    tab = selectedTab
    if selectedTab == .logs { unreadCrash = false }
    showPalette = false
    DispatchQueue.main.async { self.showTools = true }
  }
  func openPalette() {
    if showTools {
      showTools = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.showPalette = true }
    } else {
      showPalette = true
    }
  }
  func setAudioEnabled(_ enabled: Bool) {
    guard enabled != audioEnabled, !isRecording else { return }
    audioEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: "deviceAudioEnabled")
    audioStatus = enabled ? "Connecting Android audio…" : "Audio routing is off."
    onAudioChange()
  }
  func fail(_ text: String) {
    status = text
    failed = true
  }
  private func savePresets() {
    guard !scope.isEmpty, !directory.isEmpty else {
      fail("Connect a device before saving presets.")
      return
    }
    guard !storeLoadFailed else {
      fail(
        "Saved settings could not be read. Restore developer-presets.json before editing presets.")
      return
    }
    store.devices[scope] = presets
    do {
      try store.save(to: storeURL)
      failed = false
      status = "Saved device presets."
    } catch { fail("Could not save presets: \(error.localizedDescription)") }
  }
  func selectApp(_ package: String) {
    presets.selectedPackage = package
    appPIDs = []
    savePresets()
  }
  private func perform<T: Sendable>(
    _ title: String,
    work: @escaping @Sendable (DeveloperDeviceSession) throws -> T,
    done: @escaping (T) -> Void
  ) {
    guard !operationBusy else { return }
    guard let target else {
      fail("Connect a device first.")
      return
    }
    let stamp = generation
    let session = DeveloperDeviceSession(cli: cli, directory: directory, serial: target.serial)
    operation = session
    operationBusy = true
    status = title
    failed = false
    Task {
      do {
        let value = try await Task.detached(priority: .userInitiated) { try work(session) }.value
        guard generation == stamp, operation === session else { return }
        operationBusy = false
        operation = nil
        done(value)
      } catch {
        guard generation == stamp, operation === session else { return }
        operationBusy = false
        operation = nil
        fail(error.localizedDescription)
      }
    }
  }
  func cancelOperation() {
    generation = UUID()
    operation?.stop()
    operation = nil
    operationBusy = false
    status = "Operation cancelled. Android may finish an installation already submitted."
  }
  func refreshApps() {
    perform("Loading installed apps…", work: { try $0.applications() }) { apps in
      self.apps = apps
      self.status = "\(apps.count) installed apps."
      if !self.presets.selectedPackage.isEmpty && !apps.contains(self.presets.selectedPackage) {
        self.selectApp("")
      }
    }
  }
  func launchApp(restart: Bool = false) {
    let package = presets.selectedPackage
    perform(
      restart ? "Restarting app…" : "Launching app…",
      work: {
        restart ? try $0.restart(package) : try $0.launch(package)
      }
    ) { self.status = $0 }
  }
  func clearAppData() {
    let package = presets.selectedPackage
    perform("Clearing app storage…", work: { try $0.clearData(package) }) { self.status = $0 }
  }
  func chooseAPK() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.message = "Install APK files on the selected Android device."
    if panel.runModal() == .OK { install(panel.urls) }
  }
  func install(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    open(.apps)
    guard urls.allSatisfy({ $0.isFileURL && $0.pathExtension.lowercased() == "apk" }) else {
      fail("Drop APK files to install them on the selected device.")
      return
    }
    let stamp = generation
    perform(
      "Installing \(urls.count) APK\(urls.count == 1 ? "" : "s")…",
      work: { session in
        var results: [String] = []
        for (index, url) in urls.enumerated() {
          DispatchQueue.main.async {
            if self.generation == stamp {
              self.status = "Installing \(index + 1)/\(urls.count): \(url.lastPathComponent)…"
            }
          }
          do { results.append(try session.install(url)) } catch {
            throw DeviceError.message(
              (results + ["\(url.lastPathComponent): \(error.localizedDescription)"]).joined(
                separator: "\n"))
          }
        }
        return (results.joined(separator: "\n"), try session.applications())
      }
    ) { result in
      self.status = result.0
      self.apps = result.1
    }
  }
  func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
    open(.apps)
    guard target != nil, !operationBusy else {
      fail("Connect a device before installing an APK.")
      return false
    }
    let stamp = generation
    let group = DispatchGroup()
    let collector = DroppedAPKFiles()
    for provider in providers {
      group.enter()
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
        defer { group.leave() }
        if let url = value as? URL {
          collector.append(url)
        } else if let data = value as? Data,
          let url = URL(dataRepresentation: data, relativeTo: nil)
        {
          collector.append(url)
        }
      }
    }
    group.notify(queue: .main) {
      guard self.generation == stamp else { return }
      let urls = collector.urls
      if urls.count != providers.count {
        self.fail("Could not read the dropped files.")
      } else {
        self.install(urls)
      }
    }
    return true
  }
  func addLink(name: String, url: String, package: String) {
    do {
      guard presets.links.count < 100 else {
        throw DeviceError.message("A device can have up to 100 saved links.")
      }
      presets.links.append(try SavedDeviceLink(name: name, url: url, package: package))
      savePresets()
    } catch { fail(error.localizedDescription) }
  }
  func removeLink(_ id: UUID) {
    presets.links.removeAll { $0.id == id }
    savePresets()
  }
  func openLink(_ link: SavedDeviceLink) {
    perform("Opening \(link.name)…", work: { try $0.open(link) }) { self.status = $0 }
  }
  func addPort(name: String, device: String, mac: String) {
    do {
      let value = try SavedDevicePort(name: name, devicePort: device, macPort: mac)
      guard presets.ports.count < 100,
        !presets.ports.contains(where: { $0.devicePort == value.devicePort })
      else {
        throw DeviceError.message(
          "A mapping already uses that device port, or the preset limit was reached.")
      }
      presets.ports.append(value)
      savePresets()
    } catch { fail(error.localizedDescription) }
  }
  func forgetPort(_ port: SavedDevicePort) {
    guard activePorts[port.devicePort] == nil else {
      fail("Disconnect the port mapping before removing its preset.")
      return
    }
    presets.ports.removeAll { $0.id == port.id }
    savePresets()
  }
  func refreshPorts() {
    perform("Checking port mappings…", work: { try $0.mappings() }) {
      self.activePorts = $0
      self.status = "Port mappings refreshed."
    }
  }
  func applyPort(_ port: SavedDevicePort, remove: Bool = false) {
    perform(
      remove ? "Disconnecting \(port.name)…" : "Connecting \(port.name)…",
      work: { session in
        let result = remove ? try session.remove(port) : try session.apply(port)
        return (result, try session.mappings())
      }
    ) {
      self.status = $0.0
      self.activePorts = $0.1
    }
  }
  var filteredLogs: [DeviceLogEntry] {
    logs.filter {
      $0.matches(
        package: appLogsOnly ? presets.selectedPackage : "", pids: appPIDs,
        query: logQuery, minimum: minimumLogLevel)
    }
  }
  func startLogs() {
    wantsLogs = true
    guard !logsRunning, let target else {
      logStatus = "Connect a device to start logs."
      return
    }
    let stamp = UUID()
    logGeneration = stamp
    let stream = DeviceLogStream()
    let mailbox = DeviceLogMailbox()
    let operation = DeveloperDeviceSession(cli: cli, directory: directory, serial: target.serial)
    logStream = stream
    logOperation = operation
    logsRunning = true
    logStatus = "Starting Logcat…"
    Task {
      do {
        try await Task.detached {
          let adb = try operation.adbPath()
          try stream.start(
            adb: adb, serial: target.serial,
            onLines: { lines in
              guard mailbox.offer(lines) else { return }
              DispatchQueue.main.async {
                guard self.logGeneration == stamp else { return }
                let lines = mailbox.take()
                let package = self.presets.selectedPackage
                if !package.isEmpty {
                  for entry in lines.map(DeviceLogEntry.init)
                  where entry.text.contains("Process: " + package) {
                    if let pid = entry.pid { self.appPIDs.insert(pid) }
                  }
                }
                let crashes = self.buffer.append(lines)
                self.logs = self.buffer.entries
                self.crashes = Array((self.crashes + crashes).suffix(40))
                if !crashes.isEmpty && !(self.showTools && self.tab == .logs) {
                  if package.isEmpty
                    || crashes.contains(where: {
                      $0.matches(package: package, pids: self.appPIDs, query: "", minimum: "V")
                    })
                  {
                    self.unreadCrash = true
                  }
                }
                self.logStatus = "Live · \(self.logs.count) buffered lines"
              }
            },
            onExit: { message in
              DispatchQueue.main.async {
                guard self.logGeneration == stamp else { return }
                self.logsRunning = false
                self.logStatus = message
              }
            })
        }.value
        guard logGeneration == stamp else {
          stream.stop()
          return
        }
        logStatus = "Live Logcat"
        pidTask = Task {
          while !Task.isCancelled && self.logGeneration == stamp {
            let package = self.presets.selectedPackage
            if !package.isEmpty {
              let pids = try? await Task.detached {
                try operation.shell(["pidof", AndroidTooling.package(package)], timeout: 5)
              }.value
              guard self.logGeneration == stamp else { return }
              if self.presets.selectedPackage == package {
                // Retain exited process IDs so its crash stack stays in the app filter.
                self.appPIDs.formUnion(
                  (pids ?? "").split(whereSeparator: \.isWhitespace).compactMap { Int($0) })
                if self.appPIDs.count > 100 { self.appPIDs = Set(self.appPIDs.sorted().suffix(50)) }
              }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
          }
        }
      } catch {
        guard logGeneration == stamp else { return }
        logsRunning = false
        logStatus = error.localizedDescription
      }
    }
  }
  func stopLogs(preserveIntent: Bool = false) {
    if !preserveIntent { wantsLogs = false }
    logGeneration = UUID()
    pidTask?.cancel()
    pidTask = nil
    logStream?.stop()
    logStream = nil
    logOperation?.stop()
    logOperation = nil
    logsRunning = false
    logStatus = "Logs are stopped."
  }
  func clearLogs() {
    buffer.clear()
    logs = []
    crashes = []
    unreadCrash = false
  }
  func copyLogs() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(
      filteredLogs.map(\.text).joined(separator: "\n"), forType: .string)
  }
  func toggleRecording() {
    if isRecording {
      recording.stop()
      return
    }
    guard target != nil else {
      fail("Connect a device first.")
      return
    }
    do {
      let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Movies/Okestra/Recordings", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
      let url = folder.appendingPathComponent(
        "Okestra \(formatter.string(from: Date())) \(UUID().uuidString.prefix(8)).mov")
      recordingScope = scope
      try recording.start(url: url, audio: audioEnabled)
      isRecording = true
      onRecordingStart()
    } catch { recordingStatus = error.localizedDescription }
  }
  func revealRecording() {
    if let lastRecording { NSWorkspace.shared.activateFileViewerSelecting([lastRecording]) }
  }
  func exportReport() {
    guard target != nil, !operationBusy else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.zip]
    panel.nameFieldStringValue = "Okestra Bug Report.zip"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    let text = filteredLogs.map(\.text).joined(separator: "\n")
    var context = reportContext()
    context["app_package"] = presets.selectedPackage
    context["created_at"] = ISO8601DateFormatter().string(from: Date())
    let metadata = context
    let notes = reportNotes
    let package = presets.selectedPackage
    let recording = includeRecordingInReport && lastRecordingScope == scope ? lastRecording : nil
    perform(
      "Collecting bug report…",
      work: { session in
        try DeveloperBugReport.export(
          session: session, destination: destination,
          context: metadata, package: package, notes: notes, logs: text, recording: recording)
        return destination
      }
    ) { url in
      self.status = "Saved bug report to \(url.lastPathComponent)."
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }
}

private final class DroppedAPKFiles: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [URL] = []
  func append(_ url: URL) {
    lock.lock()
    values.append(url)
    lock.unlock()
  }
  var urls: [URL] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}
