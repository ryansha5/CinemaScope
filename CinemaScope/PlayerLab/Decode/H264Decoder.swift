// MARK: - PlayerLab / Decode / H264Decoder
//
// Minimal VideoToolbox H.264 decompression session.
// Sprint 9 goal: prove that extracted H.264 packets produce decoded frame callbacks.
//
// NOT integrated with production playback. Lab / diagnostic use only.
//
// Thread safety:
//   configure() and decode() must be called from the same thread (or actor).
//   VTDecompressionSession calls outputHandler on an arbitrary internal queue.
//   decodedFrameCount / decodeErrors are protected by a lock so the harness
//   can safely read them from the main thread after waitForAll() returns.

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

// MARK: - Errors

enum H264DecoderError: Error, LocalizedError {
    case invalidAvcC(String)
    case noSPSFound
    case noPPSFound
    case formatDescriptionFailed(OSStatus)
    case sessionCreateFailed(OSStatus)
    case blockBufferAllocFailed
    case blockBufferFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
    case notConfigured
    case decodeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidAvcC(let reason):        return "Invalid avcC: \(reason)"
        case .noSPSFound:                     return "avcC contains no SPS NAL units"
        case .noPPSFound:                     return "avcC contains no PPS NAL units"
        case .formatDescriptionFailed(let s): return "CMVideoFormatDescriptionCreateFromH264ParameterSets failed: \(s)"
        case .sessionCreateFailed(let s):     return "VTDecompressionSessionCreate failed: \(s)"
        case .blockBufferAllocFailed:         return "malloc() returned nil for block buffer"
        case .blockBufferFailed(let s):       return "CMBlockBufferCreateWithMemoryBlock failed: \(s)"
        case .sampleBufferFailed(let s):      return "CMSampleBufferCreateReady failed: \(s)"
        case .notConfigured:                  return "Call configure(avcCData:) before decode()"
        case .decodeFailed(let s):            return "VTDecompressionSessionDecodeFrame failed: \(s)"
        }
    }
}

// MARK: - H264Decoder

final class H264Decoder {

    // MARK: - Observable state (lock-protected)

    private(set) var decodedFrameCount: Int    = 0
    private(set) var decodeErrors:      Int    = 0
    private(set) var lastFrameSize:     CGSize = .zero

    /// Called on an arbitrary VT queue for each successfully decoded frame.
    /// Capture a copy of the pixel buffer if you need it beyond the callback.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    // MARK: - Private

    private var session:           VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?

    /// Size of NAL unit length field in sample data (from avcC, usually 4).
    private var nalUnitLength: Int = 4

    private let lock = NSLock()

    // MARK: - Format Description Factory (Sprint 10)
    //
    // Shared by the Sprint-9 VTDecompressionSession path (configure()) AND the
    // Sprint-10 AVSampleBufferDisplayLayer path (PlayerLabPlaybackController).

