import AVKit
import AppKit
import SwiftUI

struct RecordingPreviewOverlay: View {
  @ObservedObject var reviews: VideoReviewController
  let focusMode: Bool
  var body: some View {
    if let preview = reviews.preview {
      RecordingPreviewFlight(preview: preview, reviews: reviews, focusMode: focusMode).id(
        preview.id)
    }
  }
}
private struct RecordingPreviewFlight: View {
  let preview: RecordedVideoPreview
  @ObservedObject var reviews: VideoReviewController
  let focusMode: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var docked = false
  @State private var arrived = false
  var body: some View {
    GeometryReader { geometry in
      let ratio = preview.image.size.width / max(1, preview.image.size.height)
      let thumb = CGSize(width: min(172, 164 * ratio), height: min(164, 172 / ratio))
      let initialHeight = min(geometry.size.height * 0.65, geometry.size.width * 0.65 / ratio)
      let bottom = focusMode ? 14.0 : 122.0
      ZStack {
        Image(nsImage: preview.image).resizable().scaledToFit()
          .frame(
            width: docked ? thumb.width : initialHeight * ratio,
            height: docked ? thumb.height : initialHeight
          )
          .background(.black).clipShape(RoundedRectangle(cornerRadius: docked ? 8 : 0))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(docked ? 0.35 : 0)))
          .overlay {
            if arrived {
              Image(systemName: "play.fill").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(11).background(.black.opacity(0.6), in: Circle()).allowsHitTesting(false)
            }
          }
          .overlay(alignment: .bottomTrailing) {
            if arrived {
              Text(VideoReviewDocument.timecode(preview.duration)).font(
                .system(size: 9, weight: .medium)
              ).monospacedDigit()
                .padding(4).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.white).padding(5).allowsHitTesting(false)
            }
          }
          .shadow(color: .black.opacity(0.4), radius: docked ? 12 : 0, y: 4)
          .onTapGesture { reviews.open(preview.file) }
          .onDrag { NSItemProvider(contentsOf: preview.file) ?? NSItemProvider() }
          .accessibilityLabel("Recorded video. Click to review and annotate.")
          .accessibilityAddTraits(.isButton).accessibilityAction { reviews.open(preview.file) }
          .help("Click to review · Drag the saved video into another app")
          .contextMenu {
            Button("Open video editor") { reviews.open(preview.file) }
            Button("Show in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([preview.file])
            }
            Button("Dismiss") { reviews.dismissPreview() }
          }
          .position(
            x: docked ? geometry.size.width - 18 - thumb.width / 2 : geometry.size.width / 2,
            y: docked
              ? geometry.size.height - bottom - 30 - thumb.height / 2 : geometry.size.height / 2
          )
          .allowsHitTesting(arrived && !reviews.dismissing)
        if arrived {
          HStack(spacing: 10) {
            Button {
              reviews.open(preview.file)
            } label: {
              Label("Edit", systemImage: "pencil")
            }
            .accessibilityLabel("Edit recorded video")
            Button {
              reviews.dismissPreview()
            } label: {
              Image(systemName: "xmark")
            }
            .accessibilityLabel("Dismiss recording preview")
          }.font(.system(size: 10)).buttonStyle(.borderless).padding(7)
            .background(.regularMaterial, in: Capsule())
            .position(
              x: geometry.size.width - 18 - max(thumb.width, 100) / 2,
              y: geometry.size.height - bottom - 13)
        }
      }
      .opacity(reviews.dismissing ? 0 : 1)
      .offset(y: reviews.dismissing && !reduceMotion ? 28 : 0)
      .allowsHitTesting(!reviews.dismissing)
      .task {
        try? await Task.sleep(nanoseconds: 30_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.86)) {
          docked = true
        }
        try? await Task.sleep(nanoseconds: 550_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.12)) { arrived = true }
      }
    }
  }
}

