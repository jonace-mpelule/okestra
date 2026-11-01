import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum Studio {
  static let green = Color(red: 0.10, green: 0.58, blue: 0.41)
  static let blue = Color(red: 0.18, green: 0.53, blue: 0.91)
  static func canvas(_ dark: Bool) -> Color {
    dark
      ? Color(red: 0.085, green: 0.09, blue: 0.105) : Color(red: 0.968, green: 0.969, blue: 0.981)
  }
}

// Native Liquid Glass on macOS 26+, with a material fallback for our macOS 13 minimum.
private struct StudioGlass: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var systemOpaque
  let radius: CGFloat
  let clear: Bool
  let opaque: Bool
  @ViewBuilder func body(content: Content) -> some View {
    if opaque || systemOpaque {
      content.background(
        Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: radius)
      )
      .overlay(
        RoundedRectangle(cornerRadius: radius).strokeBorder(.primary.opacity(0.10), lineWidth: 0.5))
    } else if #available(macOS 26.0, *) {
      content.glassEffect(clear ? .clear : .regular, in: RoundedRectangle(cornerRadius: radius))
    } else {
      content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
        .overlay(
          RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
    }
  }
}
extension View {
  fileprivate func studioGlass(_ radius: CGFloat = 16, clear: Bool = false, opaque: Bool = false)
    -> some View
  {
    modifier(StudioGlass(radius: radius, clear: clear, opaque: opaque))
  }
}

struct DeviceWindow: View {
  @ObservedObject var model: DeviceController
  @AppStorage("studioAppearance") private var appearance = "Light"
  @AppStorage("studioOpaque") private var opaque = false
  @Environment(\.colorScheme) private var colorScheme
  @State private var apkDropTarget = false
  private var theme: ColorScheme? {
    appearance == "System" ? nil : appearance == "Dark" ? .dark : .light
  }
  var body: some View {
    NavigationSplitView(
      columnVisibility: Binding(
        get: { model.focusMode ? .detailOnly : model.showSidebar ? .all : .detailOnly },
        set: { if !model.focusMode { model.showSidebar = $0 != .detailOnly } }
      )
    ) {
      DeviceInspector(model: model)
        .navigationSplitViewColumnWidth(min: 250, ideal: 278, max: 360)
        .background(opaque ? Color(nsColor: .windowBackgroundColor) : .clear)
        .ignoresSafeArea(.container, edges: .top)
    } detail: {
      DeviceCanvas(model: model)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
          if model.focusMode { Color.black } else { WorkspaceCanvasBackground() }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $apkDropTarget) {
          model.developer.acceptDrop($0)
        }
        .overlay {
          if apkDropTarget {
            RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3)
              .allowsHitTesting(false)
          }
        }
        .ignoresSafeArea(.container, edges: .top)
    }
    .navigationSplitViewStyle(.balanced)
    .modifier(NativeSidebarToolbar())
    .toolbar(.hidden)
    .ignoresSafeArea(.container, edges: .top)
    .frame(
      minWidth: model.focusMode ? 220 : model.showSidebar ? 810 : 460,
      minHeight: model.focusMode ? 320 : 660
    )
    .preferredColorScheme(theme)
    .background(StudioWindowChrome(controller: model))
    .background(DeveloperPresentationHost(model: model, tools: model.developer))
    .modifier(ScreenshotEditorPresentation(captures: model.captures))
    .modifier(VideoEditorPresentation(reviews: model.developer.videoReview))
    .onAppear {
      model.begin()
    }
    .onDisappear { model.disconnect() }
    .onOpenURL { model.openURL($0) }
    .onExitCommand {
      if let video = model.developer.videoReview.editor {
        video.requestClose()
      } else if let editor = model.captures.editor {
        editor.requestClose()
      } else if model.focusMode {
        model.setFocusMode(false)
      }
    }
    .onChange(of: model.displaySize) { _ in model.resizeFocusWindow() }
    .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
      model.samplePerformance()
    }
    .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
      model.refreshDevices()
    }
  }
}

