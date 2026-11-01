import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ScreenshotEditorModel: ObservableObject, Identifiable {
  let id = UUID()
  let shot: DeviceScreenshot
  let title: String
  var onSavedImage: ((Data, URL) throws -> Void)?
  let image: NSImage
  let history = UndoManager()
  @Published var tool = ScreenshotMarkupTool.select {
    didSet {
      cancelGesture()
      if tool == .text { textOptionsRequested = true }
    }
  }
  @Published private(set) var color = ScreenshotMarkupColor.coral
  @Published private(set) var stroke = ScreenshotStroke.regular
  @Published private(set) var textSize = ScreenshotTextSize.medium
  @Published var label = ""
  @Published var textOptionsRequested = false
  @Published var zoom: CGFloat?
  @Published var fittedZoom: CGFloat = 1
  @Published private(set) var marks: [ScreenshotMarkup] = []
  @Published private(set) var draft: ScreenshotMarkup?
  @Published private(set) var selectedID: UUID?
  @Published private(set) var message = ""
  @Published private(set) var failed = false
  @Published private(set) var exporting = false
  @Published private(set) var savedFile: URL?
  @Published var confirmClose = false
  weak var window: NSWindow?
  var onClose: () -> Void = {}
  var focusCanvas: () -> Void = {}
  private let clipboard: NSPasteboard
  private var savedMarks: [ScreenshotMarkup]?
  private var copiedMarks: [ScreenshotMarkup]?
  private var cache: (marks: [ScreenshotMarkup], png: Data)?
  private var movingMark: ScreenshotMarkup?
  private var moveOrigin: CGPoint?
  private var closeAction: (() -> Void)?
  var canUndo: Bool { history.canUndo && !exporting }
  var canRedo: Bool { history.canRedo && !exporting }
  var copied: Bool { copiedMarks == marks }
  var selectedMark: ScreenshotMarkup? { visibleMarks.first { $0.id == selectedID } }
  var needsExport: Bool { marks != (savedMarks ?? []) && marks != copiedMarks }
  var visibleMarks: [ScreenshotMarkup] {
    guard let draft else { return marks }
    return marks.contains { $0.id == draft.id }
      ? marks.map { $0.id == draft.id ? draft : $0 } : marks + [draft]
  }
  var instruction: String {
    switch tool {
    case .select:
      return selectedID == nil
        ? "Select an annotation to move, style or delete it." : "Drag to move · Delete to remove"
    case .pen: return "Drag to draw · Hold Space to pan"
    case .arrow: return "Drag toward the arrow tip."
    case .box: return "Drag to outline an area."
    case .redact: return "Drag to cover an area with solid black."
    case .text: return "Type a label, then click the image to place it."
    }
  }
  init(shot: DeviceScreenshot, clipboard: NSPasteboard = .general, title: String = "Screenshot")
    throws
  {
    self.title = title
    self.clipboard = clipboard
    self.shot = shot
    image = try ScreenshotMarkupRenderer.source(shot.png)
    history.groupsByEvent = false
    history.levelsOfUndo = 100
  }
  func select(_ id: UUID?) {
    selectedID = id
    guard let mark = marks.first(where: { $0.id == id }) else { return }
    color = mark.color
    stroke = mark.stroke
    textSize = mark.textSize
    if mark.tool == .text { label = mark.text }
  }
  func begin(at point: CGPoint, selection: UUID? = nil) {
    guard !exporting else { return }
    message = ""
    failed = false
    if tool == .select {
      select(selection)
      movingMark = selectedMark
      moveOrigin = point
      return
    }
    selectedID = nil
    if tool == .text {
      let text = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
      guard !text.isEmpty else {
        message = "Enter a label in Text options first."
        return
      }
      var mark = ScreenshotMarkup(tool: .text, color: color, points: [point], text: text)
      mark.textSize = textSize
      replace(marks + [mark], selection: mark.id, action: "Add Text")
    } else {
      var mark = ScreenshotMarkup(tool: tool, color: color, points: [point])
      mark.stroke = stroke
      draft = mark
    }
  }
  func drag(to point: CGPoint) {
    guard !exporting else { return }
    if let movingMark, let moveOrigin {
      draft = ScreenshotMarkupRenderer.translated(
        movingMark, by: CGPoint(x: point.x - moveOrigin.x, y: point.y - moveOrigin.y))
      return
    }
    guard var mark = draft else { return }
    if mark.tool == .pen {
      if let previous = mark.points.last,
        hypot((previous.x - point.x) * image.size.width, (previous.y - point.y) * image.size.height)
          < 1
      {
        return
      }
      mark.points.append(point)
    } else {
      mark.points = [mark.points[0], point]
    }
    draft = mark
  }
  func end() {
    guard !exporting else { return }
    let mark = draft
    let moved = movingMark != nil
    cancelGesture()
    guard let mark else { return }
    if moved {
      if marks.first(where: { $0.id == mark.id }) != mark {
        replace(
          marks.map { $0.id == mark.id ? mark : $0 }, selection: mark.id, action: "Move Annotation")
      }
    } else {
      if mark.tool != .pen {
        guard let a = mark.points.first, let b = mark.points.last,
          hypot((a.x - b.x) * image.size.width, (a.y - b.y) * image.size.height) >= 3
        else { return }
        if mark.tool == .box || mark.tool == .redact {
          guard abs(a.x - b.x) * image.size.width >= 2, abs(a.y - b.y) * image.size.height >= 2
          else { return }
        }
      }
      replace(marks + [mark], selection: mark.id, action: "Add \(mark.tool.rawValue)")
    }
  }
  func cancelGesture() {
    draft = nil
    movingMark = nil
    moveOrigin = nil
  }
  private func replace(_ updated: [ScreenshotMarkup], selection: UUID?, action: String) {
    let before = marks
    let beforeSelection = selectedID
    let grouping = !history.isUndoing && !history.isRedoing
    if grouping { history.beginUndoGrouping() }
    history.registerUndo(withTarget: self) { target in
      target.replace(before, selection: beforeSelection, action: action)
    }
    history.setActionName(action)
    if grouping { history.endUndoGrouping() }
    marks = updated
    select(updated.contains { $0.id == selection } ? selection : nil)
    message = ""
    failed = false
  }
  func undo() {
    guard canUndo else { return }
    cancelGesture()
    history.undo()
  }
  func redo() {
    guard canRedo else { return }
    cancelGesture()
    history.redo()
  }
  func deleteSelection() {
    guard let selectedID, !exporting else { return }
    replace(marks.filter { $0.id != selectedID }, selection: nil, action: "Delete Annotation")
  }
  func setColor(_ color: ScreenshotMarkupColor) {
    self.color = color
    styleSelection("Change Color") { $0.color = color }
  }
  func setStroke(_ stroke: ScreenshotStroke) {
    self.stroke = stroke
    styleSelection("Change Line Weight") { $0.stroke = stroke }
  }
  func setTextSize(_ size: ScreenshotTextSize) {
    if selectedMark?.tool == .text { updateText() }
    textSize = size
    styleSelection("Change Text Size") { $0.textSize = size }
  }
  func updateText() {
    let value = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
    guard !value.isEmpty else { return }
    styleSelection("Edit Text") { if $0.tool == .text { $0.text = value } }
  }
  private func styleSelection(_ action: String, update: (inout ScreenshotMarkup) -> Void) {
    guard tool == .select, let selectedID,
      let index = marks.firstIndex(where: { $0.id == selectedID }), !exporting
    else { return }
    var edited = marks
    update(&edited[index])
    guard edited != marks else { return }
    replace(edited, selection: selectedID, action: action)
  }
  func stepZoom(_ inward: Bool) {
    zoom = min(4, max(0.1, (zoom ?? fittedZoom) + (inward ? 0.25 : -0.25)))
  }
  func requestClose(action: (() -> Void)? = nil) {
    closeAction = action ?? onClose
    if exporting { return }
    end()
    if needsExport { confirmClose = true } else { finishClose() }
  }
  func cancelClose() {
    closeAction = nil
    confirmClose = false
  }
  func discardAndClose() {
    confirmClose = false
    finishClose()
  }
  private func finishClose() {
    let action = closeAction
    closeAction = nil
    action?()
  }
  func saveAndClose() {
    confirmClose = false
    save(closeAfter: true)
  }
  func saveAs() {
    guard !exporting else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = shot.file.deletingPathExtension().lastPathComponent + " Edited.png"
    panel.directoryURL =
      savedFile?.deletingLastPathComponent() ?? shot.file.deletingLastPathComponent()
    if let window {
      panel.beginSheetModal(for: window) { [weak self] response in
        if response == .OK, let url = panel.url { self?.export(destination: url) }
      }
    } else if panel.runModal() == .OK, let url = panel.url {
      export(destination: url)
    }
  }
  func save(closeAfter: Bool = false) { export(destination: savedFile, closeAfter: closeAfter) }
  func copy() { export(copy: true) }
  private func export(copy: Bool = false, destination: URL? = nil, closeAfter: Bool = false) {
    guard !exporting else { return }
    end()
    exporting = true
    failed = false
    message = copy ? "Copying image…" : "Saving image…"
    let snapshot = marks
    let source = shot.png
    let cached = cache?.marks == marks ? cache?.png : nil
    let folder = shot.file.deletingLastPathComponent()
    Task {
      defer { exporting = false }
      do {
        let result = try await Task.detached { () throws -> (Data, URL?) in
          let png =
            try cached
            ?? ScreenshotMarkupRenderer.png(
              image: ScreenshotMarkupRenderer.source(source), marks: snapshot)
          if copy { return (png, nil) }
          if let destination {
            try png.write(to: destination, options: .atomic)
            return (png, destination)
          }
          return (
            png, try DeviceScreenshotStore.save(png, in: folder, namePrefix: "Okestra Edited")
          )
        }.value
        cache = (snapshot, result.0)
        if copy {
          guard ScreenshotClipboard.write(result.0, to: clipboard) else {
            throw CocoaError(.fileWriteUnknown)
          }
          copiedMarks = snapshot
          message = "Copied to clipboard"
        } else {
          savedFile = result.1
          if let url = result.1 { try onSavedImage?(result.0, url) }
          savedMarks = snapshot
          message = "Saved edited screenshot"
        }
        if closeAfter || closeAction != nil { finishClose() }
      } catch {
        closeAction = nil
        failed = true
        message = "\(copy ? "Copy" : "Save") failed: \(error.localizedDescription)"
      }
    }
  }
}
