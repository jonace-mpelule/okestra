import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DeveloperPresentationHost: View {
  @ObservedObject var model: DeviceController
  @ObservedObject var tools: DeveloperController
  @StateObject private var palette = CommandPalettePresenter()
  var body: some View {
    Color.clear.frame(width: 0, height: 0)
      .sheet(isPresented: $tools.showTools) { DeveloperToolsView(tools: tools) }
      .onChange(of: tools.showTools) { visible in
        if visible && model.focusMode { model.setFocusMode(false) }
      }
      .onChange(of: tools.showPalette) { visible in
        if visible {
          palette.present(model: model, tools: tools) { tools.showPalette = false }
        } else {
          palette.close()
        }
      }
      .onDisappear { palette.close() }
  }
}

struct DeveloperToolsView: View {
  @ObservedObject var tools: DeveloperController
  @Environment(\.dismiss) private var dismiss
  @State private var appSearch = ""
  @State private var confirmClear = false
  @State private var linkName = ""
  @State private var linkURL = ""
  @State private var linkPackage = ""
  @State private var portName = ""
  @State private var devicePort = ""
  @State private var macPort = ""
  @State private var showLinkEditor = false
  @State private var showPortEditor = false
  @State private var followLogs = true
  @State private var dropTarget = false
  private var unavailable: Bool { tools.target == nil || tools.operationBusy }
  private var filteredApps: [String] {
    tools.apps.filter { appSearch.isEmpty || $0.localizedCaseInsensitiveContains(appSearch) }
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "hammer").foregroundStyle(.secondary)
        Text("Developer Tools").fontWeight(.semibold)
        Spacer()
        Circle().fill(tools.target == nil ? Color.secondary : Color.green).frame(
          width: 5, height: 5)
        Text(tools.target?.name ?? "No device").font(.system(size: 11)).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle).help(
            tools.target?.serial ?? "Connect a device to get started.")
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).padding(.leading, 6)
      }.padding(.horizontal, 14).padding(.vertical, 10)
      Divider()
      HStack(spacing: 0) {
        VStack(spacing: 3) {
          ForEach(DeveloperTab.allCases) { tab in
            Button {
              tools.tab = tab
            } label: {
              HStack(spacing: 9) {
                Image(systemName: symbol(for: tab)).font(.system(size: 13)).foregroundStyle(
                  .secondary
                )
                .frame(width: 16)
                Text(tab.rawValue).font(
                  .system(size: 12, weight: tools.tab == tab ? .medium : .regular)
                )
                .foregroundStyle(.primary)
                Spacer(minLength: 0)
              }.padding(.horizontal, 10).padding(.vertical, 8)
                .background(
                  .primary.opacity(tools.tab == tab ? 0.075 : 0),
                  in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(tools.tab == tab ? "Selected" : "")
          }
          Spacer(minLength: 0)
        }.padding(8).frame(width: 148)
          .background(Color(nsColor: .windowBackgroundColor))
        Divider()
        Group {
          switch tools.tab {
          case .apps: apps
          case .logs: logs
          case .links: linksAndPorts
          case .capture: capture
          }
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color(nsColor: .controlBackgroundColor))
      }
      Divider()
      HStack(spacing: 7) {
        if tools.operationBusy {
          ProgressView().controlSize(.mini)
        } else if tools.failed {
          Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        }
        Text(tools.status).font(.system(size: 10)).foregroundStyle(
          tools.failed ? Color.primary : Color.secondary
        )
        .lineLimit(2).textSelection(.enabled).help(tools.status)
        Spacer(minLength: 0)
        if tools.operationBusy { Button("Cancel") { tools.cancelOperation() } }
      }.padding(.horizontal, 14).padding(.vertical, 8)
    }
    .font(.system(size: 12)).controlSize(.small)
    .frame(minWidth: 640, idealWidth: 720, minHeight: 440, idealHeight: 500)
    .background(Color(nsColor: .windowBackgroundColor))
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { tools.acceptDrop($0) }
    .overlay {
      if dropTarget {
        RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 2).allowsHitTesting(
          false)
      }
    }
    .confirmationDialog(
      "Clear all storage for \(tools.presets.selectedPackage)?", isPresented: $confirmClear,
      titleVisibility: .visible
    ) {
      Button("Clear app data", role: .destructive) { tools.clearAppData() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This removes the app's sign-in, settings, databases and downloaded files from this device."
      )
    }
  }
  private func symbol(for tab: DeveloperTab) -> String {
    switch tab {
    case .apps: return "square.grid.2x2"
    case .logs: return "text.alignleft"
    case .links: return "link"
    case .capture: return "record.circle"
    }
  }
  private var apps: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        TextField("Filter packages", text: $appSearch).textFieldStyle(.roundedBorder)
          .accessibilityLabel("Filter installed packages")
        Button {
          tools.refreshApps()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("Refresh installed apps").accessibilityLabel("Refresh installed apps").disabled(
          unavailable)
        Button("Install APK…", systemImage: "square.and.arrow.down") { tools.chooseAPK() }
          .disabled(unavailable).help("Choose an APK, or drop one onto this panel.")
      }
      HStack {
        Text("Installed applications").fontWeight(.medium)
        Text("\(filteredApps.count)").foregroundStyle(.secondary).monospacedDigit()
        Spacer()
        Text("User apps").font(.system(size: 10)).foregroundStyle(.tertiary)
      }
      List(
        selection: Binding<String?>(
          get: { tools.presets.selectedPackage.isEmpty ? nil : tools.presets.selectedPackage },
          set: { tools.selectApp($0 ?? "") })
      ) {
        ForEach(filteredApps, id: \.self) { package in
          HStack(spacing: 8) {
            Image(systemName: "app").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(package).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(
              .middle)
          }.tag(package).help(package)
        }
      }
      .listStyle(.inset).environment(\.defaultMinListRowHeight, 25)
      .overlay {
        if filteredApps.isEmpty {
          emptyState(
            "No applications",
            detail: tools.target == nil
              ? "Connect a device to browse installed apps."
              : appSearch.isEmpty
                ? "Refresh the list or install an APK." : "Try a different package name.",
            symbol: "app.dashed")
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 5))
      .overlay(
        RoundedRectangle(cornerRadius: 5).strokeBorder(
          Color(nsColor: .separatorColor), lineWidth: 0.5))
      HStack(spacing: 6) {
        ControlGroup {
          Button("Launch", systemImage: "play.fill") { tools.launchApp() }
          Button("Restart", systemImage: "arrow.clockwise") { tools.launchApp(restart: true) }
          Button("Logs", systemImage: "text.alignleft") {
            tools.tab = .logs
            tools.appLogsOnly = true
            tools.startLogs()
          }
        }
        Menu {
          Button("Clear app data…", role: .destructive) { confirmClear = true }
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("App actions").accessibilityLabel("App actions")
        Spacer()
        Image(systemName: "arrow.down.doc").foregroundStyle(.tertiary).help(
          "Drop APK files here to install.")
      }.disabled(unavailable || tools.presets.selectedPackage.isEmpty)
      Text(
        tools.presets.selectedPackage.isEmpty
          ? "Select an application for actions. Drop an APK to install."
          : tools.presets.selectedPackage
      )
      .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      .textSelection(.enabled)
    }
  }
  private var logs: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button(
          tools.logsRunning ? "Stop" : "Start",
          systemImage: tools.logsRunning ? "stop.fill" : "play.fill"
        ) {
          if tools.logsRunning { tools.stopLogs() } else { tools.startLogs() }
        }.disabled(tools.target == nil).help(tools.logsRunning ? "Stop Logcat" : "Start Logcat")
        Picker(
          "Scope",
          selection: Binding(
            get: { tools.appLogsOnly && !tools.presets.selectedPackage.isEmpty },
            set: { tools.appLogsOnly = $0 })
        ) {
          Text("Device").tag(false)
          Text("App").tag(true).disabled(tools.presets.selectedPackage.isEmpty)
        }.labelsHidden().frame(width: 82).help("Filter by device or selected application")
        Picker("Severity", selection: $tools.minimumLogLevel) {
          Text("All levels").tag("V")
          Text("Debug").tag("D")
          Text("Info").tag("I")
          Text("Warnings").tag("W")
          Text("Errors").tag("E")
          Text("Fatal").tag("F")
        }.labelsHidden().frame(width: 100)
        Spacer(minLength: 0)
        Toggle(isOn: $followLogs) { Image(systemName: "arrow.down.to.line") }
          .toggleStyle(.button).help("Follow new logs").accessibilityLabel("Follow new logs")
        Button {
          tools.copyLogs()
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .help("Copy filtered logs").accessibilityLabel("Copy filtered logs")
        Button {
          tools.clearLogs()
        } label: {
          Image(systemName: "trash")
        }
        .help("Clear buffered logs").accessibilityLabel("Clear buffered logs")
      }
      TextField("Filter logs", text: $tools.logQuery).textFieldStyle(.roundedBorder)
      if !tools.crashes.isEmpty {
        DisclosureGroup("Crash signals (\(tools.crashes.count))") {
          ScrollView {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(tools.crashes.suffix(5)) {
                Text($0.text).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.frame(maxHeight: 80)
        }.font(.system(size: 11)).foregroundStyle(.orange)
      }
      ScrollViewReader { proxy in
        List(tools.filteredLogs) { entry in
          Text(entry.text).font(.system(size: 10, design: .monospaced))
            .foregroundStyle(
              ["E", "F"].contains(entry.level)
                ? Color.red : entry.level == "W" ? Color.orange : Color.primary
            )
            .textSelection(.enabled).id(entry.id)
        }.listStyle(.inset).environment(\.defaultMinListRowHeight, 18)
          .overlay {
            if tools.filteredLogs.isEmpty {
              emptyState(
                tools.logsRunning ? "Waiting for logs" : "Logcat is stopped",
                detail: tools.logsRunning
                  ? "Matching messages will appear here."
                  : "Start capture to inspect device activity.", symbol: "text.alignleft")
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: 5))
          .overlay(
            RoundedRectangle(cornerRadius: 5).strokeBorder(
              Color(nsColor: .separatorColor), lineWidth: 0.5)
          )
          .onChange(of: tools.logs.last?.id) { _ in
            if followLogs, let last = tools.filteredLogs.last {
              proxy.scrollTo(last.id, anchor: .bottom)
            }
          }
      }
      HStack {
        Text(tools.logStatus).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        Spacer()
        Button("Export…", systemImage: "square.and.arrow.up") { tools.exportReport() }.disabled(
          unavailable)
      }
    }
  }
  private var linksAndPorts: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        GroupBox {
          VStack(spacing: 0) {
            if tools.presets.links.isEmpty {
              compactEmpty("No saved links", detail: "Add a URL to open it on this device.")
            }
            ForEach(tools.presets.links) { link in
              HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(link.name).fontWeight(.medium)
                  Text(link.url).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle).help(link.url)
                }
                Spacer(minLength: 0)
                Button {
                  tools.openLink(link)
                } label: {
                  Image(systemName: "arrow.up.forward.app")
                }
                .help("Open \(link.name)").accessibilityLabel("Open \(link.name)").disabled(
                  unavailable)
                Button(role: .destructive) {
                  tools.removeLink(link.id)
                } label: {
                  Image(systemName: "trash")
                }
                .help("Remove saved link").accessibilityLabel("Remove \(link.name)")
              }.padding(.vertical, 7)
              if link.id != tools.presets.links.last?.id { Divider() }
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        } label: {
          HStack {
            Text("Deep links").fontWeight(.medium)
            Spacer()
            Button {
              showLinkEditor = true
            } label: {
              Image(systemName: "plus")
            }
            .buttonStyle(.borderless).help("Add deep link").accessibilityLabel("Add deep link")
            .disabled(tools.target == nil)
            .popover(isPresented: $showLinkEditor, arrowEdge: .bottom) { linkEditor }
          }
        }
        GroupBox {
          VStack(alignment: .leading, spacing: 0) {
            if tools.presets.ports.isEmpty {
              compactEmpty("No saved ports", detail: "Connect Android localhost to a Mac service.")
            }
            ForEach(tools.presets.ports) { port in
              HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                  HStack(spacing: 6) {
                    Text(port.name).fontWeight(.medium)
                    if tools.activePorts[port.devicePort] == "tcp:\(port.macPort)" {
                      Text("Connected").font(.system(size: 9)).foregroundStyle(.green)
                    } else if let active = tools.activePorts[port.devicePort] {
                      Text("In use").font(.system(size: 9)).foregroundStyle(.orange).help(
                        "Mapped to " + active)
                    }
                  }
                  Text(verbatim: "Device :\(port.devicePort) → Mac :\(port.macPort)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(
                  tools.activePorts[port.devicePort] == "tcp:\(port.macPort)"
                    ? "Disconnect" : "Connect"
                ) {
                  tools.applyPort(
                    port, remove: tools.activePorts[port.devicePort] == "tcp:\(port.macPort)")
                }.disabled(unavailable)
                Button(role: .destructive) {
                  tools.forgetPort(port)
                } label: {
                  Image(systemName: "trash")
                }
                .help("Remove saved port").accessibilityLabel("Remove \(port.name)")
              }.padding(.vertical, 7)
              if port.id != tools.presets.ports.last?.id { Divider() }
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        } label: {
          HStack(spacing: 10) {
            Text("Development ports").fontWeight(.medium)
            Spacer()
            Button {
              tools.refreshPorts()
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless).help("Refresh connections").accessibilityLabel(
              "Refresh connections"
            ).disabled(unavailable)
            Button {
              showPortEditor = true
            } label: {
              Image(systemName: "plus")
            }
            .buttonStyle(.borderless).help("Add port mapping").accessibilityLabel(
              "Add port mapping"
            ).disabled(tools.target == nil)
            .popover(isPresented: $showPortEditor, arrowEdge: .bottom) { portEditor }
          }
        }
        Text("Mappings stay available to your development tools after the viewer disconnects.")
          .font(.system(size: 10)).foregroundStyle(.secondary)
      }.padding(1)
    }
  }
  private var linkEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New deep link").fontWeight(.semibold)
      Form {
        TextField("Name", text: $linkName)
        TextField("URL", text: $linkURL, prompt: Text("myapp://route"))
        TextField("Package", text: $linkPackage, prompt: Text("Optional"))
      }.textFieldStyle(.roundedBorder).fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Cancel") { showLinkEditor = false }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Add") {
          tools.addLink(name: linkName, url: linkURL, package: linkPackage)
          if !tools.failed {
            showLinkEditor = false
            linkName = ""
            linkURL = ""
            linkPackage = ""
          }
        }.keyboardShortcut(.defaultAction).disabled(linkName.isEmpty || linkURL.isEmpty)
      }
    }.font(.system(size: 12)).controlSize(.small).padding(16).frame(width: 330)
  }
  private var portEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New port mapping").fontWeight(.semibold)
      Form {
        TextField("Name", text: $portName, prompt: Text("Metro, API…"))
        TextField("Device port", text: $devicePort, prompt: Text("8081"))
        TextField("Mac port", text: $macPort, prompt: Text("8081"))
      }.textFieldStyle(.roundedBorder).fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Cancel") { showPortEditor = false }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Add") {
          tools.addPort(name: portName, device: devicePort, mac: macPort)
          if !tools.failed {
            showPortEditor = false
            portName = ""
            devicePort = ""
            macPort = ""
          }
        }.keyboardShortcut(.defaultAction).disabled(devicePort.isEmpty || macPort.isEmpty)
      }
    }.font(.system(size: 12)).controlSize(.small).padding(16).frame(width: 330)
  }
  private var capture: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        GroupBox("Screen recording") {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Button(
                tools.isRecording ? "Stop recording" : "Record…",
                systemImage: tools.isRecording ? "stop.circle.fill" : "record.circle"
              ) {
                tools.toggleRecording()
              }.disabled(tools.target == nil && !tools.isRecording)
              if let file = tools.lastRecording {
                Button("Review…") {
                  tools.showTools = false
                  tools.videoReview.open(file)
                }
                Button("Show in Finder") { tools.revealRecording() }
              }
              Spacer()
              Text("MOV").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text(tools.recordingStatus).font(.system(size: 11)).foregroundStyle(.secondary)
              .textSelection(.enabled)
            Text(
              "Includes audio when routing is enabled. Rotating or reconnecting finishes the recording."
            )
            .font(.system(size: 10)).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
        GroupBox("Bug report") {
          VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $tools.reportNotes).font(.system(size: 11)).frame(height: 76)
              .overlay(alignment: .topLeading) {
                if tools.reportNotes.isEmpty {
                  Text("Describe the issue or reproduction steps…").font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5).padding(.vertical, 7).allowsHitTesting(false)
                }
              }
              .overlay(
                RoundedRectangle(cornerRadius: 4).strokeBorder(
                  Color(nsColor: .separatorColor), lineWidth: 0.5)
              )
              .accessibilityLabel("Bug report notes")
            Toggle("Include latest recording", isOn: $tools.includeRecordingInReport).disabled(
              tools.lastRecording == nil
            )
            .font(.system(size: 11))
            HStack {
              Text("Screenshot · Logs · Device details").font(.system(size: 10)).foregroundStyle(
                .secondary)
              Spacer()
              Button("Export…", systemImage: "square.and.arrow.up") { tools.exportReport() }
                .disabled(unavailable)
            }
          }.padding(4)
        }
      }.padding(1)
    }
  }
  private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
    VStack(spacing: 7) {
      Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.tertiary)
      Text(title).font(.system(size: 12, weight: .medium))
      Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(
        .center)
    }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
  }
  private func compactEmpty(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).foregroundStyle(.secondary)
      Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary)
    }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct DeveloperActivityBadge: View {
  @ObservedObject var tools: DeveloperController
  var body: some View {
    VStack(alignment: .trailing, spacing: 8) {
      if tools.unreadCrash {
        Button {
          tools.open(.logs)
        } label: {
          Label("Crash detected", systemImage: "exclamationmark.triangle.fill").foregroundStyle(
            .orange)
        }
      }
      if tools.isRecording {
        Button {
          tools.recording.stop()
        } label: {
          Label("Stop recording", systemImage: "record.circle.fill").foregroundStyle(.red)
        }
      }
    }.buttonStyle(.bordered).controlSize(.small)
  }
}

