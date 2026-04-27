// MARK: - PlayerLab / Core / PacketFeeder
// Spring Cleaning SC7 — Fetch/enqueue pipeline extracted from
// PlayerLabPlaybackController.
//
// Owns:
//   • Streaming cursors  (nextVideoSampleIdx / nextAudioSampleIdx)
//   • Buffer tail PTS    (lastEnqueuedVideoPTS / lastEnqueuedAudioPTS)
//   • Sample-count totals (videoSamplesTotal / audioSamplesTotal)
//   • All packet-fetch logic  (demuxer read → CMSampleBuffer construction)
//   • All enqueue logic       (CMSampleBuffer → renderer)
//   • FetchResult value type  (pre-fetched buffers for zero-freeze seek)
//
// Sprint 44 — NAL unit format normalization
//   The Matroska spec (ISO 14496-15) requires HEVC blocks to be stored in
//   length-prefixed format (big-endian nalUnitLength-byte size before each NAL
//   unit).  Some encoders deviate and write Annex B (start-code delimited).
//   makeVideoSampleBuffer detects the format via full LP validation — walking
//   the entire buffer and verifying that all length fields account for exactly
//   the total byte count.  Only if that test passes is the data treated as LP.
//   If validation fails (Annex B, or malformed LP) the block is converted to
//   length-prefixed format before being handed to VideoToolbox.
//
// NOT production-ready. Debug / lab use only.

import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia
import VideoToolbox

// MARK: - Stderr (unbuffered, survives VT crash before stdout flushes)

private func feederLog(_ msg: String) {
    guard let d = (msg + "\n").data(using: .utf8) else { return }
    FileHandle.standardError.write(d)
}

// MARK: - PlayerLabRenderError

enum PlayerLabRenderError: Error, LocalizedError {
    case blockBufferAllocFailed
    case blockBufferFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
    /// Thrown when the sample payload is 0 bytes after all processing steps
    /// (e.g. DV stripping removed every NAL unit from a frame that contained
    /// ONLY type 62/63 NALs and the unstripped fallback was also empty).
    case emptyPayload

    var errorDescription: String? {
        switch self {
        case .blockBufferAllocFailed:    return "malloc() returned nil for block buffer"
        case .blockBufferFailed(let s):  return "CMBlockBufferCreateWithMemoryBlock: \(s)"
        case .sampleBufferFailed(let s): return "CMSampleBufferCreateReady: \(s)"
        case .emptyPayload:              return "CMSampleBuffer: sample payload is 0 bytes after processing"
        }
    }
}

// MARK: - PacketFeeder

@MainActor
final class PacketFeeder {

    // MARK: - FetchResult
    //
    // Plain value type holding pre-built CMSampleBuffers ready for enqueue.
    // Produced by fetchPackets(), consumed by enqueueAndAdvance().
    // Splitting fetch and enqueue lets seek() do IO before flushing the
    // renderer, collapsing the display gap to µs (Sprint 18.5).

    struct FetchResult {
        /// Video sample buffers paired with their PTS (seconds) for tail tracking.
        var videoBuffers: [(buffer: CMSampleBuffer, pts: Double)] = []
        /// Audio sample buffers in presentation order.
        var audioBuffers: [CMSampleBuffer] = []
        /// PTS of the last video sample in this result.
        var lastVideoPTS: Double = 0
        /// PTS of the last audio sample in this result.
        var lastAudioPTS: Double = 0
        /// Label forwarded to enqueueAndAdvance for consistent log output.
        let label: String
    }

    // MARK: - Cursor + tail state
    //
    // Read-only outside PacketFeeder. The controller reads these to:
    //   • compute buffer depth (lastEnqueuedVideoPTS − currentTime)
    //   • drive feed-loop EOS detection (nextVideoSampleIdx >= videoSamplesTotal)
    //   • update framesLoaded after enqueue

    private(set) var nextVideoSampleIdx:   Int    = 0
    private(set) var nextAudioSampleIdx:   Int    = 0
    private(set) var lastEnqueuedVideoPTS: Double = 0
    private(set) var lastEnqueuedAudioPTS: Double = 0

    // MARK: - Totals + per-file config
    //
    // Set by the controller during prepare(), cleared by reset().

    var videoSamplesTotal: Int    = 0
    var audioSamplesTotal: Int    = 0
    var duration:          Double = 0
    var hasAudio:          Bool   = false

    // MARK: - Demuxer references
    //
    // Exactly one will be non-nil after a successful prepare().
    // Cleared by reset() when the controller stops or re-prepares.

    var mkvDemuxer: MKVDemuxer? = nil
    var mp4Demuxer: MP4Demuxer? = nil

    // MARK: - Format descriptions
    //
    // Set by the controller after building them in prepare().
    // Cleared by reset().

    var videoFormatDesc: CMVideoFormatDescription? = nil
    var audioFormatDesc: CMAudioFormatDescription? = nil

    // MARK: - Renderer (injected at init; fixed for feeder lifetime)

