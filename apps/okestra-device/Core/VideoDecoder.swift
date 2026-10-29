import AVFoundation
import Foundation

public final class VideoDecoder {
  private var sps: Data?, pps: Data?
  private var format: CMVideoFormatDescription?
  public init() {}
  public func consume(_ data: Data, config: Bool, keyframe: Bool) throws -> CMSampleBuffer? {
    let units = try H264.units(data)
    var changed = false
    for unit in units {
      if unit.first! & 31 == 7 {
        sps = unit
        changed = true
      }
      if unit.first! & 31 == 8 {
        pps = unit
        changed = true
      }
    }
    if changed, let sps, let pps {
      let status = sps.withUnsafeBytes { a in
        pps.withUnsafeBytes { b in
          var pointers = [
            a.bindMemory(to: UInt8.self).baseAddress!, b.bindMemory(to: UInt8.self).baseAddress!,
          ]
          var sizes = [sps.count, pps.count]
          return CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: &pointers,
            parameterSetSizes: &sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        }
      }
      guard status == noErr else {
        throw DeviceError.message("Cannot configure H.264 decoder (\(status))")
      }
    }
    if config { return nil }
    guard let format else {
      throw DeviceError.message("Video arrived without its decoder configuration")
    }
    let frame = H264.avcc(units.filter { ![7, 8].contains(Int($0.first! & 31)) })
    guard !frame.isEmpty else { return nil }
    var block: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: frame.count,
      blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
      dataLength: frame.count, flags: 0, blockBufferOut: &block)
    guard status == noErr, let block else {
      throw DeviceError.message("Cannot allocate video frame")
    }
    status = frame.withUnsafeBytes {
      CMBlockBufferReplaceDataBytes(
        with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: frame.count
      )
    }
    guard status == noErr else { throw DeviceError.message("Cannot copy video frame") }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    var size = frame.count
    status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
      sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
      sampleSizeArray: &size, sampleBufferOut: &sample)
    guard status == noErr, let sample else {
      throw DeviceError.message("Cannot prepare video frame (\(status))")
    }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
      let dictionary = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
      CFDictionarySetValue(
        dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
        Unmanaged.passUnretained(keyframe ? kCFBooleanFalse : kCFBooleanTrue).toOpaque())
    }
    return sample
  }
}