private struct DeveloperPaletteAction: Identifiable {
  let id: String
  let title: String
  let subtitle: String
  let symbol: String
  let enabled: Bool
  let run: () -> Void
}

struct DeveloperCommandPalette: View {
  @ObservedObject var model: DeviceController
  @ObservedObject var tools: DeveloperController
  @State private var query = ""
  @State private var selected: String?
  var width: CGFloat = 520
  var onClose: () -> Void = {}
  var onHeightChange: (CGFloat) -> Void = { _ in }
  private var actions: [DeveloperPaletteAction] {
    let ready = tools.target != nil && !tools.operationBusy
    var values = [
      DeveloperPaletteAction(
        id: "tools", title: "Open developer tools",
        subtitle: "Apps, logs, links, ports and capture", symbol: "hammer", enabled: true
      ) { tools.open(.apps) },
      DeveloperPaletteAction(
        id: "install", title: "Install APK…", subtitle: "Choose a build for the selected device",
        symbol: "square.and.arrow.down", enabled: ready
      ) { tools.chooseAPK() },
      DeveloperPaletteAction(
        id: "launch", title: "Launch selected app", subtitle: tools.presets.selectedPackage,
        symbol: "play", enabled: ready && !tools.presets.selectedPackage.isEmpty
      ) { tools.launchApp() },
      DeveloperPaletteAction(
        id: "restart", title: "Restart selected app", subtitle: tools.presets.selectedPackage,
        symbol: "arrow.clockwise", enabled: ready && !tools.presets.selectedPackage.isEmpty
      ) { tools.launchApp(restart: true) },
      DeveloperPaletteAction(
        id: "logs", title: "Open Logcat", subtitle: "Live logs and crash signals",
        symbol: "text.alignleft", enabled: true
      ) {
        tools.open(.logs)
        tools.startLogs()
      },
      DeveloperPaletteAction(
        id: "links", title: "Manage deep links and ports", subtitle: "Saved device presets",
        symbol: "link", enabled: true
      ) { tools.open(.links) },
      DeveloperPaletteAction(
        id: "record", title: tools.isRecording ? "Stop recording" : "Record screen…",
        subtitle: "Save video to a MOV file", symbol: "record.circle",
        enabled: tools.target != nil || tools.isRecording
      ) { tools.toggleRecording() },
      DeveloperPaletteAction(
        id: "report", title: "Export bug report…", subtitle: "Screenshot, logs and session details",
        symbol: "square.and.arrow.up", enabled: ready
      ) { tools.exportReport() },
      DeveloperPaletteAction(
        id: "review-recording", title: "Review latest recording",
        subtitle: "Comments, annotated frames and voice notes",
        symbol: "video", enabled: tools.lastRecording != nil && tools.videoReview.editor == nil
      ) { if let file = tools.lastRecording { tools.videoReview.open(file) } },
      DeveloperPaletteAction(
        id: "audio",
        title: tools.audioEnabled ? "Disable Android audio" : "Route Android audio to Mac",
        subtitle: "Uses the current Mac audio output", symbol: "speaker.wave.2",
        enabled: !tools.isRecording
      ) { tools.setAudioEnabled(!tools.audioEnabled) },
      DeveloperPaletteAction(
        id: "mute", title: tools.audioMuted ? "Unmute Android audio" : "Mute Android audio",
        subtitle: "Playback volume only", symbol: "speaker.slash", enabled: tools.audioEnabled
      ) { tools.audioMuted.toggle() },
      DeveloperPaletteAction(
        id: "capture", title: "Recording and reports",
        subtitle: "Screen recording and bug report notes", symbol: "slider.horizontal.3",
        enabled: true
      ) { tools.open(.capture) },
      DeveloperPaletteAction(
        id: "screenshot", title: "Capture screenshot", subtitle: "Capture the Android display",
        symbol: "camera", enabled: model.connected && !model.busy
      ) { model.screenshot() },
      DeveloperPaletteAction(
        id: "open-screenshot", title: "Open screenshot…", subtitle: "Annotate a saved PNG",
        symbol: "photo", enabled: model.captures.editor == nil
      ) { model.captures.openSavedScreenshot(in: model.viewerWindow) },
      DeveloperPaletteAction(
        id: "sidebar", title: "Toggle sidebar", subtitle: "Stream performance and appearance",
        symbol: "sidebar.left", enabled: !model.focusMode
      ) { model.showSidebar.toggle() },
      DeveloperPaletteAction(
        id: "reconnect", title: "Reconnect device", subtitle: model.deviceTitle,
        symbol: "arrow.triangle.2.circlepath", enabled: model.canConnect
      ) { model.connect(reset: true) },
    ]
    values.append(
      DeveloperPaletteAction(
        id: "pin",
        title: model.alwaysOnTop ? "Turn off Always on Top" : "Keep window Always on Top",
        subtitle: "Pin the device above your editor", symbol: "pin", enabled: true
      ) { model.alwaysOnTop.toggle() })
    values.append(
      DeveloperPaletteAction(
        id: "focus", title: model.focusMode ? "Exit Focus mode" : "Enter Focus mode",
        subtitle: "Device-only window beside your editor",
        symbol: "arrow.down.right.and.arrow.up.left", enabled: !model.focusTransitioning
      ) {
        model.toggleFocusMode()
      })
    values += tools.presets.links.map { link in
      DeveloperPaletteAction(
        id: "link-\(link.id)", title: "Open \(link.name)", subtitle: link.url, symbol: "link",
        enabled: ready
      ) { tools.openLink(link) }
    }
    values += tools.presets.ports.map { port in
      DeveloperPaletteAction(
        id: "port-\(port.id)", title: "Connect \(port.name)",
        subtitle: "Device :\(port.devicePort) → Mac :\(port.macPort)", symbol: "network",
        enabled: ready
      ) { tools.applyPort(port) }
    }
    return values
  }
  private var results: [DeveloperPaletteAction] {
    actions.filter {
      query.isEmpty || ($0.title + " " + $0.subtitle).localizedCaseInsensitiveContains(query)
    }
  }
  private func execute(_ action: DeveloperPaletteAction) {
    guard action.enabled else { return }
    onClose()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { action.run() }
  }
  private var listHeight: CGFloat { results.isEmpty ? 68 : CGFloat(min(6, results.count)) * 38 + 8 }
  private var height: CGFloat { 84 + listHeight }
  private var selectedAction: DeveloperPaletteAction? {
    results.first { $0.id == selected && $0.enabled } ?? results.first(where: \.enabled)
  }
  private func moveSelection(_ delta: Int) {
    let available = results.filter(\.enabled)
    guard !available.isEmpty else { return }
    let index = available.firstIndex { $0.id == selected } ?? 0
    selected = available[max(0, min(available.count - 1, index + delta))].id
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(.secondary)
        PaletteSearchField(
          text: $query,
          onMove: moveSelection,
          onSubmit: { if let action = selectedAction { execute(action) } },
          onEscape: onClose
        )
        .frame(height: 30)
        Button(action: onClose) {
          Text("esc").font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 3)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).help("Close command palette")
      }.padding(.horizontal, 16).frame(height: 52)
      Divider().opacity(0.45)
      if results.isEmpty {
        Text("No commands found").font(.system(size: 12)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity).frame(height: listHeight)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 2) {
              ForEach(results) { action in
                Button {
                  execute(action)
                } label: {
                  HStack(spacing: 10) {
                    Image(systemName: action.symbol).font(.system(size: 12))
                      .foregroundStyle(.secondary).frame(width: 24, height: 24)
                      .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
                    Text(action.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(action.subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                      .lineLimit(1).truncationMode(.middle).frame(maxWidth: width * 0.3)
                  }
                  .padding(.horizontal, 8).frame(height: 36)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .background(
                    .primary.opacity(selectedAction?.id == action.id ? 0.07 : 0),
                    in: RoundedRectangle(cornerRadius: 6)
                  )
                  .opacity(action.enabled ? 1 : 0.4).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!action.enabled).id(action.id)
                  .onHover { if $0 && action.enabled { selected = action.id } }
              }
            }.padding(4)
          }.scrollIndicators(.hidden).frame(height: listHeight)
            .onChange(of: selected) { id in
              if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
      }
      Divider().opacity(0.45)
      HStack(spacing: 6) {
        Image(systemName: "square.stack.3d.up.fill").font(.system(size: 10))
        Text("Okestra").font(.system(size: 10, weight: .medium))
        Spacer()
        Text("↑ ↓").font(.system(size: 10, design: .monospaced))
        Text("Navigate").font(.system(size: 10))
        Text("↵").font(.system(size: 12, design: .monospaced)).padding(.leading, 8)
        Text("Run").font(.system(size: 10, weight: .medium))
      }.foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 30)
    }
    .frame(width: width, height: height)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
    .clipShape(RoundedRectangle(cornerRadius: 14))
    .onAppear {
      selected = results.first(where: \.enabled)?.id
      onHeightChange(height)
    }
    .onChange(of: query) { _ in selected = results.first(where: \.enabled)?.id }
    .onChange(of: height) { onHeightChange($0) }
  }
}