    private let renderer: FrameRenderer

    // MARK: - Sample diagnostics counter (Sprint 44)

    /// Number of video samples already diagnosed. Diagnostics run for the first
    /// kDiagnosticSampleCount samples, then stop to avoid log flooding.
    private var videoSamplesDiagnosed: Int = 0
    private static let kDiagnosticSampleCount = 20

    // MARK: - Sprint 46: DV stripping toggle

    /// Set to false to disable Dolby Vision NAL stripping entirely.
    /// Use for diagnosing whether the strip path breaks sample delivery or
    /// decoder initialisation.  When false, all NAL types (including 62/63)
    /// are passed to VideoToolbox unchanged.
    /// Default: true (strip DV NALs before handing to VT).
    static var stripDolbyVisionNALsEnabled: Bool = true

    // MARK: - Init

    init(renderer: FrameRenderer) {
        self.renderer = renderer
    }

    // MARK: - Reset

    /// Clear all per-file state. Called at the start of prepare() and from stop().
    func reset() {
        nextVideoSampleIdx    = 0
        nextAudioSampleIdx    = 0
        lastEnqueuedVideoPTS  = 0
        lastEnqueuedAudioPTS  = 0
        videoSamplesTotal     = 0
        audioSamplesTotal     = 0
        duration              = 0
        hasAudio              = false
        videoFormatDesc       = nil
        audioFormatDesc       = nil
        mkvDemuxer            = nil
        mp4Demuxer            = nil
        videoSamplesDiagnosed = 0
    }

    // MARK: - Cursor teleport (seek)

    /// Atomically reset all cursor and tail state to a new seek position.
    /// Called by the controller between the flush and enqueue phases of seek().
    func setCursors(videoIdx: Int, audioIdx: Int, videoPTS: Double, audioPTS: Double) {
        nextVideoSampleIdx   = videoIdx
        nextAudioSampleIdx   = audioIdx
        lastEnqueuedVideoPTS = videoPTS
        lastEnqueuedAudioPTS = audioPTS
    }

    // MARK: - Sample-count helpers

    /// Number of video samples spanning approximately `seconds` of media.
    func videoSamplesFor(seconds: Double) -> Int {
        guard duration > 0, videoSamplesTotal > 0 else { return 150 }
        let fps = Double(videoSamplesTotal) / duration
        return max(1, Int(seconds * fps))
    }

    /// Number of audio samples spanning approximately `seconds` of media.
    func audioSamplesFor(seconds: Double) -> Int {
        guard duration > 0, audioSamplesTotal > 0 else { return 200 }
        let aps = Double(audioSamplesTotal) / duration
        return max(1, Int(seconds * aps))
    }

    // MARK: - fetchPackets  (Phase 1 — pure IO, no side effects)
    //
    // Reads packets from the active demuxer, constructs CMSampleBuffers into
    // memory, and returns them as a FetchResult.
    // Has NO side effects on cursors, renderer, or published state.
    // Safe to call before flushing the renderer (Sprint 18.5 zero-freeze seek).

    func fetchPackets(
        videoCount:   Int,
        audioSeconds: Double,
        fromVideoIdx: Int,
        fromAudioIdx: Int,
        label:        String,
        log:          (String) -> Void
    ) async -> FetchResult {

        var result = FetchResult(label: label)
        guard let vFmt = videoFormatDesc else { return result }

        let limitedVideo = min(videoCount, videoSamplesTotal - fromVideoIdx)
        guard limitedVideo > 0 else { return result }

        // ── Video ─────────────────────────────────────────────────────────────

        do {
            let packets: [DemuxPacket]
            if let mkv = mkvDemuxer {
                packets = try await mkv.extractVideoPackets(from: fromVideoIdx, count: limitedVideo)
            } else if let mp4 = mp4Demuxer {
                packets = try await mp4.extractVideoPackets(from: fromVideoIdx, count: limitedVideo)
            } else {
                return result
            }
            for pkt in packets {
                // Sprint 46: replace try? with explicit catch so buffer-construction
                // failures are visible (try? was silently discarding them, causing
                // SampleDiag to fire while enqueueAndAdvance received 0 buffers).
                do {
                    let sb = try makeVideoSampleBuffer(packet: pkt, formatDescription: vFmt)
                    result.videoBuffers.append((sb, pkt.pts.seconds))
                    result.lastVideoPTS = max(result.lastVideoPTS, pkt.pts.seconds)
                } catch {
                    feederLog("  ⚠️ [\(label)] makeVideoSampleBuffer failed  "
                            + "pkt.index=\(pkt.index)  pts=\(String(format: "%.3f", pkt.pts.seconds))s  "
                            + "size=\(pkt.data.count)B  keyframe=\(pkt.isKeyframe)  "
                            + "error=\(error.localizedDescription)")
                }
            }
        } catch {
            log("  ⚠️ [\(label)] video fetch failed: \(error.localizedDescription)")
        }

        // ── Audio ─────────────────────────────────────────────────────────────

        if hasAudio, let aFmt = audioFormatDesc {
            let limitedAudio = min(audioSamplesFor(seconds: audioSeconds),
                                   audioSamplesTotal - fromAudioIdx)
            if limitedAudio > 0 {
                do {
                    let packets: [DemuxPacket]
                    if let mkv = mkvDemuxer {
                        packets = try await mkv.extractAudioPackets(from: fromAudioIdx,
                                                                     count: limitedAudio)
                    } else if let mp4 = mp4Demuxer {
                        packets = try await mp4.extractAudioPackets(count: limitedAudio,
                                                                     from: fromAudioIdx)
                    } else {
                        packets = []
                    }
                    for pkt in packets {
                        if let sb = try? makeAudioSampleBuffer(packet: pkt, formatDescription: aFmt) {
                            result.audioBuffers.append(sb)
                            result.lastAudioPTS = max(result.lastAudioPTS, pkt.pts.seconds)
                        }
                    }
                } catch {
                    log("  ⚠️ [\(label)] audio fetch failed: \(error.localizedDescription)")
                }
            }
        }

        return result
    }

