import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct DeviceScreenshot: Identifiable {
  let id = UUID()
  let image: NSImage
  let png: Data
  let file: URL
}

@MainActor
final class DeviceScreenshotController: ObservableObject {
  @Published private(set) var preview: DeviceScreenshot?
  @Published private(set) var capturing = false
  @Published private(set) var copied = false
  @Published private(set) var previewDismissing = false
  @Published private(set) var editor: ScreenshotEditorModel?
  private var operation: DeveloperDeviceSession?
  private var generation = UUID()
  private var dismissal: Task<Void, Never>?
  private var shutter: NSSound?
  var onStatus: (String) -> Void = { _ in }
  var allowsEditor: () -> Bool = { true }

  func capture(cli: String, directory: String, serial: String) {
    guard allowsEditor(), !capturing, editor == nil, !serial.isEmpty else { return }
    let operation = DeveloperDeviceSession(cli: cli, directory: directory, serial: serial)
    self.operation = operation
    let token = UUID()
    generation = token
    capturing = true
    Task {
      defer {
        if generation == token {
          capturing = false
          self.operation = nil
        }
      }
      do {
        let png = try await Task.detached {
          try operation.run(["exec-out", "screencap", "-p"], timeout: 15)
        }.value
        guard generation == token else { return }
        guard let image = NSImage(data: png), image.isValid else {
          throw DeviceError.message("Device did not return a valid screenshot.")
        }
        let folder = FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent("Pictures/Okestra/Screenshots", isDirectory: true)
        let file = try await Task.detached { try DeviceScreenshotStore.save(png, in: folder) }.value
        guard generation == token else { return }
        dismissal?.cancel()
        copied = false
        previewDismissing = false
        preview = DeviceScreenshot(image: image, png: png, file: file)
        let sounds =
          "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
        shutter =
          NSSound(contentsOfFile: sounds + "Shutter.aif", byReference: true)
          ?? NSSound(contentsOfFile: sounds + "Grab.aif", byReference: true)
        shutter?.play()
        onStatus("Saved screenshot to \(file.path)")
        dismissal = Task { [weak self = self] in
          // Allow the flight to finish, then hold the thumbnail for five seconds.
          try? await Task.sleep(nanoseconds: 5_550_000_000)
          guard !Task.isCancelled else { return }
          self?.dismiss()
        }
      } catch {
        if generation == token { onStatus("Screenshot failed: \(error.localizedDescription)") }
      }
    }
  }
  func cancelCapture() {
    generation = UUID()
    operation?.stop()
    operation = nil
    capturing = false
  }
  func dismiss() {
    dismissal?.cancel()
    guard let shot = preview else { return }
    let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.25
    withAnimation(.easeInOut(duration: duration)) { previewDismissing = true }
    dismissal = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
      guard !Task.isCancelled, let self, self.preview?.id == shot.id else { return }
      self.preview = nil
      self.previewDismissing = false
      self.dismissal = nil
    }
  }
  func openSavedScreenshot(in window: NSWindow?) {
    guard allowsEditor(), editor == nil, !capturing else { return }
    let panel = NSOpenPanel()
    panel.title = "Open Screenshot"
    panel.allowedContentTypes = [.png]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Pictures/Okestra/Screenshots", isDirectory: true)
    let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak window] response in
      guard response == .OK, let file = panel.url, let self, self.editor == nil else { return }
      do {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let image = try ScreenshotMarkupRenderer.source(data)
        self.openEditor(DeviceScreenshot(image: image, png: data, file: file))
      } catch {
        let alert = NSAlert(error: error)
        alert.messageText = "This screenshot could not be opened."
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
      }
    }
    if let window {
      panel.beginSheetModal(for: window, completionHandler: completion)
    } else {
      completion(panel.runModal())
    }
  }
  func openEditor(_ shot: DeviceScreenshot) {
    guard editor == nil else { return }
    do {
      let model = try ScreenshotEditorModel(shot: shot)
      model.onClose = { [weak self] in self?.editor = nil }
      dismissal?.cancel()
      dismissal = nil
      preview = nil
      previewDismissing = false
      editor = model
    } catch { onStatus("Could not open screenshot: \(error.localizedDescription)") }
  }
  func copy() {
    guard let preview else { return }
    if ScreenshotClipboard.write(preview.png) {
      copied = true
      onStatus("Screenshot copied to clipboard.")
    }
  }
}

struct DeviceScreenshotOverlay: View {
  @ObservedObject var captures: DeviceScreenshotController
  let focusMode: Bool
  var body: some View {
    if let shot = captures.preview {
      ScreenshotFlight(shot: shot, captures: captures, focusMode: focusMode).id(shot.id)
    }
  }
}