struct DeviceDeveloperCommands: Commands {
  @ObservedObject var model: DeviceController
  @ObservedObject var tools: DeveloperController
  var body: some Commands {
    CommandMenu("Developer") {
      Button("Command palette…") { tools.openPalette() }.keyboardShortcut("k")
      Button("Developer tools…") { tools.open(.apps) }.keyboardShortcut(
        "d", modifiers: [.command, .shift])
      Divider()
      Button("Install APK…") { tools.chooseAPK() }.keyboardShortcut("i").disabled(
        tools.target == nil || tools.operationBusy)
      Button("App logs…") {
        tools.open(.logs)
        tools.startLogs()
      }.keyboardShortcut("l", modifiers: [.command, .shift])
      Button(tools.isRecording ? "Stop recording" : "Record screen…") { tools.toggleRecording() }
        .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(
          tools.target == nil && !tools.isRecording)
      Button("Export bug report…") { tools.exportReport() }
        .keyboardShortcut("b", modifiers: [.command, .shift]).disabled(
          tools.target == nil || tools.operationBusy)
      Divider()
      Toggle(
        "Play Android audio on Mac",
        isOn: Binding(get: { tools.audioEnabled }, set: { tools.setAudioEnabled($0) })
      )
      .disabled(tools.isRecording)
      Toggle("Mute Android audio", isOn: $tools.audioMuted).disabled(!tools.audioEnabled)
    }
  }
}

