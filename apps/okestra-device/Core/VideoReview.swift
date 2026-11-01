import Foundation

public enum VideoReviewNoteKind: String, Codable, Sendable { case comment, frame, voice }
public struct VideoReviewNote: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var time: Double
  public var kind: VideoReviewNoteKind
  public var text: String
  public var attachment: String?
  public var duration: Double?
  public init(
    id: UUID = UUID(), time: Double, kind: VideoReviewNoteKind = .comment,
    text: String, attachment: String? = nil, duration: Double? = nil
  ) {
    self.id = id
    self.time = time
    self.kind = kind
    self.text = text
    self.attachment = attachment
    self.duration = duration
  }
}
public struct VideoReviewDocument: Codable, Equatable, Sendable {
  public var version = 1
  public var movie: String
  public var duration: Double
  public var notes: [VideoReviewNote] = []
  public init(movie: String, duration: Double) {
    self.movie = movie
    self.duration = duration
  }
  public func validated() throws -> Self {
    guard version == 1, duration.isFinite, duration > 0, notes.count <= 10_000,
      Self.safeFile(movie), Set(notes.map(\.id)).count == notes.count
    else { throw VideoReviewError.invalidDocument }
    for note in notes {
      guard note.time.isFinite, note.time >= 0, note.time <= duration + 0.1,
        note.text.count <= 10_000,
        note.duration.map({ $0.isFinite && $0 >= 0 && $0 <= 3600 }) ?? true,
        note.attachment.map(Self.safeFile) ?? (note.kind == .comment)
      else { throw VideoReviewError.invalidDocument }
    }
    return self
  }
  public static func safeFile(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && value.count <= 255
      && !value.contains("/") && !value.contains("\\")
      && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
  public static func timecode(_ seconds: Double) -> String {
    let value = seconds.isFinite ? max(0, min(seconds, 31_536_000)) : 0
    let whole = Int(value)
    return whole >= 3600
      ? String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
      : String(format: "%02d:%02d", whole / 60, whole % 60)
  }
  public func markdown() -> String {
    var lines = [
      "# Recording review", "", "Video: [\(movie)](\(Self.link(movie)))",
      "Duration: \(Self.timecode(duration))", "",
      "Comments and voice notes refer to timestamps in the original video. Annotated frames are separate PNG images.",
      "",
    ]
    for note in notes.sorted(by: { $0.time < $1.time }) {
      lines += [
        "## \(Self.timecode(note.time)) · \(note.kind.rawValue.capitalized)", "", note.text, "",
      ]
      if let file = note.attachment {
        lines += [
          "[\(note.kind == .voice ? "Voice note" : "Annotated frame")](assets/\(Self.link(file)))",
          "",
        ]
      }
    }
    if notes.isEmpty { lines += ["No review notes.", ""] }
    return lines.joined(separator: "\n")
  }
  private static func link(_ file: String) -> String {
    file.addingPercentEncoding(
      withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) ?? file
  }
}
public enum VideoReviewError: LocalizedError {
  case invalidDocument
  case missingAttachment(String)
  case archive(String)
  public var errorDescription: String? {
    switch self {
    case .invalidDocument:
      return "This recording’s review data is invalid or uses an unsupported version."
    case .missingAttachment(let file): return "A review attachment is missing: \(file)."
    case .archive(let detail): return "Could not export the review: \(detail)"
    }
  }
}
public enum VideoReviewStore {
  public static func folder(for movie: URL) -> URL {
    movie.deletingPathExtension().appendingPathExtension("okestra-review")
  }
  public static func load(movie: URL, duration: Double) throws -> VideoReviewDocument {
    let file = folder(for: movie).appendingPathComponent("review.json")
    guard FileManager.default.fileExists(atPath: file.path) else {
      return try VideoReviewDocument(movie: movie.lastPathComponent, duration: duration).validated()
    }
    let data = try Data(contentsOf: file)
    guard data.count <= 16 * 1024 * 1024 else { throw VideoReviewError.invalidDocument }
    let document = try JSONDecoder().decode(VideoReviewDocument.self, from: data).validated()
    guard document.movie == movie.lastPathComponent, abs(document.duration - duration) < 1 else {
      throw VideoReviewError.invalidDocument
    }
    return document
  }
  public static func save(_ document: VideoReviewDocument, movie: URL) throws {
    let document = try document.validated()
    let root = folder(for: movie)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(document).write(
      to: root.appendingPathComponent("review.json"), options: .atomic)
  }
  public static func assets(for movie: URL) -> URL {
    folder(for: movie).appendingPathComponent("assets")
  }
  public static func copyVideo(_ source: URL, to destination: URL) throws {
    if source.standardizedFileURL == destination.standardizedFileURL { return }
    let fm = FileManager.default
    var directory: ObjCBool = false
    if fm.fileExists(atPath: destination.path, isDirectory: &directory), directory.boolValue {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    let staged = destination.deletingLastPathComponent().appendingPathComponent(
      ".okestra-video-" + UUID().uuidString)
    defer { try? fm.removeItem(at: staged) }
    try fm.copyItem(at: source, to: staged)
    if fm.fileExists(atPath: destination.path) {
      _ = try fm.replaceItemAt(destination, withItemAt: staged)
    } else {
      try fm.moveItem(at: staged, to: destination)
    }
  }
  public static func export(_ document: VideoReviewDocument, movie: URL, to destination: URL) throws
  {
    var document = try document.validated()
    let fm = FileManager.default
    let temporary = fm.temporaryDirectory.appendingPathComponent(
      "okestra-video-review-" + UUID().uuidString)
    defer { try? fm.removeItem(at: temporary) }
    let folder = temporary.appendingPathComponent("Recording Review")
    let assets = folder.appendingPathComponent("assets")
    try fm.createDirectory(at: assets, withIntermediateDirectories: true)
    let movieName = "recording." + (movie.pathExtension.lowercased() == "mp4" ? "mp4" : "mov")
    try fm.copyItem(at: movie, to: folder.appendingPathComponent(movieName))
    for file in Set(document.notes.compactMap(\.attachment)) {
      let source = self.assets(for: movie).appendingPathComponent(file)
      let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw VideoReviewError.missingAttachment(file)
      }
      try fm.copyItem(at: source, to: assets.appendingPathComponent(file))
    }
    document.movie = movieName
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(document).write(to: folder.appendingPathComponent("review.json"))
    try document.markdown().write(
      to: folder.appendingPathComponent("Review.md"), atomically: true, encoding: .utf8)
    let archive = temporary.appendingPathComponent("review.zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--keepParent", folder.path, archive.path]
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    let details = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw VideoReviewError.archive(String(decoding: details, as: UTF8.self))
    }
    let staged = destination.deletingLastPathComponent().appendingPathComponent(
      ".okestra-review-" + UUID().uuidString + ".zip")
    defer { try? fm.removeItem(at: staged) }
    try fm.copyItem(at: archive, to: staged)
    if fm.fileExists(atPath: destination.path) {
      _ = try fm.replaceItemAt(destination, withItemAt: staged)
    } else {
      try fm.moveItem(at: staged, to: destination)
    }
  }
}