private struct ScreenshotFlight: View {
  let shot: DeviceScreenshot
  @ObservedObject var captures: DeviceScreenshotController
  let focusMode: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var docked = false
  @State private var controls = false
  var body: some View {
    GeometryReader { geometry in
      let ratio = shot.image.size.width / max(1, shot.image.size.height)
      let thumb = CGSize(width: min(156, 172 * ratio), height: min(172, 156 / ratio))
      let initialHeight = min(geometry.size.height * 0.65, geometry.size.width * 0.65 / ratio)
      let bottom = focusMode ? 14.0 : 122.0
      ZStack {
        // Only the thumbnail receives pointer events. The flying image never blocks Android input.
        Image(nsImage: shot.image).resizable().interpolation(.high).scaledToFit()
          .frame(
            width: docked ? thumb.width : initialHeight * ratio,
            height: docked ? thumb.height : initialHeight
          )
          .background(.black)
          .clipShape(RoundedRectangle(cornerRadius: docked ? 6 : 0))
          .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(docked ? 0.35 : 0)))
          .shadow(color: .black.opacity(0.4), radius: docked ? 12 : 0, y: 4)
          .onTapGesture { captures.openEditor(shot) }
          .onDrag { NSItemProvider(contentsOf: shot.file) ?? NSItemProvider() }
          .contextMenu {
            Button("Edit screenshot…") { captures.openEditor(shot) }
            Button("Copy screenshot") { captures.copy() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([shot.file]) }
            Button("Dismiss") { captures.dismiss() }
          }
          .help("Click to annotate · Drag into another app")
          .accessibilityLabel("Captured screenshot. Click to edit or drag to another app.")
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { captures.openEditor(shot) }
          .position(
            x: docked ? geometry.size.width - 18 - thumb.width / 2 : geometry.size.width / 2,
            y: docked
              ? geometry.size.height - bottom - 30 - thumb.height / 2 : geometry.size.height / 2
          )
          .allowsHitTesting(controls)
        if controls {
          HStack(spacing: 8) {
            Button {
              captures.copy()
            } label: {
              Label(
                captures.copied ? "Copied" : "Copy",
                systemImage: captures.copied ? "checkmark" : "doc.on.doc")
            }.help("Copy screenshot to clipboard")
            Button {
              captures.dismiss()
            } label: {
              Image(systemName: "xmark")
            }
            .help("Dismiss screenshot preview").accessibilityLabel("Dismiss screenshot preview")
          }
          .font(.system(size: 10)).buttonStyle(.borderless).padding(7)
          .background(.regularMaterial, in: Capsule())
          .position(
            x: geometry.size.width - 18 - max(thumb.width, 105) / 2,
            y: geometry.size.height - bottom - 13
          )
          .transition(.opacity)
        }
      }
      .opacity(captures.previewDismissing ? 0 : 1)
      .offset(y: captures.previewDismissing && !reduceMotion ? 28 : 0)
      .scaleEffect(captures.previewDismissing && !reduceMotion ? 0.96 : 1, anchor: .bottomTrailing)
      .allowsHitTesting(!captures.previewDismissing)
      .task {
        try? await Task.sleep(nanoseconds: 30_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(
          reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.86)
        ) {
          docked = true
        }
        try? await Task.sleep(nanoseconds: 550_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.12)) { controls = true }
      }
    }
  }
}

@MainActor
final class DeviceBatteryController: ObservableObject {
  @Published private(set) var reading: DeviceBatteryReading?
  private var task: Task<Void, Never>?
  private var operation: DeveloperDeviceSession?
  private var generation = UUID()
  func start(cli: String, directory: String, serial: String) {
    stop()
    let token = UUID()
    generation = token
    let operation = DeveloperDeviceSession(cli: cli, directory: directory, serial: serial)
    self.operation = operation
    task = Task { [weak self] in
      while !Task.isCancelled {
        let text = try? await Task.detached {
          try operation.shell(["dumpsys", "battery"], timeout: 5)
        }.value
        guard let self, self.generation == token, !Task.isCancelled else { return }
        self.reading = text.flatMap(DeviceBatteryReading.parse)
        do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
      }
    }
  }
  func stop() {
    generation = UUID()
    task?.cancel()
    task = nil
    operation?.stop()
    operation = nil
    reading = nil
  }
}

struct DeviceBatteryBadge: View {
  @ObservedObject var battery: DeviceBatteryController
  var body: some View {
    if let reading = battery.reading {
      let step =
        reading.percent <= 10
        ? 0
        : reading.percent <= 35 ? 25 : reading.percent <= 65 ? 50 : reading.percent <= 85 ? 75 : 100
      HStack(spacing: 3) {
        Image(systemName: reading.charging ? "battery.100.bolt" : "battery.\(step)")
          .foregroundStyle(
            reading.charging ? Color.green : reading.percent <= 20 ? Color.red : Color.secondary)
        Text("\(reading.percent)%").monospacedDigit()
      }.font(.system(size: 10)).foregroundStyle(.secondary)
        .help(
          "Battery: \(reading.percent)%\(reading.charging ? " · Charging" : reading.pluggedIn ? " · Plugged in" : "")"
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          "Battery \(reading.percent) percent\(reading.charging ? ", charging" : "")")
    }
  }
}