    // MARK: - enqueueAndAdvance  (Phase 2 — synchronous enqueue + cursor update)
    //
    // Pushes pre-built CMSampleBuffers to the renderer and advances the cursors.
    // No IO. Safe to call immediately after flushing the renderer.
    // Returns the count of video packets enqueued (used by the controller to
    // guard against empty initial windows and to update framesLoaded).

    @discardableResult
    func enqueueAndAdvance(_ result: FetchResult, log: (String) -> Void) -> Int {
        let vCount = result.videoBuffers.count
        let aCount = result.audioBuffers.count

        // Sprint 46: log the call regardless of vCount so we can distinguish
        // "enqueueAndAdvance never called" from "called but 0 buffers built."
        feederLog("[enqueue] [\(result.label)] called  videoBuffers=\(vCount)  audioBuffers=\(aCount)")
        if vCount == 0 {
            feederLog("[enqueue] [\(result.label)] ⚠️ zero video buffers — "
                    + "makeVideoSampleBuffer failed for all packets in this batch; "
                    + "check ⚠️ makeVideoSampleBuffer lines above for the cause")
            log("  [\(result.label)] ⚠️ enqueueAndAdvance: 0 video buffers built — "
              + "no frames enqueued this cycle")
        }

        if vCount > 0 {
            let vStart = nextVideoSampleIdx
            feederLog("[enqueue] [\(result.label)] video cursor=\(vStart)  "
                    + "enqueueing \(vCount) buffers  tail=\(String(format: "%.3f", result.lastVideoPTS))s")
            for (i, (sb, _)) in result.videoBuffers.enumerated() {
                let absIdx = vStart + i
                if absIdx == 0 {
                    // Sprint 46: explicit confirmation that enqueueVideo is about
                    // to be called for the very first sample.
                    feederLog("[enqueue] → renderer.enqueueVideo called for sample 0")
                }
                renderer.enqueueVideo(sb, sampleIndex: absIdx)
            }
            lastEnqueuedVideoPTS = max(lastEnqueuedVideoPTS, result.lastVideoPTS)
            nextVideoSampleIdx  += vCount
            log("  [\(result.label)] video [\(vStart)…\(nextVideoSampleIdx - 1)]  "
              + "\(vCount) pkts  tail=\(String(format: "%.2f", lastEnqueuedVideoPTS))s")
        }

        if aCount > 0 {
            let aStart = nextAudioSampleIdx
            for sb in result.audioBuffers { renderer.enqueueAudio(sb) }
            lastEnqueuedAudioPTS = max(lastEnqueuedAudioPTS, result.lastAudioPTS)
            nextAudioSampleIdx  += aCount
            log("  [\(result.label)] audio [\(aStart)…\(nextAudioSampleIdx - 1)]  "
              + "\(aCount) pkts  tail=\(String(format: "%.2f", lastEnqueuedAudioPTS))s")
        }

        return vCount
    }

    // MARK: - feedWindow  (convenience: fetch + enqueue from current cursor positions)
    //
    // Used by prepare() (initial window) and the feed loop (normal/buffering refills).
    // seek() calls fetchPackets + enqueueAndAdvance directly so it can flush the
    // renderer between the two phases (Sprint 18.5 zero-freeze seek).

    @discardableResult
    func feedWindow(
        videoCount:   Int,
        audioSeconds: Double,
        label:        String,
        log:          (String) -> Void
    ) async -> Int {
        let result = await fetchPackets(videoCount:   videoCount,
                                        audioSeconds:  audioSeconds,
                                        fromVideoIdx:  nextVideoSampleIdx,
                                        fromAudioIdx:  nextAudioSampleIdx,
                                        label:         label,
                                        log:           log)
        return enqueueAndAdvance(result, log: log)
    }

    // MARK: - CMSampleBuffer construction — Video