private struct DeviceCanvas: View {
  @ObservedObject var model: DeviceController
  @AppStorage("studioFrame") private var showFrame = true
  @AppStorage("studioFinish") private var finish = "Graphite"
  @AppStorage("studioGlass") private var glass = "Regular"
  @AppStorage("studioOpaque") private var opaque = false
  @AppStorage("studioScale") private var scale = "Fit"
  @Environment(\.colorScheme) private var colorScheme
  @State private var zoom = CanvasZoom()
  @State private var fittedPixelScale = 1.0
  var body: some View {
    ZStack {
      GeometryReader { geometry in
        let viewportHeight = max(1, geometry.size.height)
        let fraction = model.focusMode ? 1.0 : scale == "Compact" ? 0.82 : 1.0
        let widthInset = model.focusMode ? 0.0 : 100.0
        let heightInset = model.focusMode ? 0.0 : 48.0
        let fitted = model.chassis.layout(
          videoWidth: model.displaySize.width, videoHeight: model.displaySize.height,
          availableWidth: max(1, geometry.size.width - widthInset) * fraction,
          availableHeight: max(1, viewportHeight - heightInset) * fraction, framed: showFrame)
        let fittedScale = fitted.screenWidth * model.backingScale / max(1, model.renderedSize.width)
        let pixelScale = model.focusMode ? fittedScale : zoom.resolved(fittedScale: fittedScale)
        let layout = fitted.scaled(by: pixelScale / max(0.001, fittedScale))
        ScrollViewReader { proxy in
          ScrollView([.horizontal, .vertical]) {
            ZStack {
              HardwareDevice(
                model: model, layout: layout, framed: showFrame, silver: finish == "Silver"
              )
              .opacity(model.rotationPresentation == nil || model.rotationRevealing ? 1 : 0)
              if let rotation = model.rotationPresentation {
                let oldFitted = model.chassis.layout(
                  videoWidth: rotation.displaySize.width,
                  videoHeight: rotation.displaySize.height,
                  availableWidth: max(1, geometry.size.width - widthInset) * fraction,
                  availableHeight: max(1, viewportHeight - heightInset) * fraction,
                  framed: showFrame)
                let oldPixelScale =
                  oldFitted.screenWidth * model.backingScale / max(1, rotation.videoSize.width)
                let oldLayout = oldFitted.scaled(
                  by: model.focusMode
                    ? 1 : zoom.resolved(fittedScale: oldPixelScale) / max(0.001, oldPixelScale))
                RotatingDeviceSnapshot(
                  model: model, rotation: rotation, from: oldLayout, to: layout,
                  framed: showFrame, silver: finish == "Silver"
                )
                .opacity(model.rotationRevealing ? 0 : 1)
                .id(rotation.id)
              }
            }.frame(width: layout.width, height: layout.height)
              .id("device-center")
              .frame(
                width: max(geometry.size.width, layout.width + (model.focusMode ? 0 : 48)),
                height: max(viewportHeight, layout.height + (model.focusMode ? 0 : 48)))
          }
          .scrollIndicators(.hidden)
          .frame(height: viewportHeight)
          .onChange(of: zoom) { _ in
            DispatchQueue.main.async { proxy.scrollTo("device-center", anchor: .center) }
          }
          .onChange(of: model.focusMode) { _ in
            DispatchQueue.main.async { proxy.scrollTo("device-center", anchor: .center) }
          }
          .onChange(of: model.rotationPresentation?.id) { id in
            guard id != nil else { return }
            DispatchQueue.main.async { proxy.scrollTo("device-center", anchor: .center) }
          }
        }
        .onAppear { fittedPixelScale = fittedScale }
        .onChange(of: fittedScale) { fittedPixelScale = $0 }
      }
    }
    .padding(.top, model.focusMode ? FocusWindowGeometry.titlebarHeight : 0)
    .overlay(alignment: .bottom) {
      if !model.focusMode {
        HStack(spacing: 8) {
          HStack(spacing: 2) {
            CanvasButton(title: "Back", symbol: "arrow.uturn.backward") { model.key(4) }
            CanvasButton(title: "Home", symbol: "house") { model.key(3) }
            CanvasButton(title: "Capture screenshot", symbol: "camera") { model.screenshot() }
            CanvasButton(title: "Recent apps", symbol: "square.on.square") { model.key(187) }
          }.padding(4).studioGlass(13, clear: glass == "Clear", opaque: opaque)
          CanvasButton(
            title: "Rotate device", symbol: "rotate.right",
            enabled: model.rotationPresentation == nil
          ) { model.rotateDevice() }
          .padding(4).studioGlass(13, clear: glass == "Clear", opaque: opaque)
        }
        .disabled(!model.connected || model.busy || !model.interactive)
        .padding(.bottom, 14)
      }
    }
    .overlay { DeviceScreenshotOverlay(captures: model.captures, focusMode: model.focusMode) }
    .overlay {
      RecordingPreviewOverlay(reviews: model.developer.videoReview, focusMode: model.focusMode)
    }
    .onChange(of: scale) { _ in zoom.fit() }
    .overlay(alignment: .bottomTrailing) {
      if !model.focusMode {
        GeometryReader { geometry in
          VStack(alignment: .trailing, spacing: 8) {
            DeveloperActivityBadge(tools: model.developer)
            viewportZoomControls(compact: geometry.size.width < 560)
          }
          .padding(.horizontal, 16).padding(.bottom, 14)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
      }
    }
    .overlay(alignment: .top) {
      if model.focusMode {
        HStack {
          Spacer()
          Button {
            model.alwaysOnTop.toggle()
          } label: {
            Image(systemName: model.alwaysOnTop ? "pin.fill" : "pin")
              .font(.system(size: 11)).frame(width: 24, height: 24)
              .foregroundStyle(model.alwaysOnTop ? Color.accentColor : Color.secondary)
          }.buttonStyle(.plain).help("Always on Top").accessibilityLabel(
            model.alwaysOnTop ? "Turn off Always on Top" : "Keep window Always on Top")
          Button {
            model.setFocusMode(false)
          } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
              .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 24, height: 24)
          }.buttonStyle(.plain).help("Exit Focus mode (⇧⌘F or Esc)").accessibilityLabel(
            "Exit Focus mode")
        }.padding(.horizontal, 8).frame(height: FocusWindowGeometry.titlebarHeight)
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 16) {
            DeviceConnectionBar(model: model).fixedSize()
            Spacer(minLength: 0)
            viewportControls(compact: false)
          }
          HStack(alignment: .top, spacing: 12) {
            DeviceConnectionBar(model: model, compact: true).fixedSize()
            Spacer(minLength: 0)
            viewportControls(compact: true)
          }
          VStack(alignment: .leading, spacing: 8) {
            DeviceConnectionBar(model: model, compact: true).fixedSize()
            HStack {
              Spacer(minLength: 0)
              viewportControls(compact: true)
            }
          }
        }
        .padding(.horizontal, 16)
        // The canvas occupies the title-bar area when the sidebar is hidden.
        // Keep the entire header below the native window buttons in that mode.
        .padding(.top, model.showSidebar ? 16 : 48)
      }
    }
  }
  private func viewportControls(compact: Bool) -> some View {
    viewportToolbar(compact: compact).fixedSize()
  }
  private func viewportZoomControls(compact: Bool) -> some View {
    let fittedScale = fittedPixelScale
    return VStack(alignment: .trailing, spacing: 4) {
      Text(
        "\(Int((zoom.resolved(fittedScale: fittedScale) * 100).rounded()))%\(compact ? "" : " · ⌥ drag to pan")"
      )
      .font(.system(size: 9)).foregroundStyle(.secondary)
      HStack(spacing: 2) {
        CanvasButton(
          title: "Zoom out", symbol: "minus.magnifyingglass",
          enabled: zoom.resolved(fittedScale: fittedScale) > 0.1
        ) {
          zoom.step(inwards: false, fittedScale: fittedScale)
        }
        CanvasButton(title: "Fit device to canvas", symbol: "viewfinder") { zoom.fit() }
        if !compact {
          CanvasButton(
            title: "Actual size · one video pixel per display pixel", symbol: "1.magnifyingglass"
          ) { zoom.actualSize() }
        }
        CanvasButton(
          title: "Zoom in", symbol: "plus.magnifyingglass",
          enabled: zoom.resolved(fittedScale: fittedScale) < 4
        ) {
          zoom.step(inwards: true, fittedScale: fittedScale)
        }
      }.padding(4).studioGlass(20, clear: glass == "Clear", opaque: opaque)
    }.fixedSize()
  }
  private func viewportToolbar(compact: Bool) -> some View {
    HStack(spacing: 8) {
      HStack(spacing: 2) {
        if !compact {
          CanvasButton(title: "Developer tools (⇧⌘D)", symbol: "hammer") {
            model.developer.open(.apps)
          }
        }
        CanvasButton(title: "Show or hide sidebar", symbol: "sidebar.left") {
          model.showSidebar.toggle()
        }
      }.padding(4).studioGlass(20, clear: glass == "Clear", opaque: opaque)
      HStack(spacing: 2) {
        if !compact {
          CanvasButton(
            title: model.alwaysOnTop ? "Turn off Always on Top" : "Keep window Always on Top",
            symbol: model.alwaysOnTop ? "pin.fill" : "pin"
          ) { model.alwaysOnTop.toggle() }
          CanvasButton(
            title: "Enter Focus mode (⇧⌘F)", symbol: "arrow.down.right.and.arrow.up.left",
            enabled: !model.focusTransitioning
          ) {
            model.toggleFocusMode()
          }
        }
        Menu {
          Button("Developer tools…") { model.developer.open(.apps) }
          Button("Command palette…") { model.developer.openPalette() }
          Toggle("Always on Top", isOn: $model.alwaysOnTop)
          Divider()
          if compact {
            Button("Enter Focus mode") { model.toggleFocusMode() }.disabled(
              model.focusTransitioning)
            Divider()
          }
          Button("Fit device to canvas") { zoom.fit() }
          Button("Actual size (100%)") { zoom.actualSize() }
          Toggle("Device frame", isOn: $showFrame)
          Divider()
          Button("Power button") { model.key(26) }.disabled(!model.connected || !model.interactive)
          Button("Copy device text") { model.send(Data([8, 1])) }.disabled(
            !model.connected || !model.interactive)
          Button("Paste Mac clipboard") {
            if let text = NSPasteboard.general.string(forType: .string) {
              model.send(ControlPacket.paste(text))
            }
          }.disabled(!model.connected || !model.interactive)
          Divider()
          Button("Reconnect") { model.connect(reset: true) }.disabled(!model.canConnect)
          Button("Disconnect viewer") { model.disconnect() }.disabled(
            !model.connected && !model.connecting)
        } label: {
          Image(systemName: "ellipsis").font(.system(size: 14)).frame(width: 32, height: 30)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("More canvas and device controls").accessibilityLabel(
          "More canvas and device controls")
      }.padding(4).studioGlass(20, clear: glass == "Clear", opaque: opaque)
    }
  }
}

