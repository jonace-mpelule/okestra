import AVFoundation
import Foundation

// scrcpy 3.3.4 raw audio: 48 kHz, stereo, signed 16-bit little endian.
// Playback has its own queue and a bounded buffer; it never waits on video/UI work.
public final class DeviceAudioPlayer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "dev.okestra.audio", qos: .userInteractive)
  private let lock = NSLock()
  private var accepting = true
  private var pending = 0
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var volume: Float
  public init(volume: Float) { self.volume = min(1, max(0, volume)) }
  public func setVolume(_ value: Float) {
    queue.async {
      self.volume = min(1, max(0, value))
      self.player?.volume = self.volume
    }
  }
  public func play(_ data: Data, onError: @escaping (String) -> Void) {
    lock.lock()
    guard accepting, pending < 12 else {
      lock.unlock()
      return
    }
    pending += 1
    lock.unlock()
    queue.async { [self] in
      do {
        self.lock.lock()
        let active = self.accepting
        self.lock.unlock()
        guard active else {
          self.complete()
          return
        }
        let frames = try DeviceAudioPCM.frameCount(data)
        let format = AVAudioFormat(
          standardFormatWithSampleRate: DeviceAudioPCM.sampleRate, channels: 2)!
        guard
          let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
          let channels = buffer.floatChannelData
        else { throw DeviceError.message("Cannot allocate audio playback buffer.") }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
          let bytes = raw.bindMemory(to: UInt8.self)
          for frame in 0..<frames {
            for channel in 0..<2 {
              let offset = frame * 4 + channel * 2
              let value = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
              channels[channel][frame] = Float(value) / 32768
            }
          }
        }
        if self.engine == nil {
          let engine = AVAudioEngine()
          let player = AVAudioPlayerNode()
          engine.attach(player)
          engine.connect(player, to: engine.mainMixerNode, format: format)
          player.volume = self.volume
          try engine.start()
          player.play()
          self.engine = engine
          self.player = player
        }
        self.player?.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
          [weak self] _ in self?.complete()
        }
      } catch {
        self.complete()
        self.stop()
        onError("Audio playback stopped: \(error.localizedDescription). Video continues.")
      }
    }
  }
  private func complete() {
    lock.lock()
    pending = max(0, pending - 1)
    lock.unlock()
  }
  public func stop() {
    lock.lock()
    accepting = false
    lock.unlock()
    queue.async {
      self.player?.stop()
      self.engine?.stop()
      self.player = nil
      self.engine = nil
    }
  }
}