struct DeviceAudioSidebar: View {
  @ObservedObject var tools: DeveloperController
  @State private var expanded = true
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        expanded.toggle()
      } label: {
        HStack {
          Text("Audio routing").font(.system(size: 12, weight: .semibold))
          Spacer()
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel("Audio routing")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      if expanded {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("Play on Mac").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Toggle(
              "Play Android audio on Mac",
              isOn: Binding(get: { tools.audioEnabled }, set: { tools.setAudioEnabled($0) })
            )
            .labelsHidden().toggleStyle(.switch).controlSize(.mini).fixedSize()
            .disabled(tools.isRecording)
          }
          HStack(spacing: 8) {
            Button {
              tools.audioMuted.toggle()
            } label: {
              Image(systemName: tools.audioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11)).frame(width: 22, height: 22)
            }.buttonStyle(.plain)
              .help(tools.audioMuted ? "Unmute Android playback" : "Mute Android playback")
              .accessibilityLabel(
                tools.audioMuted ? "Unmute Android playback" : "Mute Android playback")
            Slider(value: $tools.audioVolume, in: 0...1).controlSize(.mini)
              .accessibilityLabel("Android playback volume")
            Text("\(Int(tools.audioVolume * 100))%")
              .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
              .frame(width: 30, alignment: .trailing)
          }.disabled(!tools.audioEnabled)
          Text(tools.audioEnabled ? tools.audioStatus : "Uses your Mac speakers or headphones.")
            .font(.system(size: 9)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          if tools.isRecording {
            Text("Stop recording to change audio routing.")
              .font(.system(size: 9)).foregroundStyle(.secondary)
          }
        }.padding(.top, 14)
      }
    }
  }
}