private struct DeviceConnectionBar: View {
  @ObservedObject var model: DeviceController
  var compact = false
  @State private var showWireless = false
  @State private var showEditor = false
  @State private var editingDevice: RemoteDeviceProfile?
  @AppStorage("studioGlass") private var glass = "Regular"
  @AppStorage("studioOpaque") private var opaque = false
  var body: some View {
    HStack(spacing: compact ? 6 : 8) {
      Menu {
        Button {
          model.selectSource(.local)
        } label: {
          Label(
            "This Mac · USB / Wi-Fi",
            systemImage: model.source == .local ? "checkmark" : "desktopcomputer")
        }
        Button {
          model.selectSource(.server)
        } label: {
          Label(
            "Server devices", systemImage: model.source == .server ? "checkmark" : "server.rack")
        }
        if model.source == .server {
          Divider()
          ForEach(model.servers, id: \.self) { server in
            Button {
              model.selectServer(server)
            } label: {
              if model.profile == server {
                Label(server, systemImage: "checkmark")
              } else {
                Text(server)
              }
            }
          }
          Button("Refresh servers") { model.loadServers() }
        }
      } label: {
        Group {
          if compact {
            Image(systemName: model.source == .local ? "desktopcomputer" : "server.rack")
          } else {
            Label(
              model.source.title,
              systemImage: model.source == .local ? "desktopcomputer" : "server.rack")
          }
        }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
      }.menuStyle(.borderlessButton).fixedSize()
        .help("Device source: \(model.source.title)").accessibilityLabel("Device source")
      Divider().frame(height: 14)
      Menu {
        if model.source == .local {
          ForEach(model.localDevices) { device in
            Button {
              model.selectLocalDevice(device.id)
            } label: {
              if device.id == model.selectedLocalID {
                Label("\(device.title) · \(device.status)", systemImage: "checkmark")
              } else {
                Text("\(device.title) · \(device.status)")
              }
            }
          }
          if model.localDevices.isEmpty {
            Text("Connect a phone with USB or use Wi-Fi in Device options.")
          }
        } else {
          ForEach(model.devices) { device in
            Button {
              model.selectDevice(device.id)
            } label: {
              if device.id == (model.isRunning ? model.activeDeviceID : model.selectedDeviceID) {
                Label(device.name, systemImage: "checkmark")
              } else {
                Text(device.name)
              }
            }.disabled(model.isRunning && device.id != model.activeDeviceID)
          }
          if model.isRunning {
            Divider()
            Text("Stop the device to switch profiles.")
          }
        }
      } label: {
        Text(model.deviceTitle).font(.system(size: 12, weight: .medium))
          .lineLimit(1).truncationMode(.middle)
          .frame(width: compact ? 100 : 160, alignment: .leading)
      }.menuStyle(.borderlessButton).help(model.deviceTitle).accessibilityLabel("Device switcher")
      DeviceBatteryBadge(battery: model.developer.battery)
      Button {
        model.refreshDevices()
      } label: {
        Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 22, height: 24)
      }.buttonStyle(.plain).help("Refresh devices").accessibilityLabel("Refresh devices")
      Menu {
        Button(model.connected || model.connecting ? "Disconnect viewer" : "Connect viewer") {
          if model.connected || model.connecting {
            model.disconnect()
          } else {
            model.connect(reset: true)
          }
        }.disabled(!model.canConnect && !model.connected && !model.connecting)
        Button("Reconnect viewer") { model.connect(reset: true) }.disabled(!model.canConnect)
        Toggle("Reconnect automatically", isOn: $model.autoReconnect)
        Divider()
        if model.source == .local {
          Button("Connect over Wi-Fi…") {
            model.wirelessMessage = ""
            showWireless = true
          }
          if let device = model.selectedLocalDevice { Text("Connection: \(device.status)") }
        } else {
          Button(model.isRunning ? "Stop device" : "Start device") {
            model.action(model.isRunning ? "device-stop" : "start")
          }.disabled(model.selectedDevice == nil)
          Divider()
          Button("New profile…") {
            editingDevice = nil
            showEditor = true
          }
          .disabled(model.isRunning || model.profile == nil)
          Button("Edit profile…") {
            editingDevice = model.selectedDevice
            showEditor = true
          }
          .disabled(model.selectedDevice == nil || model.isRunning)
          Button("Device logs") { model.action("device-logs") }
          Button("Check setup") { model.action("doctor") }
          if let device = model.displayedDevice {
            Menu("Device details") {
              Text("\(device.cores) CPU cores · \(device.memory_mb) MiB RAM")
              Text(device.avd)
            }
          }
        }
        if !model.localSerial.isEmpty {
          Button("Copy ADB device serial") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.localSerial, forType: .string)
          }
        }
        Divider()
        Button("Viewer diagnostics") { model.diagnostics() }
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 22, height: 24)
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Device options").accessibilityLabel("Device connection options")
      if model.busy || model.wirelessBusy { ProgressView().controlSize(.mini) }
    }
    .padding(.horizontal, compact ? 8 : 12).padding(.vertical, 4)
    .studioGlass(24, clear: glass == "Clear", opaque: opaque)
    .disabled(model.busy || model.wirelessBusy)
    .sheet(isPresented: $showWireless) { WirelessDeviceSheet(model: model) }
    .sheet(isPresented: $showEditor) { DeviceProfileEditor(model: model, existing: editingDevice) }
  }
}

