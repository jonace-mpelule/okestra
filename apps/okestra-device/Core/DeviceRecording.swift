import AVFoundation
import Foundation

public final class DeviceRecording: @unchecked Sendable {
  private let queue = DispatchQueue(label: "dev.okestra.recording", qos: .utility)
  private let lock = NSLock()
  private var active: MovieRecording?
  private var pending = 0
  public var onState: (Bool, String, URL?) -> Void = { _, _, _ in }
  public init() {}
  public func start(url: URL, audio: Bool) throws {
    lock.lock()
    defer { lock.unlock() }
    guard active == nil else { throw DeviceError.message("A recording is already active.") }
    let recording = try MovieRecording(url: url, audio: audio)
    active = recording
    onState(true, "Waiting for the next video keyframe…", nil)
    queue.asyncAfter(deadline: .now() + 30) { [weak self, weak recording] in
      guard let self, let recording, !recording.started else { return }
      self.finish(
        recording, note: "No video keyframe arrived. Try again while the device screen is changing."
      )
    }
  }
  public func consumeVideo(_ sample: CMSampleBuffer) {
    enqueue { recording in try recording.video(sample) }
  }
  public func consumeAudio(_ data: Data, timestamp: UInt64) {
    enqueue { recording in try recording.audio(data, timestamp: timestamp) }
  }
  private func enqueue(_ action: @escaping (MovieRecording) throws -> Void) {
    lock.lock()
    guard let recording = active else {
      lock.unlock()
      return
    }
    guard pending < 180 else {
      lock.unlock()
      stop(note: "Recording stopped because storage could not keep up.")
      return
    }
    pending += 1
    lock.unlock()
    queue.async {
      self.lock.lock()
      self.pending = max(0, self.pending - 1)
      self.lock.unlock()
      guard !recording.finishing else { return }
      do {
        let wasStarted = recording.started
        try action(recording)
        if !wasStarted && recording.started { self.onState(true, "Recording…", nil) }
      } catch { self.finish(recording, note: error.localizedDescription) }
    }
  }
  public func stop(note: String = "") {
    lock.lock()
    let recording = active
    lock.unlock()
    if let recording { queue.async { self.finish(recording, note: note) } }
  }
  private func finish(_ recording: MovieRecording, note: String) {
    guard !recording.finishing else { return }
    recording.finishing = true
    onState(true, "Saving recording…", nil)
    recording.finish { result in
      self.lock.lock()
      if self.active === recording { self.active = nil }
      self.lock.unlock()
      switch result {
      case .success(let url):
        self.onState(
          false,
          note.isEmpty
            ? "Saved \(url.lastPathComponent)." : "\(note) Saved \(url.lastPathComponent).", url)
      case .failure(let error):
        self.onState(
          false,
          note.isEmpty ? error.localizedDescription : note + " " + error.localizedDescription, nil)
      }
    }
  }
}

