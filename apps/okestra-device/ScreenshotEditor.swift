import AppKit
import SwiftUI

enum ScreenshotClipboard {
  @MainActor static func write(_ png: Data, to pasteboard: NSPasteboard = .general) -> Bool {
    let item = NSPasteboardItem()
    item.setData(png, forType: .png)
    if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
    pasteboard.clearContents()
    return pasteboard.writeObjects([item])
  }
}

struct ScreenshotEditorPresentation: ViewModifier {
  @ObservedObject var captures: DeviceScreenshotController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func body(content: Content) -> some View {
    ZStack {
      content.allowsHitTesting(captures.editor == nil).accessibilityHidden(captures.editor != nil)
      if let editor = captures.editor {
        ScreenshotEditor(model: editor)
          .id(editor.id)
          .transition(
            reduceMotion
              ? .opacity : .opacity.combined(with: .scale(scale: 0.94, anchor: .bottomTrailing))
          )
          .zIndex(10)
      }
    }
    .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.25), value: captures.editor?.id)
  }
}

struct ScreenshotEditor: View {
  @ObservedObject var model: ScreenshotEditorModel
  @FocusState private var textFocused: Bool
  private var activeTool: ScreenshotMarkupTool {
    model.tool == .select ? model.selectedMark?.tool ?? .select : model.tool
  }
  var body: some View {
    VStack(spacing: 0) {
      header.padding(.horizontal, 14).padding(.top, 38).padding(.bottom, 12)
      Divider()
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 16) {
          toolPicker
          Divider().frame(height: 18)
          properties
          Spacer(minLength: 0)
        }
        VStack(alignment: .leading, spacing: 10) {
          toolPicker
          HStack {
            properties
            Spacer(minLength: 0)
          }
        }
      }.padding(.horizontal, 14).padding(.vertical, 10)
      Divider()
      ScreenshotMarkupSurface(model: model)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceCanvasBackground())
      Divider()
      footer.padding(.horizontal, 12).padding(.vertical, 8)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .ignoresSafeArea(.container, edges: .top)
    .background(ScreenshotEditorWindowActions(model: model))
    .onExitCommand { model.requestClose() }
    .onChange(of: model.textOptionsRequested) { visible in
      if !visible {
        model.updateText()
        model.focusCanvas()
      }
    }
    .alert("Save changes to this screenshot?", isPresented: $model.confirmClose) {
      Button("Save") { model.saveAndClose() }
      Button("Cancel", role: .cancel) { model.cancelClose() }
      Button("Discard Changes", role: .destructive) { model.discardAndClose() }
    } message: {
      Text("Your annotations haven’t been saved or copied yet.")
    }
  }
  private var header: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        Image(systemName: "photo").font(.system(size: 18)).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(model.title).font(.system(size: 13, weight: .semibold))
          Text(
            model.needsExport
              ? "Edited" : model.savedFile == nil ? "Original capture" : "Saved copy"
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }.fixedSize()
        Spacer(minLength: 8)
        historyButtons
        Divider().frame(height: 18)
        copyButton(compact: false)
        saveMenu
        doneButton
      }
      HStack(spacing: 8) {
        historyButtons
        Spacer(minLength: 2)
        copyButton(compact: true)
        saveMenu
        doneButton
      }
    }
    .controlSize(.small).disabled(model.exporting)
  }
  private var historyButtons: some View {
    HStack(spacing: 8) {
      Button {
        model.undo()
      } label: {
        Image(systemName: "arrow.uturn.backward")
      }
      .disabled(!model.canUndo).help("Undo (⌘Z)").accessibilityLabel("Undo annotation")
      Button {
        model.redo()
      } label: {
        Image(systemName: "arrow.uturn.forward")
      }
      .disabled(!model.canRedo).help("Redo (⇧⌘Z)").accessibilityLabel("Redo annotation")
    }.buttonStyle(.borderless)
  }
  private func copyButton(compact: Bool) -> some View {
    Button {
      model.copy()
    } label: {
      if compact {
        Image(systemName: model.copied ? "checkmark" : "doc.on.doc")
      } else {
        Label(
          model.copied ? "Copied" : "Copy", systemImage: model.copied ? "checkmark" : "doc.on.doc")
      }
    }.help("Copy edited image (⌘C)").accessibilityLabel("Copy edited screenshot")
  }
  private var saveMenu: some View {
    Menu {
      Button("Save a Copy…") { model.saveAs() }
      if let file = model.savedFile {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
      }
    } label: {
      Text("Save")
    } primaryAction: {
      model.save()
    }
    .help("Save edited image (⌘S) · Menu for Save a Copy")
    .accessibilityLabel("Save edited screenshot")
  }
  private var doneButton: some View {
    Button("Done") { model.requestClose() }.buttonStyle(.borderedProminent)
      .help("Return to the device (Esc)").accessibilityLabel("Close screenshot editor")
  }
  private var toolPicker: some View {
    Picker("Annotation tool", selection: $model.tool) {
      ForEach(ScreenshotMarkupTool.allCases) { tool in
        Image(systemName: tool.symbol).tag(tool).help(tool.rawValue)
          .accessibilityLabel(tool.rawValue)
      }
    }.pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.regular)
      .disabled(model.exporting)
  }
  private var properties: some View {
    HStack(spacing: 10) {
      if activeTool != .redact && activeTool != .select {
        Menu {
          Picker("Color", selection: Binding(get: { model.color }, set: { model.setColor($0) })) {
            ForEach(ScreenshotMarkupColor.allCases) { color in Text(color.rawValue).tag(color) }
          }
        } label: {
          HStack(spacing: 5) {
            Circle().fill(Color(nsColor: model.color.nsColor)).frame(width: 10, height: 10)
              .overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.5))
            Text("Color")
          }
        }.fixedSize().help("Annotation color").accessibilityLabel("Annotation color")
      }
      if [.pen, .arrow, .box].contains(activeTool) {
        Picker("Weight", selection: Binding(get: { model.stroke }, set: { model.setStroke($0) })) {
          ForEach(ScreenshotStroke.allCases) { weight in Text(weight.rawValue).tag(weight) }
        }.labelsHidden().fixedSize().help("Line weight").accessibilityLabel("Line weight")
      }
      if activeTool == .text {
        Button {
          model.textOptionsRequested.toggle()
        } label: {
          Label("Text", systemImage: "text.cursor")
        }
        .popover(isPresented: $model.textOptionsRequested) { textOptions }
        .help("Text content and size").accessibilityLabel("Text options")
      }
      if activeTool == .redact {
        Label("Solid redaction", systemImage: "lock.fill").foregroundStyle(.secondary).fixedSize()
      }
      if model.tool == .select && model.selectedID != nil {
        Button {
          model.deleteSelection()
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless).help("Delete selected annotation (⌫)")
        .accessibilityLabel("Delete annotation")
      }
      if activeTool == .select {
        Text("Select an annotation").foregroundStyle(.secondary).fixedSize()
      }
    }.font(.system(size: 11)).controlSize(.small).disabled(model.exporting)
  }
  private var textOptions: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.tool == .select ? "Edit text" : "Text annotation").fontWeight(.semibold)
      TextField("Type your annotation", text: $model.label)
        .textFieldStyle(.roundedBorder).accessibilityLabel("Annotation text").focused($textFocused)
        .onAppear { textFocused = true }
        .onSubmit {
          model.updateText()
          model.textOptionsRequested = false
        }
      Picker("Size", selection: Binding(get: { model.textSize }, set: { model.setTextSize($0) })) {
        ForEach(ScreenshotTextSize.allCases) { size in Text(size.rawValue).tag(size) }
      }.pickerStyle(.segmented)
      HStack {
        Text(
          model.tool == .select
            ? "Changes apply to the selected label." : "Click the image to place your label."
        )
        .font(.system(size: 10)).foregroundStyle(.secondary)
        Spacer()
        Button("Done") {
          model.updateText()
          model.textOptionsRequested = false
        }.keyboardShortcut(.defaultAction)
      }
    }.padding(16).frame(width: 270).font(.system(size: 12))
  }
  private var footer: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        status
        Spacer(minLength: 0)
        dimensions
        zoomControls
      }
      HStack(spacing: 8) {
        status
        Spacer(minLength: 0)
        zoomControls
      }
    }.font(.system(size: 10))
  }
  private var status: some View {
    HStack(spacing: 6) {
      if model.exporting {
        ProgressView().controlSize(.mini)
      } else if model.failed {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      }
      Text(model.message.isEmpty ? model.instruction : model.message)
        .foregroundStyle(model.failed ? Color.primary : Color.secondary)
        .lineLimit(1).truncationMode(.tail)
        .help(model.message.isEmpty ? model.instruction : model.message)
    }.frame(minWidth: 0, alignment: .leading)
  }
  private var dimensions: some View {
    Text("\(Int(model.image.size.width)) × \(Int(model.image.size.height))")
      .foregroundStyle(.tertiary).monospacedDigit().fixedSize()
  }
  private var zoomControls: some View {
    HStack(spacing: 8) {
      Button {
        model.stepZoom(false)
      } label: {
        Image(systemName: "minus.magnifyingglass")
      }
      .help("Zoom out (⌘−)").accessibilityLabel("Zoom out screenshot")
      Menu {
        Button("Fit to Window") { model.zoom = nil }
        Button("Actual Size (100%)") { model.zoom = 1 }
      } label: {
        Text(
          model.zoom == nil ? "Fit" : "\(Int(((model.zoom ?? model.fittedZoom) * 100).rounded()))%"
        )
        .monospacedDigit().frame(minWidth: 28)
      }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Screenshot zoom")
      Button {
        model.stepZoom(true)
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }
      .help("Zoom in (⌘+)").accessibilityLabel("Zoom in screenshot")
    }.buttonStyle(.borderless).fixedSize()
  }
}