private struct CanvasButton: View {
  let title: String
  let symbol: String
  var enabled = true
  let action: () -> Void
  @State private var hovering: Bool = false
  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 14, weight: .regular))
        .foregroundStyle(.primary.opacity(enabled ? 0.76 : 0.25))
        .frame(width: 32, height: 30)
        .background(
          .primary.opacity(hovering && enabled ? 0.065 : 0), in: RoundedRectangle(cornerRadius: 12))
    }.buttonStyle(.plain).disabled(!enabled).help(title).accessibilityLabel(title)
      .onHover { hovering = $0 }
  }
}

private struct RotatingDeviceSnapshot: View {
  @ObservedObject var model: DeviceController
  let rotation: DeviceRotationPresentation
  let from: DeviceFrameLayout
  let to: DeviceFrameLayout
  let framed: Bool
  let silver: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var turned = false
  var body: some View {
    HardwareDevice(
      model: model, layout: from, framed: framed, silver: silver, snapshot: rotation.image
    )
    .rotationEffect(
      .degrees(!reduceMotion && turned ? DeviceRotationGeometry.angle(from: from) : 0)
    )
    .scaleEffect(!reduceMotion && turned ? DeviceRotationGeometry.scale(from: from, to: to) : 1)
    .frame(width: to.width, height: to.height)
    .allowsHitTesting(false).accessibilityHidden(true)
    .onAppear {
      if !reduceMotion {
        withAnimation(.spring(response: 0.46, dampingFraction: 0.9)) { turned = true }
      }
    }
  }
}