private final class MovieRecording {
  let writer: AVAssetWriter
  let url: URL
  let includesAudio: Bool
  var started = false
  var finishing = false
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var dimensions: CMVideoDimensions?
  private var firstTime = CMTime.invalid
  private var pendingVideo: CMSampleBuffer?
  private var startedAt = 0.0
  init(url: URL, audio: Bool) throws {
    self.url = url
    includesAudio = audio
    // NSSavePanel has already obtained the user's overwrite decision.
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    writer = try AVAssetWriter(outputURL: url, fileType: .mov)
  }
  func video(_ sample: CMSampleBuffer) throws {
    guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
    let size = CMVideoFormatDescriptionGetDimensions(format)
    if let dimensions, dimensions.width != size.width || dimensions.height != size.height {
      throw DeviceError.message("Recording stopped because the video dimensions changed.")
    }
    if !started {
      let attachments =
        CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
        as? [[String: Any]]
      guard attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true else {
        return
      }
      let input = AVAssetWriterInput(
        mediaType: .video, outputSettings: nil, sourceFormatHint: format)
      input.expectsMediaDataInRealTime = true
      guard writer.canAdd(input) else {
        throw DeviceError.message("Cannot record this video format.")
      }
      writer.add(input)
      videoInput = input
      if includesAudio {
        let audio = AVAssetWriterInput(
          mediaType: .audio,
          outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
          ])
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(audio) else {
          throw DeviceError.message("Cannot add the recording's audio track.")
        }
        writer.add(audio)
        audioInput = audio
      }
      guard writer.startWriting() else {
        throw writer.error ?? DeviceError.message("Cannot start recording.")
      }
      firstTime = CMSampleBufferGetPresentationTimeStamp(sample)
      writer.startSession(atSourceTime: firstTime)
      dimensions = size
      started = true
      startedAt = ProcessInfo.processInfo.systemUptime
    }
    if let previous = pendingVideo {
      let delta = CMTimeSubtract(
        CMSampleBufferGetPresentationTimeStamp(sample),
        CMSampleBufferGetPresentationTimeStamp(previous))
      try appendVideo(
        previous,
        duration: delta.isValid && delta.seconds > 0 ? delta : CMTime(value: 1, timescale: 60))
    }
    pendingVideo = sample
  }
  private func appendVideo(_ sample: CMSampleBuffer, duration: CMTime) throws {
    guard let input = videoInput, input.isReadyForMoreMediaData else {
      throw DeviceError.message("Recording stopped because storage could not keep up.")
    }
    var timing = CMSampleTimingInfo(
      duration: duration,
      presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
      decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sample))
    var timed: CMSampleBuffer?
    guard
      CMSampleBufferCreateCopyWithNewTiming(
        allocator: kCFAllocatorDefault, sampleBuffer: sample,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &timed) == noErr,
      let timed, input.append(timed)
    else {
      throw writer.error ?? DeviceError.message("Cannot write video.")
    }
  }
  func audio(_ data: Data, timestamp: UInt64) throws {
    guard started, let input = audioInput else { return }
    let pts = CMTime(value: Int64(timestamp), timescale: 1_000_000)
    guard CMTimeCompare(pts, firstTime) >= 0 else { return }
    let frames = try DeviceAudioPCM.frameCount(data)
    var asbd = AudioStreamBasicDescription(
      mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
      mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    guard
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format) == noErr, let format
    else { throw DeviceError.message("Invalid audio recording format.") }
    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: data.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
        dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr, let block
    else {
      throw DeviceError.message("Cannot allocate audio recording buffer.")
    }
    let copied = data.withUnsafeBytes {
      CMBlockBufferReplaceDataBytes(
        with: $0.baseAddress!, blockBuffer: block,
        offsetIntoDestination: 0, dataLength: data.count)
    }
    guard copied == noErr else { throw DeviceError.message("Cannot copy recorded audio.") }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: pts,
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    var sampleSize = 4
    guard
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: block,
        formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr,
      let sample
    else { throw DeviceError.message("Cannot prepare recorded audio.") }
    guard input.isReadyForMoreMediaData, input.append(sample) else {
      throw writer.error
        ?? DeviceError.message("Recording stopped because audio storage could not keep up.")
    }
  }
  func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
    guard started else {
      writer.cancelWriting()
      try? FileManager.default.removeItem(at: url)
      completion(.failure(DeviceError.message("No video was recorded.")))
      return
    }
    if writer.status == .writing {
      do {
        // Hold the last frame until Stop, including recordings of an entirely static screen.
        if let sample = pendingVideo {
          let last = CMSampleBufferGetPresentationTimeStamp(sample)
          let elapsed = max(1.0 / 60, ProcessInfo.processInfo.systemUptime - startedAt)
          let stop = CMTimeAdd(firstTime, CMTime(seconds: elapsed, preferredTimescale: 1_000_000))
          let remainder = CMTimeSubtract(stop, last)
          try appendVideo(
            sample,
            duration: remainder.seconds > 1.0 / 60 ? remainder : CMTime(value: 1, timescale: 60))
          pendingVideo = nil
        }
      } catch {
        writer.cancelWriting()
        completion(.failure(error))
        return
      }
      videoInput?.markAsFinished()
      audioInput?.markAsFinished()
      writer.finishWriting {
        if self.writer.status == .completed {
          completion(.success(self.url))
        } else {
          completion(
            .failure(self.writer.error ?? DeviceError.message("Recording could not be saved.")))
        }
      }
    } else {
      completion(.failure(writer.error ?? DeviceError.message("Recording could not be saved.")))
    }
  }
}
