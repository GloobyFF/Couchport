import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 / HEVC decoder for the Remote Play stream.
///
/// The console sends one Annex-B access unit per callback (start-code
/// delimited NAL units, parameter sets in front of every IDR). We pull the
/// parameter sets out to build a `CMVideoFormatDescription`, repackage the
/// remaining NAL units as 4-byte length-prefixed (AVCC/HVCC) samples, and
/// decode synchronously on the caller's thread for the lowest latency.
/// Output is NV12 video-range, IOSurface + Metal compatible, so it goes
/// straight into `MetalVideoRenderer` like a capture-card frame.
final class StreamVideoDecoder {
    enum Codec { case h264, hevc }

    /// Called on the decoding thread with each decoded frame.
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let codec: Codec
    /// HDR streams (HEVC Main10) decode to 10-bit 4:2:0 so no precision is
    /// lost before the PQ tone mapping in the shader.
    private let tenBit: Bool
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private(set) var dimensions = CMVideoDimensions(width: 0, height: 0)
    private var frameIndex: Int64 = 0

    init(codec: Codec, tenBit: Bool = false) {
        self.codec = codec
        self.tenBit = tenBit && codec == .hevc
    }

    deinit { invalidate() }

    func invalidate() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        parameterSets = []
    }

    /// Returns false when the frame could not be decoded (asks for a keyframe).
    func decode(accessUnit: UnsafeBufferPointer<UInt8>) -> Bool {
        let nalUnits = Self.splitAnnexB(accessUnit)
        guard !nalUnits.isEmpty else { return true }

        var newParams: [Data] = []
        var payload = Data()
        payload.reserveCapacity(accessUnit.count + nalUnits.count * 4)

        for nal in nalUnits {
            guard let first = nal.first else { continue }
            switch classify(first) {
            case .parameterSet:
                newParams.append(Data(nal))
            case .skip:
                continue
            case .slice:
                var length = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
                payload.append(contentsOf: nal)
            }
        }

        if !newParams.isEmpty && newParams != parameterSets {
            parameterSets = newParams
            guard rebuildSession() else { return false }
        }
        guard let session, let formatDescription, !payload.isEmpty else {
            // Waiting for the first keyframe's parameter sets.
            return session != nil || payload.isEmpty
        }
        guard let sample = makeSampleBuffer(payload, format: formatDescription) else { return false }

        var ok = true
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample,
            flags: [._1xRealTimePlayback],
            infoFlagsOut: &infoFlags
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else {
                ok = false
                return
            }
            self?.onFrame?(imageBuffer)
        }
        if status == kVTInvalidSessionErr {
            // Happens after the app was backgrounded; rebuild on next IDR.
            invalidate()
            return false
        }
        return status == noErr && ok
    }

    // MARK: - NAL handling

    private enum NALKind { case parameterSet, slice, skip }

    private func classify(_ header: UInt8) -> NALKind {
        switch codec {
        case .h264:
            switch header & 0x1F {
            case 7, 8: return .parameterSet     // SPS, PPS
            case 9: return .skip                // AUD
            default: return .slice              // slices + SEI
            }
        case .hevc:
            switch (header >> 1) & 0x3F {
            case 32, 33, 34: return .parameterSet   // VPS, SPS, PPS
            case 35: return .skip                   // AUD
            default: return .slice
            }
        }
    }

    /// Splits on 00 00 01 / 00 00 00 01 start codes.
    static func splitAnnexB(_ buf: UnsafeBufferPointer<UInt8>) -> [UnsafeBufferPointer<UInt8>] {
        var units: [UnsafeBufferPointer<UInt8>] = []
        let n = buf.count
        guard n > 3, let base = buf.baseAddress else { return units }
        var i = 0
        var start = -1
        while i + 2 < n {
            if base[i] == 0, base[i + 1] == 0, base[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start, base[end - 1] == 0 { end -= 1 }   // 4-byte code
                    if end > start { units.append(UnsafeBufferPointer(start: base + start, count: end - start)) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < n {
            units.append(UnsafeBufferPointer(start: base + start, count: n - start))
        }
        return units
    }

    // MARK: - VideoToolbox

    private func rebuildSession() -> Bool {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        formatDescription = nil

        var desc: CMFormatDescription?
        let status: OSStatus = withPointers(parameterSets) { pointers, sizes in
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
            }
        }
        guard status == noErr, let desc else { return false }
        dimensions = CMVideoFormatDescriptionGetDimensions(desc)

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: tenBit
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var newSession: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession)
        guard created == noErr, let newSession else { return false }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
        formatDescription = desc
        return true
    }

    private func makeSampleBuffer(_ payload: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let length = payload.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = payload.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }

        frameIndex += 1
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: frameIndex, timescale: 60),
                                        decodeTimeStamp: .invalid)
        var sampleSize = length
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample) == noErr else { return nil }

        if let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            // Display immediately; never hold frames for reordering.
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    private func withPointers<R>(_ sets: [Data],
                                 _ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        // Copy into stable buffers for the duration of the call.
        let buffers: [UnsafeMutablePointer<UInt8>] = sets.map { data in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(data.count, 1))
            data.copyBytes(to: p, count: data.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        return body(buffers.map { UnsafePointer($0) }, sets.map(\.count))
    }
}