private struct HardwareDevice: View {
  @ObservedObject var model: DeviceController
  let layout: DeviceFrameLayout
  let framed: Bool
  let silver: Bool
  var snapshot: NSImage? = nil
  @Environment(\.colorScheme) private var colorScheme
  private var classic: Bool { false }
  private var landscape: Bool { layout.width > layout.height }
  private var edge: Color { silver ? Color(white: 0.72) : Color(white: 0.20) }
  var body: some View {
    ZStack {
      if framed {
        RoundedRectangle(cornerRadius: layout.bodyRadius, style: .continuous)
          .fill(
            LinearGradient(
              colors: [Color(white: 0.58), edge, Color(white: 0.08), edge, Color(white: 0.48)],
              startPoint: .topLeading, endPoint: .bottomTrailing)
          )
          .overlay(
            RoundedRectangle(cornerRadius: layout.bodyRadius, style: .continuous)
              .strokeBorder(
                LinearGradient(
                  colors: [.white.opacity(0.7), .black.opacity(0.7), .white.opacity(0.4)],
                  startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
          )
          .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.13), radius: 16, x: 0, y: 12)
        RoundedRectangle(cornerRadius: max(2, layout.bodyRadius - 3), style: .continuous)
          .fill(silver && classic ? Color(white: 0.91) : Color(white: 0.045))
          .padding(3)
          .overlay(
            RoundedRectangle(cornerRadius: max(2, layout.bodyRadius - 2), style: .continuous)
              .strokeBorder(.white.opacity(0.12), lineWidth: 0.6).padding(2))
        if classic { classicHardware }
        sideKeys
      }
      ZStack {
        if let snapshot {
          Image(nsImage: snapshot).resizable().interpolation(.high).scaledToFit().background(.black)
        } else {
          DeviceSurface(controller: model, cornerRadius: framed ? layout.screenRadius : 2)
          if !model.connected { placeholder }
        }
      }
      .frame(width: layout.screenWidth, height: layout.screenHeight)
      .clipShape(
        RoundedRectangle(cornerRadius: framed ? layout.screenRadius : 2, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: framed ? layout.screenRadius : 2, style: .continuous)
          .strokeBorder(.black.opacity(0.8), lineWidth: 0.7).allowsHitTesting(false))
      if framed {
        let short = min(layout.screenWidth, layout.screenHeight)
        Circle().fill(.black).overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 0.6))
          .frame(width: short * 0.034, height: short * 0.034)
          .offset(
            x: landscape ? -layout.screenWidth / 2 + short * 0.055 : 0,
            y: landscape ? 0 : -layout.screenHeight / 2 + short * 0.055
          )
          .allowsHitTesting(false)
      }
    }.frame(width: layout.width, height: layout.height)
  }
  private var classicHardware: some View {
    let short = min(layout.screenWidth, layout.screenHeight)
    return HStack(spacing: short * 0.09) {
      Circle().fill(Color(white: 0.025))
        .overlay(
          Circle().fill(
            LinearGradient(
              colors: [Color(red: 0.12, green: 0.18, blue: 0.26), .black], startPoint: .topLeading,
              endPoint: .bottomTrailing)
          ).padding(2)
        )
        .overlay(Circle().strokeBorder(.white.opacity(0.13), lineWidth: 0.5))
        .frame(width: short * 0.034, height: short * 0.034)
      Capsule().fill(.black.opacity(0.8)).frame(width: short * 0.20, height: short * 0.013)
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
      Circle().fill(.black.opacity(0.4)).frame(width: short * 0.012, height: short * 0.012)
    }
    .rotationEffect(.degrees(landscape ? -90 : 0))
    .offset(
      x: landscape ? -layout.width / 2 + layout.insetX * 0.48 : 0,
      y: landscape ? 0 : -layout.height / 2 + layout.insetY * 0.48
    )
    .allowsHitTesting(false)
  }
  private var sideKeys: some View {
    let short = min(layout.screenWidth, layout.screenHeight)
    let portraitWidth = min(layout.width, layout.height)
    let portraitHeight = max(layout.width, layout.height)
    return ZStack {
      RoundedRectangle(cornerRadius: 1).fill(edge.gradient)
        .frame(width: 2.5, height: short * 0.12)
        .offset(x: portraitWidth / 2 + 0.8, y: -portraitHeight * 0.23)
      RoundedRectangle(cornerRadius: 1).fill(edge.gradient)
        .frame(width: 2.5, height: short * 0.22)
        .offset(x: portraitWidth / 2 + 0.8, y: -portraitHeight * 0.09)
    }.frame(width: portraitWidth, height: portraitHeight)
      .rotationEffect(.degrees(landscape ? -90 : 0))
      .frame(width: layout.width, height: layout.height).allowsHitTesting(false)
  }
  private var placeholder: some View {
    VStack(spacing: 14) {
      Image(systemName: model.connecting ? "antenna.radiowaves.left.and.right" : "iphone")
        .font(.system(size: 28, weight: .ultraLight)).foregroundStyle(.white.opacity(0.75))
      Text(model.connecting ? "Connecting to Android" : "Your device, remotely.")
        .font(.system(size: 14, weight: .medium))
      Text(model.state)
        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(
          .center
        ).lineLimit(5)
      if model.connecting {
        ProgressView().controlSize(.small).tint(.white)
      } else {
        Button(
          model.source == .local
            ? (model.canConnect ? "Connect phone" : "Refresh phones")
            : model.profile == nil
              ? "Refresh servers" : model.isRunning ? "Connect" : "Start device"
        ) {
          if model.source == .local {
            if model.canConnect { model.connect(reset: true) } else { model.refreshDevices() }
          } else if model.profile == nil {
            model.loadServers()
          } else if model.isRunning {
            model.connect(reset: true)
          } else {
            model.action("start")
          }
        }.disabled(
          model.busy
            || (model.source == .server && model.profile != nil && model.selectedDevice == nil)
        ).buttonStyle(
          .bordered
        ).controlSize(.small)
      }
    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
      .foregroundStyle(.white).background(Color(white: 0.055))
  }
}