    private func makeVideoSampleBuffer(
        packet:            DemuxPacket,
        formatDescription: CMVideoFormatDescription
    ) throws -> CMSampleBuffer {

        // ── Sprint 44: Annex B detection + conversion ─────────────────────────
        //
        // MKV stores HEVC NAL units in Annex B bytestream format (start-code
        // delimited: 00 00 01 or 00 00 00 01 before each NAL unit).  VideoToolbox
        // requires length-prefixed format (big-endian nalUnitLength bytes before
        // each NAL unit), matching the format description built from hvcC.
        //
        // This conversion must happen for every sample, not just keyframes.
        // Passing Annex B bytes to VT causes it to read start-code bytes as a
        // length field (typically 00 00 00 01 = length 1), producing completely
        // wrong NAL unit boundaries and corrupted output.
        //
        // nalUnitLength is extracted from the format description (usually 4).

        let nalUnitLength = PacketFeeder.hevcNalUnitLength(from: formatDescription)
        let rawBytes      = Array(packet.data)   // flatten to 0-based [UInt8]

        // detectNALFormat now does full LP validation, not just a 4-byte prefix
        // check. If the buffer isn't a well-formed LP stream it falls back to
        // Annex B conversion, which is the correct path for MKV HEVC content.
        let fmt = PacketFeeder.detectNALFormat(rawBytes, nalUnitLength: nalUnitLength)
        let normalizedBytes: Data
        if fmt == .annexB {
            normalizedBytes = PacketFeeder.convertAnnexBToLengthPrefixed(rawBytes,
                                                                          nalUnitLength: nalUnitLength)
        } else {
            normalizedBytes = packet.data
        }

        // Strip Dolby Vision NAL types 62 (RPU) and 63 (EL wrapper) before
        // handing to VideoToolbox.  VT should ignore reserved NAL types, but
        // in practice type 62/63 can corrupt the HEVC decoder state.
        // Stripping them leaves: AUD, VPS/SPS/PPS, SEI, and video slices only.
        //
        // Sprint 46: stripDolbyVisionNALsEnabled toggle — set to false to
        // diagnose whether the strip path breaks sample delivery.
        //
        // Sprint 46 fix: guard against frames whose entire payload is DV NALs
        // (types 62/63 only).  Stripping them produces 0 bytes, which causes
        // CMBlockBufferCreateWithMemoryBlock to return -12704
        // (kCMBlockBufferBadLengthParameterErr).  When this happens we fall back
        // to the unstripped normalizedBytes so VideoToolbox can attempt to decode
        // (or gracefully skip) the frame rather than crashing the pipeline.
        let sampleBytes: Data
        if PacketFeeder.stripDolbyVisionNALsEnabled {
            let stripped = PacketFeeder.stripDolbyVisionNALs(normalizedBytes,
                                                              nalUnitLength: nalUnitLength)
            if stripped.isEmpty && !normalizedBytes.isEmpty {
                // All NALs were DV types — fall back to unstripped so we don't
                // pass blockLength=0 to CMBlockBufferCreateWithMemoryBlock.
                feederLog("[makeVideoSampleBuffer] ⚠️ DV strip emptied frame — using unstripped fallback  "
                        + "pkt=\(packet.index)  pts=\(String(format: "%.3f", packet.pts.seconds))s  "
                        + "original=\(normalizedBytes.count)B  keyframe=\(packet.isKeyframe)")
                sampleBytes = normalizedBytes
            } else {
                sampleBytes = stripped
            }
        } else {
            sampleBytes = normalizedBytes
        }

        // Final safety net: if sampleBytes is somehow still empty (shouldn't
        // happen with the fallback above, but guard defensively to prevent the
        // -12704 crash in any future code path).
        guard !sampleBytes.isEmpty else {
            feederLog("[makeVideoSampleBuffer] ❌ sampleBytes=0 after all processing — throwing emptyPayload  "
                    + "pkt=\(packet.index)  pts=\(String(format: "%.3f", packet.pts.seconds))s  "
                    + "normalizedBytes=\(normalizedBytes.count)B")
            throw PlayerLabRenderError.emptyPayload
        }

        // ── Diagnostics: log first kDiagnosticSampleCount video samples ───────
        if videoSamplesDiagnosed < PacketFeeder.kDiagnosticSampleCount {
            videoSamplesDiagnosed += 1
            PacketFeeder.logVideoSampleDiagnostic(
                raw:           rawBytes,
                normalized:    Array(normalizedBytes),   // pre-strip: shows full NAL list
                stripped:      Array(sampleBytes),       // post-strip: what VT receives
                packet:        packet,
                fmt:           fmt,
                nalUnitLength: nalUnitLength,
                diagIdx:       videoSamplesDiagnosed
            )
        }

        // ── CMBlockBuffer ─────────────────────────────────────────────────────
        let dataLen = sampleBytes.count
        guard let mallocPtr = malloc(dataLen) else {
            throw PlayerLabRenderError.blockBufferAllocFailed
        }
        sampleBytes.withUnsafeBytes { src in
            memcpy(mallocPtr, src.baseAddress!, dataLen)
        }
        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator:         kCFAllocatorDefault,
            memoryBlock:       mallocPtr,
            blockLength:       dataLen,
            blockAllocator:    kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData:      0,
            dataLength:        dataLen,
            flags:             0,
            blockBufferOut:    &blockBuffer
        )
        guard bbStatus == noErr, let blockBuffer = blockBuffer else {
            free(mallocPtr)
            throw PlayerLabRenderError.blockBufferFailed(bbStatus)
        }