private struct ScreenshotMarkupSurface: NSViewRepresentable {
  @ObservedObject var model: ScreenshotEditorModel
  func makeNSView(context: Context) -> ScreenshotMarkupScrollView {
    ScreenshotMarkupScrollView(model: model)
  }
  func updateNSView(_ view: ScreenshotMarkupScrollView, context: Context) {
    view.canvas.model = model
    view.updateCanvas()
    view.canvas.needsDisplay = true
    view.window?.invalidateCursorRects(for: view.canvas)
  }
}

private final class ScreenshotMarkupScrollView: NSScrollView {
  let canvas: ScreenshotMarkupCanvas
  private var updating = false
  private var previousZoom: CGFloat?
  init(model: ScreenshotEditorModel) {
    canvas = ScreenshotMarkupCanvas(model: model)
    super.init(frame: .zero)
    drawsBackground = false
    hasVerticalScroller = true
    hasHorizontalScroller = true
    autohidesScrollers = true
    documentView = canvas
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  override func layout() {
    super.layout()
    updateCanvas()
  }
  func updateCanvas() {
    guard !updating, contentSize.width > 0, contentSize.height > 0 else { return }
    updating = true
    defer { updating = false }
    let model = canvas.model
    let viewport = contentSize
    let backing = window?.backingScaleFactor ?? 2
    let fitted = min(
      max(1, viewport.width - 48) * backing / model.image.size.width,
      max(1, viewport.height - 48) * backing / model.image.size.height)
    if abs(model.fittedZoom - fitted) > 0.0001 {
      DispatchQueue.main.async { [weak model] in
        if let model, abs(model.fittedZoom - fitted) > 0.0001 { model.fittedZoom = fitted }
      }
    }
    let oldRect = canvas.imageRect
    let visible = contentView.bounds
    let center = ScreenshotMarkupRenderer.normalized(
      CGPoint(x: visible.midX, y: visible.midY), in: oldRect)
    let factor = (model.zoom ?? fitted) / backing
    canvas.imageSize = CGSize(
      width: model.image.size.width * factor, height: model.image.size.height * factor)
    let size = CGSize(
      width: max(viewport.width, canvas.imageSize.width + 48),
      height: max(viewport.height, canvas.imageSize.height + 48))
    let changed = canvas.frame.size != size || previousZoom != model.zoom
    if canvas.frame.size != size { canvas.setFrameSize(size) }
    if changed {
      let rect = canvas.imageRect
      let point =
        model.zoom == nil
        ? CGPoint(x: (size.width - viewport.width) / 2, y: (size.height - viewport.height) / 2)
        : CGPoint(
          x: rect.minX + center.x * rect.width - viewport.width / 2,
          y: rect.minY + center.y * rect.height - viewport.height / 2)
      let proposed = contentView.constrainBoundsRect(CGRect(origin: point, size: viewport))
      contentView.scroll(to: proposed.origin)
      reflectScrolledClipView(contentView)
    }
    previousZoom = model.zoom
    canvas.needsDisplay = true
  }
}

private final class ScreenshotMarkupCanvas: NSView {
  var model: ScreenshotEditorModel
  var imageSize = CGSize.zero
  private var drawing = false
  private var spaceDown = false
  private var panStart: (point: CGPoint, origin: CGPoint)?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override var undoManager: UndoManager? { model.history }
  init(model: ScreenshotEditorModel) {
    self.model = model
    super.init(frame: .zero)
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
    setAccessibilityLabel("Screenshot annotation canvas")
    setAccessibilityHelp(
      "Choose an annotation tool. Space-drag to pan. Delete removes the selected annotation.")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    model.window = window
    model.focusCanvas = { [weak self] in if let self { self.window?.makeFirstResponder(self) } }
    window?.makeFirstResponder(self)
  }
  var imageRect: CGRect {
    CGRect(
      x: (bounds.width - imageSize.width) / 2, y: (bounds.height - imageSize.height) / 2,
      width: imageSize.width, height: imageSize.height)
  }
  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 12
    shadow.shadowOffset = NSSize(width: 0, height: 2)
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(rect: imageRect).fill()
    NSGraphicsContext.restoreGraphicsState()
    ScreenshotMarkupRenderer.draw(image: model.image, marks: model.visibleMarks, in: imageRect)
    if model.tool == .select, let mark = model.selectedMark {
      let box = ScreenshotMarkupRenderer.bounds(of: mark, in: imageRect).insetBy(dx: -4, dy: -4)
      NSColor.controlAccentColor.setStroke()
      let outline = NSBezierPath(rect: box)
      outline.lineWidth = 1
      outline.setLineDash([4, 3], count: 2, phase: 0)
      outline.stroke()
    }
  }
  override func resetCursorRects() {
    addCursorRect(
      bounds, cursor: spaceDown ? .openHand : model.tool == .select ? .arrow : .crosshair)
  }
  override func mouseDown(with event: NSEvent) {
    guard !model.exporting else { return }
    window?.makeFirstResponder(self)
    if spaceDown, let clip = enclosingScrollView?.contentView {
      panStart = (event.locationInWindow, clip.bounds.origin)
      NSCursor.closedHand.set()
      return
    }
    let point = convert(event.locationInWindow, from: nil)
    guard imageRect.contains(point) else {
      model.select(nil)
      return
    }
    let selected =
      model.tool == .select
      ? ScreenshotMarkupRenderer.hitTest(point, marks: model.marks, imageRect: imageRect) : nil
    drawing = true
    model.begin(at: ScreenshotMarkupRenderer.normalized(point, in: imageRect), selection: selected)
    if event.clickCount == 2, model.selectedMark?.tool == .text {
      model.textOptionsRequested = true
    }
    needsDisplay = true
  }
  override func mouseDragged(with event: NSEvent) {
    if let start = panStart, let scroll = enclosingScrollView {
      let point = CGPoint(
        x: start.origin.x - (event.locationInWindow.x - start.point.x),
        y: start.origin.y + (event.locationInWindow.y - start.point.y))
      scroll.contentView.scroll(
        to: scroll.contentView.constrainBoundsRect(
          CGRect(origin: point, size: scroll.contentView.bounds.size)
        ).origin)
      scroll.reflectScrolledClipView(scroll.contentView)
      return
    }
    guard drawing else { return }
    model.drag(
      to: ScreenshotMarkupRenderer.normalized(
        convert(event.locationInWindow, from: nil), in: imageRect))
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    if panStart != nil {
      panStart = nil
      window?.invalidateCursorRects(for: self)
      return
    }
    guard drawing else { return }
    model.drag(
      to: ScreenshotMarkupRenderer.normalized(
        convert(event.locationInWindow, from: nil), in: imageRect))
    model.end()
    drawing = false
    needsDisplay = true
  }
  override func magnify(with event: NSEvent) {
    model.zoom = min(4, max(0.1, (model.zoom ?? model.fittedZoom) * (1 + event.magnification)))
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 49 {
      spaceDown = true
      window?.invalidateCursorRects(for: self)
      return
    }
    if event.keyCode == 53 {
      if model.draft != nil {
        model.cancelGesture()
        drawing = false
      } else {
        model.requestClose()
      }
      return
    }
    if event.keyCode == 51 || event.keyCode == 117 {
      model.deleteSelection()
      return
    }
    let shortcuts: [String: ScreenshotMarkupTool] = [
      "v": .select, "d": .pen, "a": .arrow, "r": .box, "x": .redact, "t": .text,
    ]
    if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
      let key = event.charactersIgnoringModifiers, let tool = shortcuts[key]
    {
      model.tool = tool
      return
    }
    super.keyDown(with: event)
  }
  override func keyUp(with event: NSEvent) {
    if event.keyCode == 49 {
      spaceDown = false
      window?.invalidateCursorRects(for: self)
      return
    }
    super.keyUp(with: event)
  }
  override func resignFirstResponder() -> Bool {
    spaceDown = false
    return super.resignFirstResponder()
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.firstResponder === self, event.modifierFlags.contains(.command) else {
      return super.performKeyEquivalent(with: event)
    }
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "z": if event.modifierFlags.contains(.shift) { model.redo() } else { model.undo() }
    case "c": model.copy()
    case "s": if event.modifierFlags.contains(.shift) { model.saveAs() } else { model.save() }
    case "+", "=": model.stepZoom(true)
    case "-": model.stepZoom(false)
    case "0": model.zoom = nil
    case "1": model.zoom = 1
    default: return super.performKeyEquivalent(with: event)
    }
    return true
  }
}