private struct WirelessDeviceSheet: View {
  @ObservedObject var model: DeviceController
  @Environment(\.dismiss) private var dismiss
  @State private var pairingAddress = ""
  @State private var pairingCode = ""
  @State private var connectionAddress = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Connect a phone over Wi-Fi").font(.title3.weight(.semibold))
      Text(
        "On your Android 11+ phone, open Developer options → Wireless debugging. Connect the phone and Mac to the same network."
      )
      .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      GroupBox("1. Pair this Mac") {
        VStack(alignment: .leading, spacing: 10) {
          Text(
            "Tap ‘Pair device with pairing code’ on the phone. Enter that screen’s address and six-digit code."
          )
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          TextField("Pairing address, e.g. 192.168.1.20:37123", text: $pairingAddress)
            .accessibilityLabel("Pairing address and port")
          SecureField("Six-digit pairing code", text: $pairingCode)
          Button("Pair") {
            model.wirelessAction(pair: true, address: pairingAddress, code: pairingCode)
            pairingCode = ""
          }.disabled(model.wirelessBusy || pairingAddress.isEmpty || pairingCode.isEmpty)
        }.padding(8)
      }
      GroupBox("2. Connect") {
        VStack(alignment: .leading, spacing: 10) {
          Text(
            "Use the IP address and port on the main Wireless debugging screen. The connection port is different from the pairing port. Already paired? Start here."
          )
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          TextField("Connection address, e.g. 192.168.1.20:42157", text: $connectionAddress)
            .accessibilityLabel("Connection address and port")
          Button("Connect phone") {
            model.wirelessAction(pair: false, address: connectionAddress)
          }.disabled(model.wirelessBusy || connectionAddress.isEmpty)
        }.padding(8)
      }
      if !model.wirelessMessage.isEmpty {
        HStack(alignment: .top, spacing: 8) {
          if model.wirelessBusy { ProgressView().controlSize(.small) }
          Text(model.wirelessMessage).font(.callout).textSelection(.enabled)
        }
      }
      HStack {
        Text("USB needs no Wi-Fi pairing; approve the debugging prompt on the phone.")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.wirelessBusy)
      }
    }.padding(24).frame(width: 460).textFieldStyle(.roundedBorder)
      .interactiveDismissDisabled(model.wirelessBusy)
  }
}