        // ── CMSampleBuffer ────────────────────────────────────────────────────
        var timing = CMSampleTimingInfo(
            duration:              .invalid,
            presentationTimeStamp: packet.pts,
            decodeTimeStamp:       packet.dts   // .invalid for video (Sprint 30 B-frame fix)
        )
        var sampleSize  = dataLen
        var sampleBuffer: CMSampleBuffer?
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
            throw PlayerLabRenderError.sampleBufferFailed(sbStatus)
        }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           let dict = (arr as NSArray).firstObject as? NSMutableDictionary {
            dict[kCMSampleAttachmentKey_NotSync as NSString] =
                packet.isKeyframe ? kCFBooleanFalse : kCFBooleanTrue
        }

        // Sprint 46: confirm buffer was actually built (fires AFTER SampleDiag, so
        // its presence proves the full CMSampleBuffer construction path succeeded).
        if packet.index < 20 {
            feederLog("[CMSampleBuffer #\(packet.index)] ✅ built  "
                    + "dataLen=\(dataLen)B  "
                    + "pts=\(String(format: "%.3f", packet.pts.seconds))s  "
                    + "keyframe=\(packet.isKeyframe)  "
                    + "dvStrip=\(PacketFeeder.stripDolbyVisionNALsEnabled)")
        }

        return sampleBuffer
    }

    // MARK: - NAL format detection

    enum NALFormat { case annexB, lengthPrefixed }

    /// Validate that `b` is a well-formed length-prefixed NAL unit stream.
    ///
    /// Walks the entire buffer treating each prefix as a `nalUnitLength`-byte
    /// big-endian integer.  Returns true only if:
    ///   • At least one NAL unit is found
    ///   • Every length field produces a NAL that fits within the buffer
    ///   • All bytes in the buffer are accounted for exactly (no trailing
    ///     bytes, no overrun)
    ///
    /// This is far more reliable than checking only the first 4 bytes:
    ///   • Annex B streams where the first start code isn't 00 00 00 01
    ///     (e.g. a 3-byte 00 00 01 start code) would fool a prefix-only check.
    ///   • LP streams where the first length happens to be 00 00 00 01
    ///     (a 1-byte NAL) would also fool a prefix-only check.
    ///
    /// Only if this validation passes do we trust the LP interpretation.
    /// Otherwise we fall back to Annex B conversion.
    private static func isValidLengthPrefixed(_ b: [UInt8], nalUnitLength: Int) -> Bool {
        guard nalUnitLength >= 1, nalUnitLength <= 4, !b.isEmpty else { return false }
        var i = 0
        let n = b.count
        var nalCount = 0
        while i < n {
            // Need at least `nalUnitLength` bytes for the length field
            guard i + nalUnitLength <= n else { return false }
            var len = 0
            for k in 0..<nalUnitLength { len = (len << 8) | Int(b[i + k]) }
            guard len > 0 else { return false }        // zero-length NAL is invalid
            let naluEnd = i + nalUnitLength + len
            guard naluEnd <= n else { return false }   // NAL overruns buffer
            i = naluEnd
            nalCount += 1
        }
        // All bytes consumed exactly — no trailing garbage
        return nalCount > 0 && i == n
    }

    /// Determine whether `b` is Annex B (start-code delimited) or
    /// length-prefixed.
    ///
    /// Strategy:
    ///   1. Try full LP validation with the expected `nalUnitLength`.
    ///      If every length field accounts for exactly the total buffer size,
    ///      the data is length-prefixed.
    ///   2. Otherwise, treat as Annex B and convert.
    ///
    /// The old approach (check only bytes 0–3 for a start code) is kept as
    /// a fast pre-filter: if the buffer literally starts with 00 00 00 01 or
    /// 00 00 01 we know immediately it is Annex B without paying for the full
    /// scan (avoids wasting time validating obviously Annex B data).
    private static func detectNALFormat(_ b: [UInt8], nalUnitLength: Int) -> NALFormat {
        // Fast path: definite Annex B start codes at byte 0
        if b.count >= 4 && b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] == 1 { return .annexB }
        if b.count >= 3 && b[0] == 0 && b[1] == 0 && b[2] == 1                { return .annexB }
        // Slow path: full LP validation — only trust LP if every byte is
        // accounted for by valid length-prefixed NAL units.
        if isValidLengthPrefixed(b, nalUnitLength: nalUnitLength) { return .lengthPrefixed }
        // Validation failed → data is not valid LP; convert from Annex B.
        return .annexB
    }

    // MARK: - DV NAL stripping

    /// Strip Dolby Vision NAL units (type 62 = RPU, type 63 = EL wrappers)
    /// from a length-prefixed HEVC stream before handing it to VideoToolbox.
    ///
    /// Motivation: HEVC NAL types 48–63 are reserved by the spec; decoders are
    /// required to ignore them.  In practice, VideoToolbox may not handle type
    /// 62/63 gracefully — either silently corrupting decoder state or stalling
    /// on unknown SEI-like payloads.  Stripping them produces a clean HEVC-only
    /// stream: AUD, VPS, SPS, PPS, SEI, and video slices.
    ///
    /// Returns the input Data unchanged if no DV NALs are found (avoids an
    /// allocation on non-DV content).
    static func stripDolbyVisionNALs(_ data: Data, nalUnitLength: Int) -> Data {
        let b = Array(data)
        let n = b.count
        var i = 0
        var hadDV = false

        // First pass: check if there are any DV NALs at all (cheap early exit)
        var probe = 0
        while probe + nalUnitLength <= n {
            var len = 0
            for k in 0..<nalUnitLength { len = (len << 8) | Int(b[probe + k]) }
            guard len > 0 else { break }
            let naluStart = probe + nalUnitLength
            guard naluStart < n else { break }
            let nalType = Int((b[naluStart] >> 1) & 0x3F)
            if nalType == 62 || nalType == 63 { hadDV = true; break }
            probe = naluStart + len
        }
        guard hadDV else { return data }    // nothing to strip — return original

        // Second pass: rebuild without DV NALs
        var out = Data()
        out.reserveCapacity(n)
        while i + nalUnitLength <= n {
            var len = 0
            for k in 0..<nalUnitLength { len = (len << 8) | Int(b[i + k]) }
            guard len > 0 else { break }
            let naluStart = i + nalUnitLength
            guard naluStart + len <= n else { break }
            let nalType = Int((b[naluStart] >> 1) & 0x3F)
            if nalType != 62 && nalType != 63 {
                // Keep this NAL — copy length prefix + payload
                for k in 0..<nalUnitLength { out.append(b[i + k]) }
                out.append(contentsOf: b[naluStart..<(naluStart + len)])
            }
            i = naluStart + len
        }
        return out
    }

    // MARK: - Annex B → length-prefixed conversion

    /// Convert HEVC Annex B bytestream (start-code delimited) to the
    /// length-prefixed format required by VideoToolbox.
    ///
    /// Each NAL unit is prefixed with `nalUnitLength` big-endian bytes
    /// containing the NALU byte count (matching what hvcC's lengthSizeMinusOne
    /// describes).
    ///
    /// - Note: Trailing zero bytes between the end of a NALU payload and the
    ///   start of the next start code are included in the current NALU (they are
    ///   part of the RBSP if present). For real HEVC content this is safe.
    private static func convertAnnexBToLengthPrefixed(_ b: [UInt8], nalUnitLength: Int) -> Data {
        let n = b.count
        // Collect (naluStart, naluEnd) for each NALU — indices into b[]
        var naluRanges: [(Int, Int)] = []
        var i = 0
        var naluStart = -1

        while i < n {
            var scLen = 0
            if i + 3 < n && b[i] == 0 && b[i+1] == 0 && b[i+2] == 0 && b[i+3] == 1 {
                scLen = 4
            } else if i + 2 < n && b[i] == 0 && b[i+1] == 0 && b[i+2] == 1 {
                scLen = 3
            }

            if scLen > 0 {
                if naluStart >= 0 {
                    // Close the previous NALU at the start of this start code
                    naluRanges.append((naluStart, i))
                }
                naluStart = i + scLen
                i = naluStart
            } else {
                i += 1
            }
        }
        // Close the final NALU
        if naluStart >= 0 && naluStart < n {
            naluRanges.append((naluStart, n))
        }

        // Emit length-prefixed output
        var out = Data()
        out.reserveCapacity(n + naluRanges.count * nalUnitLength)
        for (start, end) in naluRanges {
            let len = end - start
            guard len > 0 else { continue }
            for shift in stride(from: (nalUnitLength - 1) * 8, through: 0, by: -8) {
                out.append(UInt8((len >> shift) & 0xFF))
            }
            out.append(contentsOf: b[start..<end])
        }
        return out
    }

    // MARK: - nalUnitLength extraction from CMVideoFormatDescription

    /// Extract the HEVC NAL unit header length from a CMVideoFormatDescription.
    /// Returns 4 if the query fails (covers virtually all real content).
    private static func hevcNalUnitLength(from desc: CMVideoFormatDescription) -> Int {
        var nal: Int32 = 4
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            desc,
            parameterSetIndex:      0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut:    nil,
            parameterSetCountOut:   nil,
            nalUnitHeaderLengthOut: &nal
        )
        return max(1, Int(nal))
    }

    // MARK: - NAL type parsing helpers

    /// Returns the HEVC NAL unit type name for a type number.
    private static func hevcNALTypeName(_ t: Int) -> String {
        switch t {
        case  0...9:   return "TRAIL_\(t)"
        case 16:       return "BLA_W_LP"
        case 17:       return "BLA_W_RADL"
        case 18:       return "BLA_N_LP"
        case 19:       return "IDR_W_RADL ✅"   // true IDR
        case 20:       return "IDR_N_LP ✅"      // true IDR
        case 21:       return "CRA_NUT"
        case 32:       return "VPS"
        case 33:       return "SPS"
        case 34:       return "PPS"
        case 35:       return "AUD"
        case 39:       return "PREFIX_SEI"
        case 40:       return "SUFFIX_SEI"
        default:       return "type\(t)"
        }
    }

    /// Parse NAL unit types from length-prefixed bytes.
    /// Returns array of (nalType, sizeBytes) pairs.
    /// `sizeBytes` is the NAL payload size (NOT including the length prefix field).
    private static func nalTypesFromLengthPrefixed(_ b: [UInt8], nalUnitLength: Int) -> [(type: Int, size: Int)] {
        var result: [(Int, Int)] = []
        var i = 0
        let n = b.count
        // Use <= (not <) so the final NAL whose length field starts at n-nalUnitLength is parsed.
        while i + nalUnitLength <= n {
            var len = 0
            for k in 0..<nalUnitLength { len = (len << 8) | Int(b[i + k]) }
            i += nalUnitLength
            guard len > 0, i + len <= n else { break }
            let nalType = Int((b[i] >> 1) & 0x3F)
            result.append((nalType, len))
            i += len
        }
        return result
    }

    // MARK: - Video sample diagnostic logger

    private static func logVideoSampleDiagnostic(
        raw:           [UInt8],
        normalized:    [UInt8],   // after LP normalisation, before DV strip
        stripped:      [UInt8],   // after DV NAL strip — what VT actually receives
        packet:        DemuxPacket,
        fmt:           NALFormat,
        nalUnitLength: Int,
        diagIdx:       Int
    ) {
        let tag = "[SampleDiag #\(diagIdx)]"

        // Basic info
        let dtsStr = packet.dts.isValid
            ? String(format: "%.3f", packet.dts.seconds) + "s"
            : "invalid"
        let dvStripped = normalized.count - stripped.count
        feederLog("\(tag) sample idx=\(packet.index)  "
                + "rawSize=\(raw.count)B  normalizedSize=\(normalized.count)B  "
                + "strippedSize=\(stripped.count)B  dvRemoved=\(dvStripped)B  "
                + "keyframe=\(packet.isKeyframe)  "
                + "pts=\(String(format: "%.3f", packet.pts.seconds))s  dts=\(dtsStr)  "
                + "format=\(fmt == .annexB ? "AnnexB→converted" : "lengthPrefixed")")

        // First 32 bytes of raw payload
        let raw32 = raw.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
        feederLog("\(tag) raw first32:  \(raw32)")

        // First 32 bytes after any conversion (always log — confirms length prefix looks sane)
        let norm32 = normalized.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
        feederLog("\(tag) norm first32: \(norm32)"
                + (fmt == .annexB ? "  (converted from AnnexB)" : "  (already length-prefixed)"))

        // LP validation result — tells us whether the format detection was
        // confident (valid LP) or fell back to Annex B conversion.
        let lpValid = isValidLengthPrefixed(normalized, nalUnitLength: nalUnitLength)
        feederLog("\(tag) lpValid=\(lpValid)  nalUnitLength=\(nalUnitLength)  "
                + "format=\(fmt == .annexB ? "AnnexB→converted" : "lengthPrefixed")")

        // Parse NAL types from the normalized (length-prefixed) data
        let nalList = nalTypesFromLengthPrefixed(normalized, nalUnitLength: nalUnitLength)
        feederLog("\(tag) NAL units found: \(nalList.count)")
        if nalList.isEmpty && normalized.count > nalUnitLength {
            // If the parse finds nothing in a non-empty buffer, the length field is probably
            // being misread — dump the raw 4-byte prefix so we can see what VT is getting
            let prefix8 = normalized.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            feederLog("\(tag) ⚠️  nalList empty — first8 of normalized: \(prefix8)  "
                    + "(if first 4 bytes look like a start code, Annex B detection missed)")
        }
        // Log each NAL: type, size, and first 8 bytes of NAL payload (after
        // the 2-byte HEVC NAL header) — this lets us see if VPS/SPS/PPS are
        // plausible and slice data isn't garbled at the boundary.
        var nalCursor = nalUnitLength   // skip first length prefix to get to byte 0 of first NAL
        for (i, (t, sz)) in nalList.enumerated() {
            let naluStart = nalCursor   // first byte of HEVC NAL header
            // Payload starts after 2-byte HEVC NAL header
            let payloadStart = naluStart + 2
            let payloadBytes = payloadStart < normalized.count
                ? normalized[payloadStart..<min(payloadStart + 8, normalized.count)]
                    .map { String(format: "%02X", $0) }.joined(separator: " ")
                : "—"
            feederLog("\(tag)   [\(i)] type=\(t) (\(hevcNALTypeName(t)))  size=\(sz)B  "
                    + "payload[0..7]: \(payloadBytes)")
            nalCursor += sz + nalUnitLength   // advance past this NAL + next length prefix
        }

        // IDR check
        let isIDR  = nalList.contains { $0.type == 19 || $0.type == 20 }
        let hasSPS = nalList.contains { $0.type == 33 }
        let hasVPS = nalList.contains { $0.type == 32 }
        let hasPPS = nalList.contains { $0.type == 34 }
        feederLog("\(tag) IDR=\(isIDR ? "✅" : "❌")  "
                + "VPS=\(hasVPS ? "✅" : "—")  SPS=\(hasSPS ? "✅" : "—")  PPS=\(hasPPS ? "✅" : "—")")

        if packet.isKeyframe && !isIDR {
            feederLog("\(tag) ⚠️  MKV marks this as keyframe but no IDR NAL found — "
                    + "CRA or non-IDR keyframe; VT may need prior state")
        }

        // Dolby Vision detection
        // Type 62 = Dolby Vision RPU (Reference Processing Unit) — tone-mapping metadata
        // Type 63 = Dolby Vision EL overlay or proprietary extension
        // Present in every frame of DV Profile 7 (dual-layer) and Profile 8 (single-layer) content.
        //
        // DV Profile 7 dual-layer MKV:
        //   • This track (BL) is intentionally low-bitrate (~100-300 kbps) — a "compatibility signal".
        //   • High quality lives in a separate EL track (typically track 2 in the MKV).
        //   • Standard HEVC decoders (VideoToolbox) can only render the BL → blocky output is expected.
        //   • Fix: find and decode the HDR10-compatible or non-DV video track, or use a DV-capable pipeline.
        //
        // DV Profile 8 single-layer MKV:
        //   • This track IS the full-quality picture (HDR10-compatible BL).
        //   • RPU (type 62) carries DV tone-mapping metadata — ignored by standard HEVC decoders.
        //   • Quality should be full; if blocky, the issue is elsewhere (SPS mismatch, 10-bit display).
        let hasDVRPU  = nalList.contains { $0.type == 62 }
        let hasDVExt  = nalList.contains { $0.type == 63 }
        let rpu62Size = nalList.filter { $0.type == 62 }.reduce(0) { $0 + $1.size }
        let ext63Size = nalList.filter { $0.type == 63 }.reduce(0) { $0 + $1.size }
        if hasDVRPU || hasDVExt {
            let dvOverheadPct = (rpu62Size + ext63Size) * 100 / max(1, normalized.count)
            feederLog("\(tag) 🎬 Dolby Vision NALs: "
                    + "RPU(type62)=\(rpu62Size)B  ext(type63)=\(ext63Size)B  "
                    + "DV-overhead=\(dvOverheadPct)% of frame  "
                    + "payload(non-DV)=\(normalized.count - rpu62Size - ext63Size)B")
            if normalized.count < 2000 && !isIDR {
                feederLog("\(tag) ⚠️  Frame is \(normalized.count)B — likely DV Profile 7 Base Layer "
                        + "(BL is intentionally low-bitrate; EL track carries full quality). "
                        + "VideoToolbox renders BL only → expect heavy blocking.")
            }
        }
    }

    // MARK: - CMSampleBuffer construction — Audio

    private func makeAudioSampleBuffer(
        packet:            DemuxPacket,
        formatDescription: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        let dataLen = packet.data.count
        guard let mallocPtr = malloc(dataLen) else {
            throw PlayerLabRenderError.blockBufferAllocFailed
        }
        packet.data.withUnsafeBytes { src in
            memcpy(mallocPtr, src.baseAddress!, dataLen)
        }
        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator:         kCFAllocatorDefault,
            memoryBlock:       mallocPtr,
            blockLength:       dataLen,
            blockAllocator:    kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData:      0,
            dataLength:        dataLen,
            flags:             0,
            blockBufferOut:    &blockBuffer
        )
        guard bbStatus == noErr, let blockBuffer = blockBuffer else {
            free(mallocPtr)
            throw PlayerLabRenderError.blockBufferFailed(bbStatus)
        }
        var timing = CMSampleTimingInfo(
            duration:              packet.duration,
            presentationTimeStamp: packet.pts,
            decodeTimeStamp:       .invalid
        )
        var sampleSize = dataLen
        var sampleBuffer: CMSampleBuffer?
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
            throw PlayerLabRenderError.sampleBufferFailed(sbStatus)
        }
        return sampleBuffer
    }
}
