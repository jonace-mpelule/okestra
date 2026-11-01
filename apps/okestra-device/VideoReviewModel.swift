import AVFoundation
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct RecordedVideoPreview: Identifiable {
  let id = UUID()
  let file: URL
  let image: NSImage
  let duration: Double
}
struct VideoMediaInfo: Sendable {
  let duration: Double
  let thumbnail: Data?
  let aspectRatio: CGFloat
}
enum VideoMedia {
  static func info(_ file: URL) async throws -> VideoMediaInfo {
    let asset = AVURLAsset(url: file)
    let duration = try await asset.load(.duration).seconds
    guard duration.isFinite, duration > 0,
      let track = try await asset.loadTracks(withMediaType: .video).first
    else {
      throw DeviceError.message("This file has no playable video recording.")
    }
    let size = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let display = CGRect(origin: .zero, size: size).applying(transform).size
    let ratio = display.height > 0 ? display.width / display.height : 16.0 / 9.0
    return VideoMediaInfo(
      duration: duration, thumbnail: try? frame(file, at: 0, thumbnail: true), aspectRatio: ratio)
  }
  static func frame(_ file: URL, at seconds: Double, thumbnail: Bool = false) throws -> Data {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    if thumbnail { generator.maximumSize = CGSize(width: 480, height: 480) }
    let image = try generator.copyCGImage(
      at: CMTime(seconds: max(0, seconds), preferredTimescale: 600), actualTime: nil)
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil)
    else {
      throw DeviceError.message("Could not prepare the recording preview.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw DeviceError.message("Could not capture the video frame.")
    }
    return data as Data
  }
}

@MainActor
final class VideoReviewController: ObservableObject {
  @Published private(set) var preview: RecordedVideoPreview?
  @Published private(set) var editor: VideoEditorModel?
  @Published private(set) var dismissing = false
  @Published private(set) var loading = false
  @Published var error: String?
  @Published private(set) var latest: URL?
  var prepareEditor: (@escaping () -> Void) -> Void = { $0() }
  var onPreview: () -> Void = {}
  var onEditorVisibility: (Bool) -> Void = { _ in }
  private var generation = UUID()
  private var dismissal: Task<Void, Never>?
  func recorded(_ file: URL) {
    latest = file
    let token = UUID()
    generation = token
    Task {
      do {
        let info = try await Task.detached { try await VideoMedia.info(file) }.value
        guard generation == token else { return }
        let image =
          info.thumbnail.flatMap(NSImage.init(data:)) ?? NSImage(
            systemSymbolName: "video", accessibilityDescription: nil)!
        dismissal?.cancel()
        dismissing = false
        onPreview()
        preview = RecordedVideoPreview(file: file, image: image, duration: info.duration)
        dismissal = Task { [weak self = self] in
          try? await Task.sleep(nanoseconds: 5_550_000_000)
          guard !Task.isCancelled else { return }
          self?.dismissPreview()
        }
      } catch {
        self.error =
          "Recording saved, but its preview could not be loaded: \(error.localizedDescription)"
      }
    }
  }
  func dismissPreview() {
    dismissal?.cancel()
    guard let id = preview?.id else { return }
    let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.25
    withAnimation(.easeInOut(duration: duration)) { dismissing = true }
    dismissal = Task { [weak self = self] in
      try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
      guard !Task.isCancelled, let self, preview?.id == id else { return }
      preview = nil
      dismissing = false
    }
  }
  func open(_ file: URL) {
    guard editor == nil, !loading else { return }
    prepareEditor { [weak self = self] in self?.loadEditor(file) }
  }
  private func loadEditor(_ file: URL) {
    dismissal?.cancel()
    preview = nil
    dismissing = false
    loading = true
    Task {
      defer { loading = false }
      do {
        let info = try await Task.detached { try await VideoMedia.info(file) }.value
        let model = try VideoEditorModel(
          file: file, duration: info.duration, aspectRatio: info.aspectRatio)
        model.onClose = { [weak self = self, weak model] in
          model?.shutdown()
          self?.editor = nil
          self?.onEditorVisibility(false)
        }
        editor = model
        onEditorVisibility(true)
      } catch { self.error = error.localizedDescription }
    }
  }
  func openFile(in window: NSWindow?) {
    guard editor == nil, !loading else { return }
    let panel = NSOpenPanel()
    panel.title = "Open Recording"
    panel.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie]
    panel.allowsMultipleSelection = false
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Movies/Okestra/Recordings")
    let done: (NSApplication.ModalResponse) -> Void = { [weak self = self] result in
      if result == .OK, let file = panel.url { self?.open(file) }
    }
    if let window {
      panel.beginSheetModal(for: window, completionHandler: done)
    } else {
      done(panel.runModal())
    }
  }
}