private struct DeviceInspector: View {
  @ObservedObject var model: DeviceController
  @State private var performanceOpen: Bool = true
  @State private var streamDetailsOpen: Bool = false
  @State private var simulatorOpen: Bool = true
  @State private var activityOpen: Bool = true
  @AppStorage("studioAppearance") private var appearance = "Light"
  @AppStorage("studioFinish") private var finish = "Graphite"
  @AppStorage("studioGlass") private var glass = "Regular"
  @AppStorage("studioFrame") private var showFrame = true
  @AppStorage("studioScale") private var scale = "Fit"
  @AppStorage("studioOpaque") private var opaque = false
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 9) {
        Image(systemName: "square.stack.3d.up.fill").font(.system(size: 17)).foregroundStyle(
          .primary.opacity(0.8))
        Text("Okestra Device").font(.system(size: 17, weight: .semibold)).tracking(-0.5)
        Spacer()
      }.padding(.horizontal, 18).padding(.top, 38).padding(.bottom, 19)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          sectionHeader("Stream performance", expanded: $performanceOpen)
          if performanceOpen { performance.padding(.top, 15) }
          separator
          DeviceNetworkSidebar(monitor: model.developer.network)
          separator
          DeviceAudioSidebar(tools: model.developer)
          separator
          sectionHeader("Appearance", expanded: $simulatorOpen)
          if simulatorOpen { simulator.padding(.top, 16) }
          if !model.output.isEmpty {
            separator
            activity
          }
          Spacer(minLength: 18)
        }.padding(.horizontal, 18).padding(.bottom, 20)
      }.scrollIndicators(.hidden)
        .modifier(SidebarStatusBar { connectionStatus })
    }
  }
  private var connectionStatus: some View {
    HStack(spacing: 6) {
      Circle().fill(model.connected ? Studio.green : .orange).frame(width: 5, height: 5)
      Text(
        model.connected
          ? "Connected to Android" : model.connecting ? "Connecting…" : "Device offline"
      )
      .font(.system(size: 10)).foregroundStyle(.secondary)
      Spacer()
      if model.busy {
        ProgressView().controlSize(.mini)
      } else {
        Image(systemName: "network").font(.system(size: 11)).foregroundStyle(.tertiary)
      }
    }.padding(.horizontal, 18).padding(.vertical, 13)
      .frame(maxWidth: .infinity)
  }
  private var separator: some View { Divider().opacity(0.55).padding(.vertical, 21) }
  private func sectionHeader(_ title: String, expanded: Binding<Bool>) -> some View {
    Button {
      expanded.wrappedValue.toggle()
    } label: {
      HStack {
        Text(title).font(.system(size: 12, weight: .semibold))
        Spacer()
        Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right").font(
          .system(size: 9, weight: .medium)
        ).foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(
      expanded.wrappedValue ? "Expanded" : "Collapsed")
  }
  private var displayedStreamMode: StreamMode {
    model.connected || model.connecting
      ? model.effectiveStreamMode : model.streamMode == .automatic ? .balanced : model.streamMode
  }
  private var performance: some View {
    VStack(spacing: 13) {
      StreamMetric(
        title: "Frame rate", value: model.connected ? String(format: "%.0f fps", model.fps) : "—",
        values: model.fpsHistory,
        ceiling: displayedStreamMode.configuration.maxFPS > 0
          ? Double(displayedStreamMode.configuration.maxFPS) : 60,
        color: Studio.green)
      StreamMetric(
        title: "Video bitrate",
        value: model.connected ? String(format: "%.2f Mbps", model.megabits) : "—",
        values: model.bitrateHistory,
        ceiling: Double(displayedStreamMode.configuration.bitRate) / 1_000_000,
        color: Studio.blue)
      VStack(alignment: .leading, spacing: 9) {
        HStack {
          Text("Quality").font(.system(size: 11, weight: .medium))
          Spacer()
          Menu {
            ForEach(StreamMode.allCases, id: \.rawValue) { mode in
              Button {
                model.setStreamMode(mode)
              } label: {
                if model.streamMode == mode {
                  Label(mode.title, systemImage: "checkmark")
                } else {
                  Text(mode.title)
                }
              }
            }
          } label: {
            Text(model.streamMode.title).font(.system(size: 11))
          }
          .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Stream quality")
        }
        HStack(spacing: 4) {
          if model.streamMode == .automatic {
            Text(model.effectiveStreamMode.title)
            Text("·")
          }
          Text(displayedStreamMode.configuration.summary)
          Spacer()
          Text("H.264").monospaced()
        }.font(.system(size: 9)).foregroundStyle(.tertiary)
      }
      .padding(10).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
      VStack(alignment: .leading, spacing: 10) {
        Button {
          streamDetailsOpen.toggle()
        } label: {
          HStack {
            Text("Stream details")
            Spacer()
            Image(systemName: streamDetailsOpen ? "chevron.up" : "chevron.down")
              .font(.system(size: 8, weight: .medium))
          }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
        .accessibilityLabel("Stream details")
        .accessibilityValue(streamDetailsOpen ? "Expanded" : "Collapsed")
        if streamDetailsOpen {
          VStack(spacing: 7) {
            diagnosticRow("Received", value: String(format: "%.0f fps", model.receivedFPS))
            diagnosticRow("Decode", value: String(format: "%.1f ms", model.decodeMS))
            diagnosticRow("UI wait", value: String(format: "%.1f ms", model.uiWaitMS))
            diagnosticRow("Backlog growth", value: String(format: "%.0f ms", model.backlogMS))
              .help("Estimated delay growth since connection; not total network latency.")
            diagnosticRow(
              "Decoder", value: model.hardwareDecoder.map { $0 ? "Hardware" : "Software" } ?? "—")
          }
        }
      }.padding(.horizontal, 2).padding(.top, 2)
    }
  }
  private func diagnosticRow(_ title: String, value: String) -> some View {
    HStack {
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Text(value).monospacedDigit()
    }.font(.system(size: 10))
  }
  private var simulator: some View {
    VStack(spacing: 19) {
      valueRow(
        "Workspace", value: appearance, choices: ["Light", "Dark", "System"], selection: $appearance
      )
      valueRow("Liquid Glass", value: glass, choices: ["Regular", "Clear"], selection: $glass)
      valueRow("Frame finish", value: finish, choices: ["Graphite", "Silver"], selection: $finish)
      valueRow("Device scale", value: scale, choices: ["Fit", "Compact"], selection: $scale)
      switchRow("Interactive", selection: $model.interactive)
      switchRow("Device frame", selection: $showFrame)
      switchRow("Reduce transparency", selection: $opaque)
      VStack(alignment: .leading, spacing: 7) {
        Divider().opacity(0.5).padding(.bottom, 3)
        Text("DISPLAY").font(.system(size: 8, weight: .medium)).tracking(1.3).foregroundStyle(
          .tertiary)
        HStack {
          Text(
            model.identity.nativeWidth > 0
              ? "\(model.identity.nativeWidth) × \(model.identity.nativeHeight)"
              : "Waiting for device")
          Spacer()
          Text("Native").foregroundStyle(.tertiary)
        }.font(.system(size: 10)).foregroundStyle(.secondary)
        HStack {
          Text("\(Int(model.renderedSize.width)) × \(Int(model.renderedSize.height))")
          Spacer()
          Text("Stream").foregroundStyle(.tertiary)
        }.font(.system(size: 10)).foregroundStyle(.secondary)
        if !model.identity.avd.isEmpty {
          Text(model.identity.avd).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
        }
      }
    }.font(.system(size: 12)).toggleStyle(.switch).controlSize(.mini)
  }
  private func switchRow(_ title: String, selection: Binding<Bool>) -> some View {
    HStack {
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Toggle(title, isOn: selection).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        .fixedSize()
    }.frame(maxWidth: .infinity)
  }
  private func valueRow(
    _ label: String, value: String, choices: [String], selection: Binding<String>
  ) -> some View {
    HStack {
      Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
      Spacer()
      Menu {
        ForEach(choices, id: \.self) { item in
          Button {
            selection.wrappedValue = item
          } label: {
            if value == item { Label(item, systemImage: "checkmark") } else { Text(item) }
          }
        }
      } label: {
        HStack(spacing: 7) {
          Text(value).font(.system(size: 11))
        }
        .padding(.horizontal, 9).padding(.vertical, 6).background(
          .primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.055), lineWidth: 0.5))
      }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel(label)
    }
  }
  private var activity: some View {
    VStack(alignment: .leading, spacing: 14) {
      sectionHeader("Activity", expanded: $activityOpen)
      if activityOpen {
        if model.output.isEmpty {
          Text("Device logs and diagnostics appear here.").font(.system(size: 11)).foregroundStyle(
            .tertiary
          ).padding(.vertical, 10)
        } else {
          Text(model.output).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
          HStack {
            Button("Copy") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(model.output, forType: .string)
            }
            Spacer()
            Button("Clear") { model.output = "" }
          }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary)
        }
      }
    }
  }
}

private struct SidebarStatusBar<Footer: View>: ViewModifier {
  let footer: Footer
  init(@ViewBuilder footer: () -> Footer) { self.footer = footer() }
  @ViewBuilder func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.safeAreaBar(edge: .bottom, spacing: 0) { footer }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    } else {
      content.overlay(alignment: .bottom) {
        footer.background(alignment: .bottom) {
          Rectangle().fill(.regularMaterial).frame(height: 78)
            .mask(
              LinearGradient(
                stops: [
                  .init(color: .clear, location: 0),
                  .init(color: .black.opacity(0.65), location: 0.4),
                  .init(color: .black, location: 0.75),
                ], startPoint: .top, endPoint: .bottom)
            )
            .allowsHitTesting(false)
        }
      }
    }
  }
}