// An auxiliary panel keeps search lightweight and leaves the device window undimmed.
@MainActor
private final class CommandPalettePresenter: NSObject, ObservableObject, NSWindowDelegate {
  private var panel: PalettePanel?
  private var onDismiss: (() -> Void)?
  func present(model: DeviceController, tools: DeveloperController, onDismiss: @escaping () -> Void)
  {
    if let panel {
      panel.makeKeyAndOrderFront(nil)
      return
    }
    self.onDismiss = onDismiss
    let parent = NSApp.keyWindow ?? NSApp.mainWindow
    let screen = parent?.screen ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let width = min(520, max(360, (parent?.frame.width ?? visible.width) - 32))
    let anchor = parent?.frame ?? visible
    let x = min(visible.maxX - width - 16, max(visible.minX + 16, anchor.midX - width / 2))
    let top = min(visible.maxY - 24, anchor.maxY - min(110, anchor.height * 0.14))
    let panel = PalettePanel(
      contentRect: NSRect(x: x, y: max(visible.minY + 16, top - 320), width: width, height: 320),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    self.panel = panel
    panel.identifier = NSUserInterfaceItemIdentifier("OkestraCommandPalette")
    panel.title = "Okestra Commands"
    panel.delegate = self
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = true
    panel.isMovableByWindowBackground = true
    panel.appearance = parent?.effectiveAppearance
    panel.collectionBehavior = [.fullScreenAuxiliary]
    panel.contentView = NSHostingView(
      rootView: DeveloperCommandPalette(
        model: model, tools: tools,
        width: width, onClose: { [weak self] in self?.close() },
        onHeightChange: { [weak self] in self?.resize(height: $0) }))
    panel.makeKeyAndOrderFront(nil)
  }
  private func resize(height: CGFloat) {
    guard let panel else { return }
    var frame = panel.frame
    guard abs(frame.height - height) > 0.5 else { return }
    frame.origin.y += frame.height - height
    frame.size.height = height
    if let screen = panel.screen {
      frame.origin.y = max(screen.visibleFrame.minY + 16, frame.origin.y)
    }
    panel.setFrame(frame, display: true)
  }
  func close() {
    guard let panel else { return }
    self.panel = nil
    panel.orderOut(nil)
    panel.close()
    let completion = onDismiss
    onDismiss = nil
    completion?()
  }
  func windowDidResignKey(_ notification: Notification) { close() }
}
private final class PalettePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

// Handle navigation before the field editor consumes arrows/Return as text editing.
private struct PaletteSearchField: NSViewRepresentable {
  @Binding var text: String
  var onMove: (Int) -> Void
  var onSubmit: () -> Void
  var onEscape: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> SearchField {
    let field = SearchField()
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 15)
    field.placeholderString = "Search commands, links and ports…"
    field.setAccessibilityLabel("Search commands")
    field.delegate = context.coordinator
    return field
  }
  func updateNSView(_ field: SearchField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
  }
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: PaletteSearchField
    init(_ parent: PaletteSearchField) { self.parent = parent }
    func controlTextDidChange(_ notification: Notification) {
      if let field = notification.object as? NSTextField { parent.text = field.stringValue }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
    {
      guard !textView.hasMarkedText() else { return false }
      switch NSStringFromSelector(selector) {
      case "moveDown:": parent.onMove(1)
      case "moveUp:": parent.onMove(-1)
      case "insertNewline:": parent.onSubmit()
      case "cancelOperation:": parent.onEscape()
      default: return false
      }
      return true
    }
  }
  final class SearchField: NSTextField {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      DispatchQueue.main.async { [weak self] in
        guard let self, let window = self.window else { return }
        window.makeFirstResponder(self)
      }
    }
  }
}
