import Foundation
import XCTest

@testable import DeviceCore

final class VideoReviewTests: XCTestCase {
  func testReviewRoundTripAndPortableNotes() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let movie = root.appendingPathComponent("My Capture.mov")
    try Data("original video".utf8).write(to: movie)
    var document = VideoReviewDocument(movie: movie.lastPathComponent, duration: 85)
    document.notes = [
      VideoReviewNote(time: 12.5, text: "Check this button →"),
      VideoReviewNote(
        time: 40, kind: .voice, text: "Explain the issue", attachment: "voice.m4a", duration: 3),
    ]
    try VideoReviewStore.save(document, movie: movie)
    XCTAssertEqual(try VideoReviewStore.load(movie: movie, duration: 85), document)
    XCTAssertTrue(document.markdown().contains("00:12"))
    XCTAssertTrue(document.markdown().contains("Check this button →"))
    XCTAssertTrue(document.markdown().contains("My%20Capture.mov"))
    XCTAssertFalse(document.markdown().contains(root.path))
  }
  func testInvalidTimesPathsVersionsAndDuplicateIDsAreRejected() throws {
    var document = VideoReviewDocument(movie: "capture.mov", duration: 10)
    for time in [-1.0, Double.nan, Double.infinity, 12] {
      document.notes = [VideoReviewNote(time: time, text: "Invalid")]
      XCTAssertThrowsError(try document.validated())
    }
    for file in ["../secret", "/private/secret", "a\\b", "..", "bad\nname"] {
      document.notes = [VideoReviewNote(time: 1, kind: .frame, text: "Frame", attachment: file)]
      XCTAssertThrowsError(try document.validated())
    }
    let note = VideoReviewNote(time: 1, text: "Duplicate")
    document.notes = [note, note]
    XCTAssertThrowsError(try document.validated())
    document.notes = []
    document.version = 2
    XCTAssertThrowsError(try document.validated())
  }
  func testBundleIncludesMovieNotesFramesAndVoiceAndPreservesOriginal() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let movie = root.appendingPathComponent("Capture.mov")
    let original = Data("movie bytes".utf8)
    try original.write(to: movie)
    var document = VideoReviewDocument(movie: movie.lastPathComponent, duration: 20)
    document.notes = [
      VideoReviewNote(time: 2, kind: .frame, text: "Here", attachment: "frame.png"),
      VideoReviewNote(time: 4, kind: .voice, text: "Listen", attachment: "voice.m4a", duration: 1),
    ]
    try VideoReviewStore.save(document, movie: movie)
    let assets = VideoReviewStore.assets(for: movie)
    try Data("image".utf8).write(to: assets.appendingPathComponent("frame.png"))
    try Data("voice".utf8).write(to: assets.appendingPathComponent("voice.m4a"))
    let zip = root.appendingPathComponent("Review.zip")
    try VideoReviewStore.export(document, movie: movie, to: zip)
    let names = try unzip(["-Z1", zip.path])
    for entry in [
      "recording.mov", "review.json", "Review.md", "assets/frame.png", "assets/voice.m4a",
    ] {
      XCTAssertTrue(names.contains("Recording Review/" + entry), entry)
    }
    let json = try unzip(["-p", zip.path, "Recording Review/review.json"])
    let exported = try JSONDecoder().decode(VideoReviewDocument.self, from: Data(json.utf8))
    XCTAssertEqual(exported.movie, "recording.mov")
    XCTAssertEqual(exported.notes, document.notes)
    XCTAssertEqual(try Data(contentsOf: movie), original)
    let oldArchive = try Data(contentsOf: zip)
    try FileManager.default.removeItem(at: assets.appendingPathComponent("voice.m4a"))
    XCTAssertThrowsError(try VideoReviewStore.export(document, movie: movie, to: zip))
    XCTAssertEqual(try Data(contentsOf: zip), oldArchive)
  }
  func testVideoCopyIsLosslessAndRefusesDirectoryDestination() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("original.mov")
    let copy = root.appendingPathComponent("copy.mov")
    let bytes = Data((0..<256).map(UInt8.init))
    try bytes.write(to: source)
    try VideoReviewStore.copyVideo(source, to: copy)
    try VideoReviewStore.copyVideo(source, to: source)
    XCTAssertEqual(try Data(contentsOf: copy), bytes)
    XCTAssertEqual(try Data(contentsOf: source), bytes)
    XCTAssertThrowsError(try VideoReviewStore.copyVideo(source, to: root))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }
  private func temporary() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "video-review-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
  private func unzip(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    return String(decoding: data, as: UTF8.self)
  }
}