private struct StreamMetric: View {
  let title: String
  let value: String
  let values: [Double]
  let ceiling: Double
  let color: Color
  var body: some View {
    VStack(spacing: 0) {
      GeometryReader { g in
        let points = values.enumerated().map { index, value in
          CGPoint(
            x: g.size.width * Double(index) / Double(max(1, values.count - 1)),
            y: g.size.height - 6 - min(1, max(0, value) / max(ceiling, values.max() ?? ceiling))
              * (g.size.height - 12))
        }
        Path { p in
          guard let first = points.first, let last = points.last else { return }
          p.move(to: first)
          for point in points.dropFirst() { p.addLine(to: point) }
          p.addLine(to: CGPoint(x: last.x, y: g.size.height))
          p.addLine(to: CGPoint(x: first.x, y: g.size.height))
          p.closeSubpath()
        }.fill(
          LinearGradient(
            colors: [color.opacity(0.23), color.opacity(0.01)], startPoint: .top, endPoint: .bottom)
        )
        Path { $0.addLines(points) }.stroke(
          color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
      }.frame(height: 53).clipped().padding(.top, 3)
      HStack {
        Text(title).foregroundStyle(.secondary)
        Spacer()
        Text(value).monospacedDigit()
      }
      .font(.system(size: 10)).padding(.horizontal, 9).padding(.vertical, 8)
    }.background(.primary.opacity(0.022), in: RoundedRectangle(cornerRadius: 9))
      .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(value)
  }
}

struct DeviceToolsWindow: View {
  @ObservedObject var model: DeviceController
  @AppStorage("studioAppearance") private var appearance = "Light"
  @AppStorage("studioOpaque") private var opaque = false
  @AppStorage("studioGlass") private var glass = "Regular"
  var body: some View {
    DeviceInspector(model: model).studioGlass(18, clear: glass == "Clear", opaque: opaque).padding(
      8
    )
    .frame(minWidth: 278, idealWidth: 300, maxWidth: 400, minHeight: 620)
    .toolbar(.hidden)
    .background(StudioWindowChrome())
    .ignoresSafeArea(.container, edges: .top)
    .preferredColorScheme(appearance == "System" ? nil : appearance == "Dark" ? .dark : .light)
  }
}
struct ShowToolsCommand: View {
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    Button("Device Tools") { openWindow(id: "tools") }.keyboardShortcut(
      "t", modifiers: [.command, .shift])
  }
}
private struct StudioWindowChrome: NSViewRepresentable {
  var controller: DeviceController? = nil
  func makeNSView(context: Context) -> ChromeView {
    let view = ChromeView()
    view.controller = controller
    return view
  }
  func updateNSView(_ nsView: ChromeView, context: Context) {
    nsView.controller = controller
    if let window = nsView.window { controller?.viewerWindow = window }
  }
  final class ChromeView: NSView {
    weak var controller: DeviceController?
    private var configured = false
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window, !configured else { return }
      controller?.viewerWindow = window
      configured = true
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.styleMask.insert(.fullSizeContentView)
      // NavigationSplitView installs an empty toolbar even after its items are hidden.
      // Remove that toolbar's height while retaining the standard window controls.
      DispatchQueue.main.async { [weak window] in
        guard let window else { return }
        window.toolbar = nil
        window.titlebarSeparatorStyle = .none
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
          window.standardWindowButton(kind)?.isHidden = false
        }
      }
      window.isMovableByWindowBackground = true
      window.setFrameAutosaveName("OkestraStudio-v2")
    }
  }
}

private struct NativeSidebarToolbar: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    if #available(macOS 14.0, *) {
      content.toolbar(removing: .sidebarToggle)
    } else {
      content
    }
  }
}

private struct DeviceProfileEditor: View {
  @ObservedObject var model: DeviceController
  let existing: RemoteDeviceProfile?
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var hardware: String
  @State private var cores: Int
  @State private var memory: Int
  init(model: DeviceController, existing: RemoteDeviceProfile?) {
    self.model = model
    self.existing = existing
    _name = State(initialValue: existing?.name ?? "Pixel 7")
    _hardware = State(initialValue: existing?.hardware ?? "pixel_7")
    _cores = State(initialValue: existing?.cores ?? 2)
    _memory = State(initialValue: existing?.memory_mb ?? 2048)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(existing == nil ? "New device profile" : "Edit device profile").font(
        .title3.weight(.semibold))
      Form {
        TextField("Name", text: $name)
        if existing == nil {
          Picker("Phone", selection: $hardware) {
            Text("Google Pixel 7").tag("pixel_7")
            Text("Google Pixel 9").tag("pixel_9")
          }
        } else if let existing {
          LabeledContent("AVD", value: existing.avd)
        }
        Stepper("CPU cores: \(cores)", value: $cores, in: 1...8)
        Picker("RAM", selection: $memory) {
          ForEach(Array(Set([1536, 2048, 3072, 4096, 6144, 8192, memory])).sorted(), id: \.self) {
            value in
            Text("\(value) MiB").tag(value)
          }
        }
      }.formStyle(.grouped)
        .onChange(of: hardware) { value in
          if existing == nil && ["Pixel 7", "Pixel 9"].contains(name) {
            name = value == "pixel_9" ? "Pixel 9" : "Pixel 7"
          }
        }
      Text(
        "CPU and RAM are allocated on the server. Each AVD retains its installed apps and data. One emulator can run at a time."
      )
      .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(
        horizontal: false, vertical: true)
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(existing == nil ? "Create profile" : "Save") {
          model.saveDevice(
            existing: existing, name: name, hardware: hardware, cores: cores, memory: memory)
          dismiss()
        }.keyboardShortcut(.defaultAction).disabled(
          name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80
            || model.busy)
      }
    }.padding(22).frame(width: 400)
  }
}