private struct ScreenshotEditorWindowActions: NSViewRepresentable {
  let model: ScreenshotEditorModel
  func makeNSView(context: Context) -> EditorWindowActionView {
    EditorWindowActionView(model: model)
  }
  func updateNSView(_ view: EditorWindowActionView, context: Context) {}
  static func dismantleNSView(_ view: EditorWindowActionView, coordinator: ()) { view.detach() }
}
private final class EditorWindowActionView: NSView {
  let model: ScreenshotEditorModel
  private weak var button: NSButton?
  private weak var originalTarget: AnyObject?
  private var originalAction: Selector?
  private var monitor: Any?
  init(model: ScreenshotEditorModel) {
    self.model = model
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    detach()
    guard let window else { return }
    model.window = window
    if let button = window.standardWindowButton(.closeButton) {
      self.button = button
      originalTarget = button.target
      originalAction = button.action
      button.target = self
      button.action = #selector(closeWindow)
    }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self, weak window] event in
      guard let self, event.window === window, event.modifierFlags.contains(.command),
        event.charactersIgnoringModifiers == "w", window?.attachedSheet == nil
      else { return event }
      self.closeWindow()
      return nil
    }
  }
  @objc private func closeWindow() {
    guard let window else { return }
    model.requestClose { [weak self, weak model, weak window] in
      self?.detach()
      model?.onClose()
      DispatchQueue.main.async { window?.performClose(nil) }
    }
  }
  func detach() {
    if button?.target === self {
      button?.target = originalTarget
      button?.action = originalAction
    }
    button = nil
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
}

struct ScreenshotOpenCommand: View {
  @ObservedObject var captures: DeviceScreenshotController
  let window: () -> NSWindow?
  var body: some View {
    Button("Open Screenshot…") { captures.openSavedScreenshot(in: window()) }
      .keyboardShortcut("o", modifiers: [.command, .shift])
      .disabled(!captures.allowsEditor() || captures.editor != nil || captures.capturing)
  }
}
