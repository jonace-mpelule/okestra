import AVFoundation
import AppKit
import Foundation

@main struct VideoReviewChecks {
  @MainActor static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "okestra-video-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let movie = root.appendingPathComponent("Fixture.mov")
    try await makeMovie(movie)
    let info = try await VideoMedia.info(movie)
    precondition(info.duration > 1 && info.thumbnail != nil)
    let original = try Data(contentsOf: movie)
    let model = try VideoEditorModel(file: movie, duration: info.duration)
    model.seek(0.7)
    model.comment = "Fix this screen"
    model.postComment()
    precondition(model.document.notes.count == 1 && !model.unsaved)
    let note = model.document.notes[0]
    precondition(abs(note.time - 0.7) < 0.01)
    model.edit(note)
    model.comment = "Fix this button"
    model.postComment()
    precondition(
      model.document.notes.count == 1 && model.document.notes[0].text == "Fix this button")
    model.seek(0.5)
    model.annotateFrame()
    try await settle { !model.busy }
    guard let frame = model.frameEditor else {
      fatalError("Frame editor did not open: \(model.message)")
    }
    frame.tool = .box
    frame.begin(at: CGPoint(x: 0.1, y: 0.1))
    frame.drag(to: CGPoint(x: 0.7, y: 0.5))
    frame.end()
    frame.save()
    try await settle { !frame.exporting }
    precondition(!frame.failed)
    let marked = model.document.notes.first { $0.kind == .frame }!
    precondition(
      FileManager.default.fileExists(
        atPath: VideoReviewStore.assets(for: movie).appendingPathComponent(marked.attachment!).path)
    )
    frame.onClose()
    precondition(model.frameEditor == nil)
    let zip = root.appendingPathComponent("Review.zip")
    model.writeExport(to: zip, bundle: true)
    try await settle { !model.busy }
    precondition(!model.failed && FileManager.default.fileExists(atPath: zip.path))
    let copy = root.appendingPathComponent("Copy.mov")
    model.writeExport(to: copy, bundle: false)
    try await settle { !model.busy }
    let copied = try Data(contentsOf: copy)
    precondition(copied == original)
    var closed = false
    model.comment = "Do not lose this draft"
    precondition(model.hasPendingWork)
    model.requestClose { closed = true }
    precondition(closed && model.comment.isEmpty)
    let persisted = try VideoReviewStore.load(movie: movie, duration: info.duration)
    precondition(persisted.notes.contains { $0.text == "Do not lose this draft" })
    model.shutdown()
    let reviews = VideoReviewController()
    reviews.recorded(movie)
    try await settle { reviews.preview != nil || reviews.error != nil }
    precondition(reviews.error == nil && reviews.preview?.file == movie)
    reviews.open(movie)
    try await settle { !reviews.loading }
    precondition(reviews.editor != nil && reviews.preview == nil)
    reviews.editor?.onClose()
    precondition(reviews.editor == nil)
    reviews.recorded(movie)
    try await settle { reviews.preview != nil }
    try await Task.sleep(nanoseconds: 6_000_000_000)
    try await settle { reviews.preview == nil }
    precondition(reviews.preview == nil && FileManager.default.fileExists(atPath: movie.path))
    try await checkRecording(source: movie, output: root.appendingPathComponent("Captured.mov"))
    try await checkStaticRecording(source: movie, output: root.appendingPathComponent("Static.mov"))
    print(
      "PASS: real movie playback metadata; timed comments and edits; frame annotation integration; review ZIP; lossless copy; draft close; preview opening/expiry; H.264 recording finalization"
    )
  }
  @MainActor static func settle(_ predicate: () -> Bool) async throws {
    for _ in 0..<500 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    fatalError("Video check timed out")
  }
  static func makeMovie(_ url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 80, AVVideoHeightKey: 128,
      ])
    let adapter = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 80, kCVPixelBufferHeightKey as String: 128,
      ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    for index in 0..<30 {
      for _ in 0..<500 {
        if input.isReadyForMoreMediaData { break }
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      var buffer: CVPixelBuffer?
      guard
        CVPixelBufferPoolCreatePixelBuffer(nil, adapter.pixelBufferPool!, &buffer)
          == kCVReturnSuccess, let buffer
      else { fatalError("Pixel buffer allocation failed") }
      CVPixelBufferLockBaseAddress(buffer, [])
      let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
      for y in 0..<128 {
        for x in 0..<80 {
          let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
          bytes[offset] = UInt8(index * 8)
          bytes[offset + 1] = UInt8(y)
          bytes[offset + 2] = UInt8(x * 3)
          bytes[offset + 3] = 255
        }
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      guard adapter.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10))
      else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
  }
  @MainActor static func checkStaticRecording(source: URL, output: URL) async throws {
    let asset = AVURLAsset(url: source)
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let reader = try AVAssetReader(asset: asset)
    let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(samples)
    precondition(reader.startReading())
    var keyframe: CMSampleBuffer?
    while let candidate = samples.copyNextSampleBuffer() {
      guard CMSampleBufferGetFormatDescription(candidate) != nil,
        CMSampleBufferGetNumSamples(candidate) > 0
      else { continue }
      let attachments =
        CMSampleBufferGetSampleAttachmentsArray(candidate, createIfNecessary: false)
        as? [[String: Any]]
      if attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true {
        keyframe = candidate
        break
      }
    }
    guard let original = keyframe else { fatalError("Fixture has no keyframe") }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    precondition(
      CMSampleBufferCreateCopyWithNewTiming(
        allocator: kCFAllocatorDefault, sampleBuffer: original,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &sample) == noErr)
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample!, createIfNecessary: true) {
      let flags = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        flags, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanFalse).toOpaque())
    }
    let result = RecordingResult()
    let recording = DeviceRecording()
    recording.onState = { active, message, url in if !active { result.set(message, url) } }
    try recording.start(url: output, audio: false)
    recording.consumeVideo(sample!)
    try await Task.sleep(nanoseconds: 400_000_000)
    recording.stop()
    try await settle { result.finished }
    precondition(result.url == output, result.message)
    let info = try await VideoMedia.info(output)
    precondition(info.duration >= 0.3 && info.thumbnail != nil)
  }
  @MainActor static func checkRecording(source: URL, output: URL) async throws {
    let recording = DeviceRecording()
    let result = RecordingResult()
    recording.onState = { active, message, url in if !active { result.set(message, url) } }
    try recording.start(url: output, audio: false)
    let asset = AVURLAsset(url: source)
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let reader = try AVAssetReader(asset: asset)
    let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(samples)
    precondition(reader.startReading())
    while let sample = samples.copyNextSampleBuffer() {
      recording.consumeVideo(sample)
      try await Task.sleep(nanoseconds: 40_000_000)
    }
    recording.stop()
    try await settle { result.finished }
    precondition(result.url == output, result.message)
    let info = try await VideoMedia.info(output)
    precondition(info.duration > 0 && info.thumbnail != nil)
  }
}
private final class RecordingResult: @unchecked Sendable {
  private let lock = NSLock()
  private var value: (String, URL?)?
  var finished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value != nil
  }
  var message: String {
    lock.lock()
    defer { lock.unlock() }
    return value?.0 ?? ""
  }
  var url: URL? {
    lock.lock()
    defer { lock.unlock() }
    return value?.1
  }
  func set(_ message: String, _ url: URL?) {
    lock.lock()
    value = (message, url)
    lock.unlock()
  }
}