struct VideoEditorPresentation: ViewModifier {
  @ObservedObject var reviews: VideoReviewController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func body(content: Content) -> some View {
    ZStack {
      content.allowsHitTesting(reviews.editor == nil).accessibilityHidden(reviews.editor != nil)
      if let editor = reviews.editor {
        VideoEditor(model: editor).id(editor.document.movie)
          .transition(
            reduceMotion
              ? .opacity : .opacity.combined(with: .scale(scale: 0.94, anchor: .bottomTrailing))
          )
          .zIndex(20)
      }
      if reviews.loading {
        VStack(spacing: 10) {
          ProgressView()
          Text("Opening recording…").font(.system(size: 12))
        }
        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      }
    }
    .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.25), value: reviews.editor != nil)
    .alert(
      "Recording",
      isPresented: Binding(get: { reviews.error != nil }, set: { if !$0 { reviews.error = nil } })
    ) {
      Button("OK") { reviews.error = nil }
    } message: {
      Text(reviews.error ?? "")
    }
  }
}

struct VideoEditor: View {
  @ObservedObject var model: VideoEditorModel
  var body: some View {
    VStack(spacing: 0) {
      header.padding(.horizontal, 14).padding(.top, 38).padding(.bottom, 12)
      Divider()
      GeometryReader { geometry in
        if geometry.size.width >= 760 {
          HStack(spacing: 0) {
            playback
            Divider()
            notesPanel.frame(width: 300)
          }
        } else {
          VStack(spacing: 0) {
            playback
            Divider()
            notesPanel.frame(height: min(260, max(110, geometry.size.height * 0.42)))
          }
        }
      }
      Divider()
      HStack(spacing: 8) {
        if model.busy || model.voiceFinishing || model.voiceRequesting {
          ProgressView().controlSize(.mini)
        } else if model.failed {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        Text(model.message).foregroundStyle(model.failed ? Color.primary : Color.secondary)
          .lineLimit(1).help(model.message)
        Spacer(minLength: 0)
        Text("\(model.document.notes.count) notes").foregroundStyle(.tertiary).fixedSize()
      }.font(.system(size: 10)).padding(.horizontal, 12).padding(.vertical, 8)
    }
    .background(Color(nsColor: .windowBackgroundColor)).ignoresSafeArea(.container, edges: .top)
    .background(VideoEditorWindowActions(model: model))
    .overlay {
      if let frame = model.frameEditor {
        ScreenshotEditor(model: frame).id(frame.id)
      }
    }
    .onExitCommand { model.requestClose() }
    .onDisappear { model.shutdown() }
    .alert("Save your review notes?", isPresented: $model.confirmClose) {
      Button("Save") { model.saveAndClose() }
      Button("Cancel", role: .cancel) { model.cancelClose() }
      Button("Discard Changes", role: .destructive) { model.discardAndClose() }
    } message: {
      Text("The last save failed. Keep this editor open or retry saving your notes.")
    }
  }
  private var header: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        Image(systemName: "video").font(.system(size: 18)).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text("Recording review").font(.system(size: 13, weight: .semibold))
          Text(model.file.lastPathComponent).font(.system(size: 10)).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
        }.frame(maxWidth: 260, alignment: .leading)
        Spacer(minLength: 4)
        actions(compact: false)
      }
      HStack(spacing: 8) { actions(compact: true) }
    }.controlSize(.small)
  }
  private func actions(compact: Bool) -> some View {
    HStack(spacing: 8) {
      Menu {
        Button("Save Video…") { model.saveVideo() }
        Button("Save Review Notes") { _ = model.persist() }
        Button("Copy Timestamped Notes") { model.copyNotes() }
        Button("Show Recording in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([model.file])
        }
      } label: {
        Label(compact ? "" : "Save", systemImage: "square.and.arrow.down")
      }
      .help("Save the video or review notes").disabled(
        model.busy || model.voiceRecording || model.voiceFinishing || model.voiceRequesting)
      Spacer(minLength: 0)
      Button {
        model.exportReview()
      } label: {
        if compact {
          Image(systemName: "square.and.arrow.up")
        } else {
          Label("Export for Agent…", systemImage: "square.and.arrow.up")
        }
      }.help("Export a ZIP with the video, timestamped notes, annotated frames and voice notes")
        .accessibilityLabel("Export review for agent").disabled(
          model.busy || model.voiceRecording || model.voiceFinishing || model.voiceRequesting)
      Button("Done") { model.requestClose() }.buttonStyle(.borderedProminent).help(
        "Return to the device")
    }
  }
  private var playback: some View {
    VStack(spacing: 0) {
      GeometryReader { geometry in
        let width = max(
          1, min(geometry.size.width - 40, (geometry.size.height - 40) * model.aspectRatio))
        ReviewPlayerSurface(model: model).frame(
          width: width, height: width / max(0.01, model.aspectRatio)
        )
        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
      }.background(WorkspaceCanvasBackground())
      Divider()
      VStack(spacing: 8) {
        HStack(spacing: 10) {
          Button {
            model.togglePlayback()
          } label: {
            Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 16)
          }
          .buttonStyle(.borderless).accessibilityLabel(
            model.playing ? "Pause recording" : "Play recording"
          )
          .disabled(model.voiceRecording || model.voiceFinishing)
          Text(VideoReviewDocument.timecode(model.position)).monospacedDigit().frame(minWidth: 36)
          VStack(spacing: 2) {
            Slider(
              value: Binding(get: { model.position }, set: { model.seek($0) }),
              in: 0...max(0.01, model.duration),
              onEditingChanged: { editing in
                model.scrubbing = editing
                if editing { model.player.pause() }
              }
            )
            .accessibilityLabel("Recording timeline").disabled(model.voiceRecording)
            GeometryReader { geometry in
              ForEach(model.notes) { note in
                Circle().fill(
                  note.kind == .voice ? Color.orange : note.kind == .frame ? .purple : .accentColor
                )
                .frame(width: 4, height: 4)
                .position(
                  x: min(
                    geometry.size.width - 2,
                    max(2, geometry.size.width * note.time / model.duration)), y: 2
                )
                .help("\(VideoReviewDocument.timecode(note.time)) · \(note.text)")
                .onTapGesture { model.seek(note.time) }
              }
            }.frame(height: 4)
          }
          Text(VideoReviewDocument.timecode(model.duration)).foregroundStyle(.secondary)
            .monospacedDigit()
        }.font(.system(size: 10))
        ViewThatFits(in: .horizontal) {
          annotationActions(compact: false)
          annotationActions(compact: true)
        }
      }.padding(12)
    }
  }
  private func annotationActions(compact: Bool) -> some View {
    HStack(spacing: 12) {
      Button {
        model.annotateFrame()
      } label: {
        Label("Annotate Frame", systemImage: "rectangle.and.pencil.and.ellipsis").labelStyle(
          EditorActionLabelStyle(compact: compact))
      }.help("Annotate a still frame; the original video remains unchanged").accessibilityLabel(
        "Annotate current video frame"
      )
      .disabled(model.busy || model.voiceRecording || model.voiceFinishing || model.voiceRequesting)
      Button {
        if model.voiceRecording { model.stopVoice() } else { model.startVoice() }
      } label: {
        Label(
          model.voiceRecording
            ? "Stop Voice \(VideoReviewDocument.timecode(model.voiceElapsed))" : "Voice Note",
          systemImage: model.voiceRecording ? "stop.circle.fill" : "mic"
        )
        .labelStyle(EditorActionLabelStyle(compact: compact))
      }.foregroundStyle(model.voiceRecording ? Color.red : Color.primary)
        .help("Record a microphone note at this timestamp").accessibilityLabel(
          model.voiceRecording ? "Stop voice note" : "Record voice note"
        )
        .disabled(model.busy || model.voiceFinishing || model.voiceRequesting)
      if compact && model.voiceRecording {
        Text(VideoReviewDocument.timecode(model.voiceElapsed)).monospacedDigit().foregroundStyle(
          .red)
      }
      Spacer(minLength: 0)
    }.controlSize(.small).font(.system(size: 11))
  }
  private var notesPanel: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Review notes").font(.system(size: 12, weight: .semibold))
        Spacer()
        Text(VideoReviewDocument.timecode(model.position)).font(.system(size: 10)).monospacedDigit()
          .foregroundStyle(.secondary)
      }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
      HStack(alignment: .bottom, spacing: 8) {
        TextField("Comment at this moment…", text: $model.comment, axis: .vertical)
          .lineLimit(1...3).textFieldStyle(.roundedBorder).font(.system(size: 12))
          .accessibilityLabel("Video review comment")
          .onSubmit { model.postComment() }
        if model.editingNote != nil {
          Button {
            model.cancelEdit()
          } label: {
            Image(systemName: "xmark")
          }.buttonStyle(.borderless).help("Cancel editing comment")
        }
        Button {
          model.postComment()
        } label: {
          Image(systemName: model.editingNote == nil ? "plus" : "checkmark")
        }
        .accessibilityLabel(model.editingNote == nil ? "Add timestamped comment" : "Update comment")
        .disabled(model.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }.padding(.horizontal, 12).padding(.bottom, 10).disabled(model.busy)
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if model.notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
              Text("Make the next step clear.").font(.system(size: 12, weight: .medium))
              Text(
                "Add comments, mark up a frame or leave a voice note. Each note links to a moment in this recording."
              )
              .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(14)
          }
          ForEach(model.notes) { note in
            noteRow(note)
            Divider().padding(.leading, 12)
          }
        }
      }
    }.background(Color(nsColor: .controlBackgroundColor))
  }
  private func noteRow(_ note: VideoReviewNote) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Button {
        model.player.pause()
        model.seek(note.time)
      } label: {
        Text(VideoReviewDocument.timecode(note.time)).font(.system(size: 10, weight: .medium))
          .monospacedDigit()
      }.buttonStyle(.borderless).help("Jump to this moment")
      VStack(alignment: .leading, spacing: 5) {
        Text(note.text).font(.system(size: 11)).lineLimit(4).frame(
          maxWidth: .infinity, alignment: .leading)
        if note.kind == .voice {
          Button {
            model.playVoice(note)
          } label: {
            Label(
              "\(model.voicePlayingID == note.id ? "Stop voice" : "Play voice") · \(VideoReviewDocument.timecode(note.duration ?? 0))",
              systemImage: "waveform")
          }
          .buttonStyle(.borderless).font(.system(size: 10)).disabled(model.voiceRecording)
        } else if note.kind == .frame {
          Button {
            model.viewFrame(note)
          } label: {
            Label("Open annotated frame", systemImage: "photo")
          }
          .buttonStyle(.borderless).font(.system(size: 10))
        }
      }
      Menu {
        Button("Edit Comment") { model.edit(note) }
        Button("Remove Note") { model.remove(note) }
      } label: {
        Image(systemName: "ellipsis")
      }.menuStyle(.borderlessButton).fixedSize().help("Note options")
    }.padding(12).disabled(model.busy)
  }
}
private struct EditorActionLabelStyle: LabelStyle {
  let compact: Bool
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 5) {
      configuration.icon
      if !compact { configuration.title }
    }
  }
}
private struct ReviewPlayerSurface: NSViewRepresentable {
  @ObservedObject var model: VideoEditorModel
  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.player = model.player
    view.controlsStyle = .none
    view.videoGravity = .resizeAspect
    view.showsFullScreenToggleButton = false
    return view
  }
  func updateNSView(_ view: AVPlayerView, context: Context) {
    view.player = model.player
    model.window = view.window
  }
}
private struct VideoEditorWindowActions: NSViewRepresentable {
  let model: VideoEditorModel
  func makeNSView(context: Context) -> VideoWindowActionView { VideoWindowActionView(model: model) }
  func updateNSView(_ view: VideoWindowActionView, context: Context) {}
  static func dismantleNSView(_ view: VideoWindowActionView, coordinator: ()) { view.detach() }
}
private final class VideoWindowActionView: NSView {
  let model: VideoEditorModel
  private weak var button: NSButton?
  private weak var originalTarget: AnyObject?
  private var originalAction: Selector?
  private var monitor: Any?
  init(model: VideoEditorModel) {
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
      guard let self, event.window === window, window?.attachedSheet == nil else { return event }
      if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
        self.closeWindow()
        return nil
      }
      if event.keyCode == 53, self.model.frameEditor == nil {
        self.model.requestClose()
        return nil
      }
      return event
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

struct OpenRecordingCommand: View {
  @ObservedObject var reviews: VideoReviewController
  let window: () -> NSWindow?
  var body: some View {
    Button("Open Recording…") { reviews.openFile(in: window()) }
      .disabled(reviews.editor != nil || reviews.loading)
  }
}