    /// Parse a raw avcC box payload and return a CMVideoFormatDescription.
    /// Does NOT create a VTDecompressionSession — use configure() for that.
    static func makeFormatDescription(from avcCData: Data) throws -> CMVideoFormatDescription {
        guard avcCData.count >= 7 else {
            throw H264DecoderError.invalidAvcC("payload too short (\(avcCData.count) bytes)")
        }

        var idx = 0
        guard avcCData[idx] == 1 else {
            throw H264DecoderError.invalidAvcC("configurationVersion is \(avcCData[0]), expected 1")
        }
        idx += 1    // configurationVersion
        idx += 3    // AVCProfileIndication, profile_compatibility, AVCLevelIndication

        let nalUnitLength = Int(avcCData[idx] & 0x03) + 1
        idx += 1

        // SPS
        var spsSet: [Data] = []
        let numSPS = Int(avcCData[idx] & 0x1F); idx += 1
        for _ in 0..<numSPS {
            guard idx + 2 <= avcCData.count else {
                throw H264DecoderError.invalidAvcC("SPS length field truncated")
            }
            let len = Int(avcCData[idx]) << 8 | Int(avcCData[idx + 1]); idx += 2
            guard idx + len <= avcCData.count else {
                throw H264DecoderError.invalidAvcC("SPS data truncated")
            }
            spsSet.append(avcCData.subdata(in: idx..<(idx + len))); idx += len
        }
        guard !spsSet.isEmpty else { throw H264DecoderError.noSPSFound }

        // PPS
        var ppsSet: [Data] = []
        guard idx < avcCData.count else {
            throw H264DecoderError.invalidAvcC("PPS count missing")
        }
        let numPPS = Int(avcCData[idx]); idx += 1
        for _ in 0..<numPPS {
            guard idx + 2 <= avcCData.count else {
                throw H264DecoderError.invalidAvcC("PPS length field truncated")
            }
            let len = Int(avcCData[idx]) << 8 | Int(avcCData[idx + 1]); idx += 2
            guard idx + len <= avcCData.count else {
                throw H264DecoderError.invalidAvcC("PPS data truncated")
            }
            ppsSet.append(avcCData.subdata(in: idx..<(idx + len))); idx += len
        }
        guard !ppsSet.isEmpty else { throw H264DecoderError.noPPSFound }

        let allSets   = spsSet + ppsSet
        let nsDataArr = allSets.map { $0 as NSData }
        var ptrs      = nsDataArr.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        var sizes     = nsDataArr.map { $0.length }

        var fmtDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator:             kCFAllocatorDefault,
            parameterSetCount:     allSets.count,
            parameterSetPointers:  &ptrs,
            parameterSetSizes:     &sizes,
            nalUnitHeaderLength:   Int32(nalUnitLength),
            formatDescriptionOut:  &fmtDesc
        )
        guard status == noErr, let fmtDesc = fmtDesc else {
            throw H264DecoderError.formatDescriptionFailed(status)
        }
        return fmtDesc
    }

    // MARK: - Configure

    /// Parse the raw avcC box payload and create a VTDecompressionSession.
    ///
    /// avcC layout:
    ///   [0]    configurationVersion (must be 1)
    ///   [1]    AVCProfileIndication
    ///   [2]    profile_compatibility
    ///   [3]    AVCLevelIndication
    ///   [4]    0b111111xx | lengthSizeMinusOne  (NAL length field width − 1)
    ///   [5]    0b111xxxxx | numSPS
    ///   [6-7]  SPS length (big-endian)
    ///   [...] SPS bytes
    ///   [n]    numPPS
    ///   [n+1-2] PPS length
    ///   [...] PPS bytes

    func configure(avcCData: Data) throws {
        guard avcCData.count >= 7 else {
            throw H264DecoderError.invalidAvcC("payload too short (\(avcCData.count) bytes)")
        }

        var idx = 0

        guard avcCData[idx] == 1 else {
            throw H264DecoderError.invalidAvcC("configurationVersion is \(avcCData[0]), expected 1")
        }
        idx += 1                    // skip configurationVersion

        idx += 3                    // skip profile, compat, level

        nalUnitLength = Int(avcCData[idx] & 0x03) + 1
        idx += 1

        // SPS
        var spsSet: [Data] = []
        let numSPS = Int(avcCData[idx] & 0x1F);   idx += 1
        for _ in 0..<numSPS {
            guard idx + 2 <= avcCData.count else {
                throw H264DecoderError.invalidAvcC("SPS length field truncated")
            }
            let len = Int(avcCData[idx]) << 8 | Int(avcCData[idx + 1]);   idx += 2
            guard idx + len <= avcCData.count else {
                throw H264DecoderError.invalidAvcC("SPS data truncated")
            }
            spsSet.append(avcCData.subdata(in: idx..<(idx + len)));   idx += len
        }
        guard !spsSet.isEmpty else { throw H264DecoderError.noSPSFound }

        // PPS
        var ppsSet: [Data] = []
        guard idx < avcCData.count else {
            throw H264DecoderError.invalidAvcC("PPS count missing")
        }
        let numPPS = Int(avcCData[idx]);   idx += 1
        for _ in 0..<numPPS {
            guard idx + 2 <= avcCData.count else {
                throw H264DecoderError.invalidAvcC("PPS length field truncated")
            }
            let len = Int(avcCData[idx]) << 8 | Int(avcCData[idx + 1]);   idx += 2
            guard idx + len <= avcCData.count else {
                throw H264DecoderError.invalidAvcC("PPS data truncated")
            }
            ppsSet.append(avcCData.subdata(in: idx..<(idx + len)));   idx += len
        }
        guard !ppsSet.isEmpty else { throw H264DecoderError.noPPSFound }

        // CMVideoFormatDescription from SPS + PPS
        // NSData keeps the bytes pinned for the duration of the call.
        let allSets   = spsSet + ppsSet
        let nsDataArr = allSets.map { $0 as NSData }
        var ptrs      = nsDataArr.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        var sizes     = nsDataArr.map { $0.length }

        var fmtDesc: CMVideoFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator:             kCFAllocatorDefault,
            parameterSetCount:     allSets.count,
            parameterSetPointers:  &ptrs,
            parameterSetSizes:     &sizes,
            nalUnitHeaderLength:   Int32(nalUnitLength),
            formatDescriptionOut:  &fmtDesc
        )
        guard fmtStatus == noErr, let fmtDesc = fmtDesc else {
            throw H264DecoderError.formatDescriptionFailed(fmtStatus)
        }
        formatDescription = fmtDesc

        // VTDecompressionSession
        // Passing outputCallback: nil → must use the outputHandler closure API.
        let pixelAttrs: [NSString: Any] = [
            kCVPixelBufferPixelFormatTypeKey:    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var vtSession: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator:               kCFAllocatorDefault,
            formatDescription:       fmtDesc,
            decoderSpecification:    nil,
            imageBufferAttributes:   pixelAttrs as CFDictionary,
            outputCallback:          nil,
            decompressionSessionOut: &vtSession
        )
        guard sessionStatus == noErr, let vtSession = vtSession else {
            throw H264DecoderError.sessionCreateFailed(sessionStatus)
        }
        session = vtSession
    }

    // MARK: - Decode

    /// Submit one AVCC-format H.264 packet to VideoToolbox.
    ///
    /// Memory: packet data is copied into a malloc buffer that VT frees when
    /// it releases the CMBlockBuffer, so there is no lifetime dependency on
    /// the DemuxPacket's Data after this call returns.
    func decode(packet: DemuxPacket) throws {
        guard let session = session, let formatDescription = formatDescription else {
            throw H264DecoderError.notConfigured
        }

        let dataLen = packet.data.count

        // Allocate a malloc buffer and copy the packet data into it.
        // VT will call free() on this pointer when it releases the CMBlockBuffer
        // (because we pass kCFAllocatorMalloc as blockAllocator).
        guard let mallocPtr = malloc(dataLen) else {
            throw H264DecoderError.blockBufferAllocFailed
        }
        packet.data.withUnsafeBytes { src in
            memcpy(mallocPtr, src.baseAddress!, dataLen)
        }

        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator:         kCFAllocatorDefault,
            memoryBlock:       mallocPtr,
            blockLength:       dataLen,
            blockAllocator:    kCFAllocatorMalloc,  // VT owns and frees mallocPtr
            customBlockSource: nil,
            offsetToData:      0,
            dataLength:        dataLen,
            flags:             0,
            blockBufferOut:    &blockBuffer
        )
        guard bbStatus == noErr, let blockBuffer = blockBuffer else {
            free(mallocPtr)
            throw H264DecoderError.blockBufferFailed(bbStatus)
        }

        // CMSampleBuffer
        var timing = CMSampleTimingInfo(
            duration:               CMTime.invalid,
            presentationTimeStamp:  packet.pts,
            decodeTimeStamp:        packet.dts
        )
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataLen
        let sbStatus = CMSampleBufferCreateReady(
            allocator:              kCFAllocatorDefault,
            dataBuffer:             blockBuffer,
            formatDescription:      formatDescription,
            sampleCount:            1,
            sampleTimingEntryCount: 1,
            sampleTimingArray:      &timing,
            sampleSizeEntryCount:   1,
            sampleSizeArray:        &sampleSize,
            sampleBufferOut:        &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer = sampleBuffer else {
            throw H264DecoderError.sampleBufferFailed(sbStatus)
        }

        // Decode — using the outputHandler closure variant (requires outputCallback: nil at session creation)
        let decStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags:         [],           // synchronous-preferred; VT may still be async
            infoFlagsOut:  nil,
            outputHandler: { [weak self] status, _, imageBuffer, pts, _ in
                guard let self = self else { return }
                if status == noErr, let imageBuffer = imageBuffer {
                    let w = CVPixelBufferGetWidth(imageBuffer)
                    let h = CVPixelBufferGetHeight(imageBuffer)
                    self.lock.lock()
                    self.decodedFrameCount += 1
                    self.lastFrameSize      = CGSize(width: w, height: h)
                    self.lock.unlock()
                    self.onFrame?(imageBuffer, pts)
                } else if status != noErr {
                    self.lock.lock()
                    self.decodeErrors += 1
                    self.lock.unlock()
                }
            }
        )
        if decStatus != noErr {
            throw H264DecoderError.decodeFailed(decStatus)
        }
    }

    // MARK: - Flush

    /// Block until all in-flight VT decode operations have fired their callbacks.
    /// Call this after submitting a batch of packets before reading decodedFrameCount.
    func waitForAll() {
        guard let session = session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }

    // MARK: - Teardown

    func invalidate() {
        if let session = session {
            VTDecompressionSessionInvalidate(session)
        }
        session           = nil
        formatDescription = nil
    }

    deinit { invalidate() }
}
