import AVFoundation
import VideoToolbox

// Called serially on the capture worker, never on the main/UI thread. Decode every compressed
// picture to preserve reference frames; only decoded output may be coalesced by the mailbox.
public final class RealtimeVideoDecoder {
  private var session: VTDecompressionSession?
  private var format: CMFormatDescription?
  public private(set) var hardwareAccelerated: Bool?
  public init() {}
  deinit { if let session { VTDecompressionSessionInvalidate(session) } }
  public func decode(_ sample: CMSampleBuffer) throws -> CMSampleBuffer? {
    guard let inputFormat = CMSampleBufferGetFormatDescription(sample) else { return nil }
    if format == nil || !CMFormatDescriptionEqual(format!, otherFormatDescription: inputFormat) {
      if let session { VTDecompressionSessionInvalidate(session) }
      session = nil
      format = nil
      let spec =
        [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:],
      ]
      let status = VTDecompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        formatDescription: inputFormat, decoderSpecification: spec,
        imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
        decompressionSessionOut: &session)
      guard status == noErr, let session else {
        throw DeviceError.message("Cannot create video decoder (\(status))")
      }
      _ = VTSessionSetProperty(
        session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
      var hardware: Unmanaged<CFTypeRef>?
      if VTSessionCopyProperty(
        session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
        allocator: kCFAllocatorDefault, valueOut: &hardware) == noErr
      {
        hardwareAccelerated = hardware?.takeRetainedValue() as? Bool
      }
      format = inputFormat
    }
    guard let session else { return nil }
    let result = DecodedPicture()
    // No asynchronous/temporal flags: VT guarantees the callback finishes before this returns.
    let status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
    ) {
      status, _, image, _, _ in
      result.status = status
      result.image = image
    }
    guard status == noErr, result.status == noErr else {
      throw DeviceError.message("Video decode failed (\(status == noErr ? result.status : status))")
    }
    guard let image = result.image else { return nil }
    var description: CMVideoFormatDescription?
    var output: CMSampleBuffer?
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
      decodeTimeStamp: .invalid)
    let descriptionStatus = CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: image, formatDescriptionOut: &description)
    guard descriptionStatus == noErr, let description else {
      throw DeviceError.message("Cannot describe decoded frame")
    }
    let outputStatus = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: image, formatDescription: description, sampleTiming: &timing,
      sampleBufferOut: &output)
    guard outputStatus == noErr, let output else {
      throw DeviceError.message("Cannot prepare decoded frame")
    }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(output, createIfNecessary: true) {
      let dictionary = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return output
  }
}
private final class DecodedPicture: @unchecked Sendable {
  var status: OSStatus = noErr
  var image: CVImageBuffer?
}