@MainActor
final class VideoEditorModel: NSObject, ObservableObject {
  let file: URL
  let player: AVPlayer
  let aspectRatio: CGFloat
  @Published private(set) var document: VideoReviewDocument
  @Published private(set) var position = 0.0
  @Published private(set) var playing = false
  @Published var comment = ""
  @Published private(set) var editingNote: UUID?
  @Published private(set) var busy = false
  @Published private(set) var voiceRecording = false
  @Published private(set) var voiceFinishing = false
  @Published private(set) var voiceRequesting = false
  @Published private(set) var voiceElapsed = 0.0
  @Published private(set) var voicePlayingID: UUID?
  @Published private(set) var message = "Review notes save automatically"
  @Published private(set) var failed = false
  @Published private(set) var unsaved = false
  @Published private(set) var frameEditor: ScreenshotEditorModel?
  @Published var confirmClose = false
  weak var window: NSWindow?
  var onClose: () -> Void = {}
  var scrubbing = false
  private var periodic: Any?
  private var itemObservation: NSKeyValueObservation?
  private var recorder: AVAudioRecorder?
  private var voicePlayer: AVAudioPlayer?
  private var voiceAnchor = 0.0
  private var voiceFile: URL?
  private var voiceStarted: Date?
  private var voiceLength = 0.0
  private var voiceTimer: Task<Void, Never>?
  private var closed = false
  private let recordingDelegate = ReviewVoiceDelegate()
  private var pendingClose: (() -> Void)?
  var duration: Double { document.duration }
  var notes: [VideoReviewNote] { document.notes.sorted { $0.time < $1.time } }
  var hasPendingWork: Bool {
    busy || voiceRecording || voiceFinishing || voiceRequesting || unsaved
      || !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || frameEditor?.needsExport == true || frameEditor?.exporting == true
  }
  init(file: URL, duration: Double, aspectRatio: CGFloat = 9.0 / 16.0) throws {
    self.aspectRatio = aspectRatio
    self.file = file
    document = try VideoReviewStore.load(movie: file, duration: duration)
    player = AVPlayer(url: file)
    super.init()
    recordingDelegate.playbackFinished = { [weak self] in self?.voicePlayingID = nil }
    recordingDelegate.finished = { [weak self = self] success in self?.finishVoice(success) }
    periodic = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
    ) { [weak self = self] time in
      MainActor.assumeIsolated {
        guard let self else { return }
        if !self.scrubbing, time.seconds.isFinite {
          self.position = min(self.duration, max(0, time.seconds))
        }
        self.playing = self.player.rate != 0
        if let recorder = self.recorder, self.voiceRecording {
          self.voiceElapsed = recorder.currentTime
        }
      }
    }
    itemObservation = player.currentItem?.observe(\.status, options: [.new]) {
      [weak self = self] item, _ in
      if item.status == .failed {
        Task { @MainActor in
          self?.fail(item.error?.localizedDescription ?? "Video playback failed.")
        }
      }
    }
  }
  func togglePlayback() {
    guard !voiceRecording && !voiceFinishing else { return }
    voicePlayer?.stop()
    voicePlayingID = nil
    if player.rate != 0 {
      player.pause()
    } else {
      if position >= duration - 0.05 { seek(0) }
      player.play()
    }
    playing = player.rate != 0
  }
  func seek(_ time: Double) {
    guard time.isFinite, !voiceRecording else { return }
    position = min(duration, max(0, time))
    player.currentItem?.cancelPendingSeeks()
    player.seek(
      to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero,
      toleranceAfter: .zero)
  }
  func postComment() {
    guard !busy else { return }
    let text = String(comment.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10_000))
    guard !text.isEmpty else { return }
    if let id = editingNote, let i = document.notes.firstIndex(where: { $0.id == id }) {
      document.notes[i].text = text
    } else {
      let note = VideoReviewNote(time: position, text: text)
      document.notes.append(note)
      editingNote = note.id
    }
    if persist() {
      comment = ""
      editingNote = nil
    }
  }
  func edit(_ note: VideoReviewNote) {
    if editingNote != note.id, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      postComment()
    }
    editingNote = note.id
    comment = note.text
    player.pause()
    seek(note.time)
  }
  func cancelEdit() {
    editingNote = nil
    comment = ""
  }
  func remove(_ note: VideoReviewNote) {
    document.notes.removeAll { $0.id == note.id }
    if editingNote == note.id { cancelEdit() }
    _ = persist()
  }
  @discardableResult func persist() -> Bool {
    do {
      try VideoReviewStore.save(document, movie: file)
      unsaved = false
      failed = false
      message = "Review notes saved"
      return true
    } catch {
      unsaved = true
      fail("Notes are still in this editor. Save failed: \(error.localizedDescription)")
      return false
    }
  }
  func annotateFrame() {
    guard !busy, !voiceRecording, frameEditor == nil else { return }
    player.pause()
    busy = true
    let time = min(position, max(0, duration - 0.01))
    let file = file
    Task {
      defer {
        busy = false
        finishPendingClose()
      }
      do {
        let png = try await Task.detached { try VideoMedia.frame(file, at: time) }.value
        let image = try ScreenshotMarkupRenderer.source(png)
        let id = UUID()
        let folder = VideoReviewStore.assets(for: file)
        let shot = DeviceScreenshot(
          image: image, png: png, file: folder.appendingPathComponent("frame-\(id).png"))
        let editor = try ScreenshotEditorModel(
          shot: shot, title: "Frame at \(VideoReviewDocument.timecode(time))")
        editor.onSavedImage = { [weak self = self] _, url in
          guard let self else { return }
          let note = VideoReviewNote(
            id: id, time: time, kind: .frame, text: "Annotated frame",
            attachment: url.lastPathComponent)
          if let i = self.document.notes.firstIndex(where: { $0.id == id }) {
            self.document.notes[i] = note
          } else {
            self.document.notes.append(note)
          }
          guard self.persist() else { throw DeviceError.message(self.message) }
        }
        editor.onClose = { [weak self = self] in self?.frameEditor = nil }
        frameEditor = editor
      } catch { fail(error.localizedDescription) }
    }
  }
  func viewFrame(_ note: VideoReviewNote) {
    guard !busy, !voiceRecording, let attachment = note.attachment else { return }
    player.pause()
    seek(note.time)
    do {
      let url = VideoReviewStore.assets(for: file).appendingPathComponent(attachment)
      let png = try Data(contentsOf: url)
      let image = try ScreenshotMarkupRenderer.source(png)
      let editor = try ScreenshotEditorModel(
        shot: DeviceScreenshot(image: image, png: png, file: url),
        title: "Frame at \(VideoReviewDocument.timecode(note.time))")
      editor.onSavedImage = { [weak self] _, file in
        guard let self, let i = self.document.notes.firstIndex(where: { $0.id == note.id }) else {
          return
        }
        self.document.notes[i].attachment = file.lastPathComponent
        guard self.persist() else { throw DeviceError.message(self.message) }
      }
      editor.onClose = { [weak self] in self?.frameEditor = nil }
      frameEditor = editor
    } catch { fail(error.localizedDescription) }
  }
  func startVoice() {
    guard !voiceRecording, !voiceFinishing, !voiceRequesting, !busy else { return }
    player.pause()
    voicePlayer?.stop()
    voicePlayingID = nil
    voiceRequesting = true
    Task {
      defer { voiceRequesting = false }
      let allowed: Bool
      switch AVCaptureDevice.authorizationStatus(for: .audio) {
      case .authorized: allowed = true
      case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
      default: allowed = false
      }
      guard !closed else { return }
      if let action = pendingClose {
        pendingClose = nil
        voiceRequesting = false
        requestClose(action: action)
        return
      }
      guard allowed else {
        fail(
          "Microphone access is off. Enable it for Okestra Device in System Settings → Privacy & Security → Microphone."
        )
        return
      }
      do {
        let folder = VideoReviewStore.assets(for: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let recorder = try AVAudioRecorder(
          url: url,
          settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
          ])
        recorder.delegate = recordingDelegate
        guard recorder.prepareToRecord(), recorder.record(forDuration: 300) else {
          throw DeviceError.message("The microphone could not start recording.")
        }
        self.recorder = recorder
        voiceAnchor = position
        voiceFile = url
        voiceStarted = Date()
        voiceLength = 0
        voiceRecording = true
        voiceElapsed = 0
        failed = false
        message = "Recording voice note · up to 5 minutes"
        voiceTimer = Task { [weak self = self] in
          while !Task.isCancelled, self?.voiceRecording == true {
            self?.voiceElapsed = self?.recorder?.currentTime ?? 0
            try? await Task.sleep(nanoseconds: 200_000_000)
          }
        }
      } catch { fail(error.localizedDescription) }
    }
  }
  func stopVoice() {
    guard let recorder, voiceRecording else { return }
    voiceLength = recorder.currentTime
    voiceRecording = false
    voiceFinishing = true
    message = "Saving voice note…"
    recorder.stop()
  }
  private func finishVoice(_ success: Bool) {
    guard voiceFile != nil else { return }
    voiceTimer?.cancel()
    voiceTimer = nil
    let url = voiceFile
    voiceRecording = false
    voiceFinishing = false
    recorder = nil
    voiceFile = nil
    guard success, let url else {
      pendingClose = nil
      fail("The voice note could not be saved. Your video is still saved.")
      return
    }
    do {
      let audio = try AVAudioPlayer(contentsOf: url)
      let length =
        audio.duration.isFinite
        ? audio.duration
        : min(300, max(voiceLength, Date().timeIntervalSince(voiceStarted ?? Date())))
      guard length > 0.05 else {
        throw DeviceError.message("The voice note was too short. Try recording again.")
      }
      document.notes.append(
        VideoReviewNote(
          time: voiceAnchor, kind: .voice, text: "Voice note", attachment: url.lastPathComponent,
          duration: length))
      guard persist() else {
        pendingClose = nil
        return
      }
      finishPendingClose()
    } catch {
      pendingClose = nil
      fail(error.localizedDescription)
    }
  }
  func playVoice(_ note: VideoReviewNote) {
    guard let attachment = note.attachment, !voiceRecording else { return }
    if voicePlayer?.isPlaying == true, voicePlayingID == note.id {
      voicePlayer?.stop()
      voicePlayingID = nil
      return
    }
    player.pause()
    voicePlayer?.stop()
    seek(note.time)
    do {
      voicePlayer = try AVAudioPlayer(
        contentsOf: VideoReviewStore.assets(for: file).appendingPathComponent(attachment))
      voicePlayer?.delegate = recordingDelegate
      if voicePlayer?.play() == true { voicePlayingID = note.id }
    } catch { fail(error.localizedDescription) }
  }
  func copyNotes() {
    if !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { postComment() }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(document.markdown(), forType: .string)
    failed = false
    message = "Timestamped notes copied"
  }
  func saveVideo() { chooseDestination(bundle: false) }
  func exportReview() { chooseDestination(bundle: true) }
  private func chooseDestination(bundle: Bool) {
    guard !busy, !voiceRecording, !voiceFinishing, !voiceRequesting else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes =
      bundle ? [.zip] : [file.pathExtension.lowercased() == "mp4" ? .mpeg4Movie : .quickTimeMovie]
    panel.message =
      bundle
      ? "Includes the original video, timestamped comments, separate annotated frames and voice notes."
      : "Save a copy of the original recording."
    panel.nameFieldStringValue =
      bundle
      ? file.deletingPathExtension().lastPathComponent + " Review.zip" : file.lastPathComponent
    let complete: (NSApplication.ModalResponse) -> Void = { [weak self = self] result in
      guard result == .OK, let url = panel.url else { return }
      self?.writeExport(to: url, bundle: bundle)
    }
    if let window {
      panel.beginSheetModal(for: window, completionHandler: complete)
    } else {
      complete(panel.runModal())
    }
  }
  func writeExport(to destination: URL, bundle: Bool) {
    guard !busy else { return }
    if bundle, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { postComment() }
    guard !bundle || persist() else { return }
    busy = true
    player.pause()
    failed = false
    message = bundle ? "Exporting review bundle…" : "Saving video…"
    let document = document
    let file = file
    Task {
      defer {
        busy = false
        finishPendingClose()
      }
      do {
        try await Task.detached {
          if bundle {
            try VideoReviewStore.export(document, movie: file, to: destination)
          } else {
            try VideoReviewStore.copyVideo(file, to: destination)
          }
        }.value
        message = bundle ? "Review bundle exported" : "Video saved"
      } catch {
        pendingClose = nil
        fail(error.localizedDescription)
      }
    }
  }
  func requestClose(action: (() -> Void)? = nil) {
    if let frameEditor {
      frameEditor.requestClose { [weak self, weak frameEditor] in
        frameEditor?.onClose()
        self?.requestClose(action: action)
      }
      return
    }
    pendingClose = action ?? onClose
    if voiceRecording {
      stopVoice()
      return
    }
    if voiceFinishing || voiceRequesting || busy { return }
    if !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { postComment() }
    if unsaved { confirmClose = true } else { finishPendingClose() }
  }
  func cancelClose() {
    confirmClose = false
    pendingClose = nil
  }
  func saveAndClose() {
    confirmClose = false
    if persist() { finishPendingClose() }
  }
  func discardAndClose() {
    confirmClose = false
    unsaved = false
    comment = ""
    editingNote = nil
    finishPendingClose()
  }
  private func finishPendingClose() {
    guard !busy, !voiceRecording, !voiceFinishing, !voiceRequesting else { return }
    if pendingClose != nil, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      postComment()
    }
    guard !unsaved else {
      if pendingClose != nil { confirmClose = true }
      return
    }
    let action = pendingClose
    pendingClose = nil
    action?()
  }
  private func fail(_ text: String) {
    failed = true
    message = text
  }
  func shutdown() {
    guard !closed else { return }
    closed = true
    if !busy, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { postComment() }
    voiceTimer?.cancel()
    player.pause()
    voicePlayer?.stop()
    recorder?.stop()
    if let periodic {
      player.removeTimeObserver(periodic)
      self.periodic = nil
    }
    itemObservation = nil
  }
}
@MainActor
private final class ReviewVoiceDelegate: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
  var playbackFinished: () -> Void = {}
  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Task { @MainActor [weak self] in self?.playbackFinished() }
  }
  var finished: (Bool) -> Void = { _ in }
  nonisolated func audioRecorderDidFinishRecording(
    _ recorder: AVAudioRecorder, successfully flag: Bool
  ) {
    Task { @MainActor [weak self = self] in self?.finished(flag) }
  }
  nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    Task { @MainActor [weak self = self] in self?.finished(false) }
  }
}
