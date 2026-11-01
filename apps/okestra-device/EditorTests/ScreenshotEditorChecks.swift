import AppKit
import Foundation

// Runs against the real editor and transport types; no device or general clipboard access.
@main struct Checks {
  @MainActor static func main() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "okestra-editor-checks-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let png = try fixturePNG()
    let sourceFile = folder.appendingPathComponent("Original.png")
    try png.write(to: sourceFile)
    let shot = DeviceScreenshot(image: NSImage(data: png)!, png: png, file: sourceFile)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let m = try ScreenshotEditorModel(shot: shot, clipboard: board)
    precondition(!m.needsExport && !m.canUndo)
    m.tool = .box
    m.begin(at: CGPoint(x: 0.1, y: 0.1))
    m.drag(to: CGPoint(x: 0.5, y: 0.4))
    m.end()
    precondition(m.canUndo && m.needsExport && m.marks.count == 1)
    let original = m.marks[0]
    m.tool = .select
    m.select(original.id)
    m.setColor(.blue)
    precondition(m.marks[0].color == .blue)
    m.undo()
    precondition(m.marks[0].color == .coral)
    m.redo()
    precondition(m.marks[0].color == .blue)
    m.begin(at: CGPoint(x: 0.2, y: 0.2), selection: original.id)
    m.drag(to: CGPoint(x: 0.3, y: 0.3))
    m.end()
    precondition(m.marks[0].points != original.points)
    m.undo()
    precondition(m.marks[0].points == original.points)
    m.redo()
    m.deleteSelection()
    precondition(m.marks.isEmpty)
    m.undo()
    precondition(m.marks.count == 1)
    m.tool = .text
    precondition(m.textOptionsRequested)
    m.label = "First label"
    m.begin(at: CGPoint(x: 0.1, y: 0.7))
    precondition(m.marks.count == 2)
    m.tool = .select
    m.select(m.marks[1].id)
    m.label = "Changed label"
    m.setTextSize(.large)
    precondition(m.marks[1].text == "Changed label" && m.marks[1].textSize == .large)
    m.undo()
    precondition(m.marks[1].text == "Changed label" && m.marks[1].textSize == .medium)
    m.undo()
    precondition(m.marks[1].text == "First label")
    var closed = false
    m.requestClose { closed = true }
    precondition(m.confirmClose && !closed)
    m.cancelClose()
    precondition(!m.confirmClose && !closed)
    m.save()
    try await settle(m)
    precondition(!m.failed && !m.needsExport)
    let saved = m.savedFile!
    precondition(saved != sourceFile)
    let originalBytes = try Data(contentsOf: sourceFile)
    precondition(originalBytes == png)
    m.tool = .redact
    m.begin(at: CGPoint(x: 0.2, y: 0.2))
    m.drag(to: CGPoint(x: 0.8, y: 0.3))
    m.end()
    m.save()
    try await settle(m)
    precondition(m.savedFile == saved)
    let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    precondition(contents.count == 2)
    m.copy()
    try await settle(m)
    precondition(m.copied && !m.failed)
    let copied = board.data(forType: .png)!
    precondition(board.data(forType: .tiff) != nil && board.data(forType: .fileURL) == nil)
    let bitmap = NSBitmapImageRep(data: copied)!
    precondition(bitmap.pixelsWide == 600 && bitmap.pixelsHigh == 1000)
    let pixel = bitmap.colorAt(x: 300, y: 250)!.usingColorSpace(.deviceRGB)!
    precondition(
      pixel.redComponent == 0 && pixel.greenComponent == 0 && pixel.blueComponent == 0
        && pixel.alphaComponent == 1)
    m.requestClose { closed = true }
    precondition(closed)
    let blocked = folder.appendingPathComponent("blocked")
    try Data().write(to: blocked)
    let bad = try ScreenshotEditorModel(
      shot: DeviceScreenshot(
        image: shot.image, png: png, file: blocked.appendingPathComponent("original.png")),
      clipboard: board)
    bad.tool = .box
    bad.begin(at: CGPoint(x: 0.1, y: 0.1))
    bad.drag(to: CGPoint(x: 0.3, y: 0.4))
    bad.end()
    var lost = false
    bad.requestClose { lost = true }
    bad.saveAndClose()
    try await settle(bad)
    precondition(bad.failed && !lost && bad.marks.count == 1 && bad.needsExport)
    print(
      "PASS: native undo/redo; move/delete/style; text editing; close/cancel; async save; repeat-save URL; clipboard PNG/TIFF; opaque redaction; failed-save retention"
    )
  }
  @MainActor static func fixturePNG() throws -> Data {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 1000,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { throw CocoaError(.fileWriteUnknown) }
    memset(bitmap.bitmapData!, 255, bitmap.bytesPerRow * bitmap.pixelsHigh)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    return png
  }
  @MainActor static func settle(_ model: ScreenshotEditorModel) async throws {
    for _ in 0..<500 {
      if !model.exporting { return }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    fatalError("Export did not finish")
  }
}
