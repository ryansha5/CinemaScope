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
// The controller configures the feeder once per file (demuxers, format
// descriptions, totals) then calls feedWindow / fetchPackets / enqueueAndAdvance
// as needed. Cursor state is readable by the controller for logging and
// buffer-depth calculation.
//
// `PlayerLabRenderError` is defined here because it is thrown exclusively by
// the sample-buffer construction methods that live in this file.
//
// NOT production-ready. Debug / lab use only.

import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia
import VideoToolbox

// MARK: - PlayerLabRenderError

enum PlayerLabRenderError: Error, LocalizedError {
    case blockBufferAllocFailed
    case blockBufferFailed(OSStatus)
    case sampleBufferFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .blockBufferAllocFailed:    return "malloc() returned nil for block buffer"
        case .blockBufferFailed(let s):  return "CMBlockBufferCreateWithMemoryBlock: \(s)"
        case .sampleBufferFailed(let s): return "CMSampleBufferCreateReady: \(s)"
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

    // MARK: - Init

    init(renderer: FrameRenderer) {
        self.renderer = renderer
    }

    // MARK: - Reset

    /// Clear all per-file state. Called at the start of prepare() and from stop().
    func reset() {
        nextVideoSampleIdx   = 0
        nextAudioSampleIdx   = 0
        lastEnqueuedVideoPTS = 0
        lastEnqueuedAudioPTS = 0
        videoSamplesTotal    = 0
        audioSamplesTotal    = 0
        duration             = 0
        hasAudio             = false
        videoFormatDesc      = nil
        audioFormatDesc      = nil
        mkvDemuxer           = nil
        mp4Demuxer           = nil
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
                if let sb = try? makeVideoSampleBuffer(packet: pkt, formatDescription: vFmt) {
                    result.videoBuffers.append((sb, pkt.pts.seconds))
                    result.lastVideoPTS = max(result.lastVideoPTS, pkt.pts.seconds)
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

        if vCount > 0 {
            let vStart = nextVideoSampleIdx
            for (sb, _) in result.videoBuffers { renderer.enqueueVideo(sb) }
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
            duration:              .invalid,
            presentationTimeStamp: packet.pts,
            decodeTimeStamp:       packet.dts   // .invalid for video (Sprint 30 B-frame fix)
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
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           let dict = (arr as NSArray).firstObject as? NSMutableDictionary {
            dict[kCMSampleAttachmentKey_NotSync as NSString] =
                packet.isKeyframe ? kCFBooleanFalse : kCFBooleanTrue
        }
        return sampleBuffer
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
