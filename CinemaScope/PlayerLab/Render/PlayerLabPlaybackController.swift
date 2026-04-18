// MARK: - PlayerLab / Render / PlayerLabPlaybackController
//
// Sprint 10 — Frame Rendering Proof
// Sprint 11 — Timed Presentation / Playback Clock
// Sprint 12 — HEVC path
//
// Drives the full PlayerLab pipeline for debug video playback:
//   MediaReader → MP4Demuxer → CMVideoFormatDescription
//   → DemuxPacket[] → CMSampleBuffer[] → FrameRenderer → visible output
//
// Supports H.264 (avc1/avc3) and HEVC (hvc1/hev1).
//
// Design:
//   • @MainActor ObservableObject — SwiftUI observes `state` and `log` live
//   • prepare() loads up to `packetCount` packets and enqueues them to the
//     FrameRenderer all at once (sufficient for a proof / short clip)
//   • play() / pause() toggle the CMTimebase rate via FrameRenderer
//   • No audio, no subtitles, no production integration
//
// NOT production-ready. Debug / lab use only.

import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import VideoToolbox

// MARK: - Errors

enum PlayerLabRenderError: Error, LocalizedError {
    case blockBufferAllocFailed
    case blockBufferFailed(OSStatus)
    case sampleBufferFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .blockBufferAllocFailed:      return "malloc() returned nil for block buffer"
        case .blockBufferFailed(let s):    return "CMBlockBufferCreateWithMemoryBlock: \(s)"
        case .sampleBufferFailed(let s):   return "CMSampleBufferCreateReady: \(s)"
        }
    }
}

// MARK: - PlayerLabPlaybackController

@MainActor
final class PlayerLabPlaybackController: ObservableObject {

    // MARK: - State

    enum State: Equatable {
        case idle
        case loading
        case ready
        case playing
        case paused
        case ended
        case failed(String)

        static func == (l: State, r: State) -> Bool {
            switch (l, r) {
            case (.idle, .idle), (.loading, .loading), (.ready, .ready),
                 (.playing, .playing), (.paused, .paused), (.ended, .ended): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }

        var statusLabel: String {
            switch self {
            case .idle:           return "Idle"
            case .loading:        return "Loading…"
            case .ready:          return "Ready"
            case .playing:        return "▶ Playing"
            case .paused:         return "⏸ Paused"
            case .ended:          return "Ended"
            case .failed(let m):  return "❌ \(m)"
            }
        }

        var canPlay: Bool {
            switch self { case .ready, .paused: return true; default: return false }
        }

        var canPause: Bool {
            if case .playing = self { return true }
            return false
        }
    }

    @Published private(set) var state:           State   = .idle
    @Published private(set) var log:             [String] = []
    @Published private(set) var firstFrameSize:  CGSize   = .zero
    @Published private(set) var framesLoaded:    Int      = 0
    @Published private(set) var detectedCodec:   String   = "—"

    // MARK: - Renderer

    /// The frame renderer — attach its layer to a view before calling prepare().
    let renderer = FrameRenderer()

    // MARK: - Private

    private var startPTS: CMTime = .zero

    // MARK: - Init

    init() {
        renderer.onFirstFrame = { [weak self] size in
            // Already on main (called from enqueue, which we call from main).
            self?.firstFrameSize = size
        }
    }

    // MARK: - Prepare (Sprint 10 + 12)
    //
    // Full pipeline:
    //   1. Open MediaReader
    //   2. Parse MP4 box tree (MP4Demuxer)
    //   3. Identify codec (H.264 or HEVC)
    //   4. Build CMVideoFormatDescription
    //   5. Extract up to `packetCount` DemuxPackets
    //   6. Wrap each in a CMSampleBuffer and enqueue to FrameRenderer

    func prepare(url: URL, packetCount: Int = 300) async {
        state = .loading
        log   = []
        renderer.flush()

        record("[prepare] \(url.lastPathComponent)  max=\(packetCount) packets")

        // ── Step 1: Open ────────────────────────────────────────────────────

        record("[1] Opening MediaReader…")
        let reader = MediaReader(url: url)
        do {
            try await reader.open()
            record("  ✅ Opened — \(formatBytes(reader.contentLength))")
        } catch {
            fail("Open failed: \(error.localizedDescription)")
            return
        }

        // ── Step 2: Parse MP4 box tree ───────────────────────────────────────

        record("[2] Parsing MP4 box tree…")
        let demuxer = MP4Demuxer(reader: reader)
        do {
            try await demuxer.parse()
            record("  ✅ Parsed — \(demuxer.tracks.count) tracks found")
        } catch {
            fail("Parse failed: \(error.localizedDescription)")
            return
        }

        // ── Step 3: Identify video track ─────────────────────────────────────

        record("[3] Identifying video track…")
        guard let videoTrack = demuxer.videoTrack else {
            fail("No video track found")
            return
        }

        let fourCC = videoTrack.codecFourCC ?? "?"
        detectedCodec = fourCC
        record("  codec=\(fourCC)  \(videoTrack.displayWidth ?? 0)×\(videoTrack.displayHeight ?? 0)  " +
               "\(videoTrack.sampleCount) samples  \(String(format: "%.2f", videoTrack.durationSeconds))s")

        // ── Step 4: Build CMVideoFormatDescription ────────────────────────────

        record("[4] Building CMVideoFormatDescription (\(fourCC))…")
        let formatDescription: CMVideoFormatDescription
        do {
            if videoTrack.isH264 {
                guard let avcC = videoTrack.avcCData else {
                    fail("H.264 track has no avcC data")
                    return
                }
                formatDescription = try H264Decoder.makeFormatDescription(from: avcC)
                record("  ✅ H.264 format description created (avcC \(avcC.count) bytes)")
            } else if videoTrack.isHEVC {
                guard let hvcC = videoTrack.hvcCData else {
                    fail("HEVC track has no hvcC data")
                    return
                }
                formatDescription = try HEVCDecoder.makeFormatDescription(from: hvcC)
                record("  ✅ HEVC format description created (hvcC \(hvcC.count) bytes)")
            } else {
                fail("Unsupported codec: \(fourCC) — only H.264 and HEVC are supported")
                return
            }
        } catch {
            fail("Format description failed: \(error.localizedDescription)")
            return
        }

        // ── Step 5: Extract DemuxPackets ──────────────────────────────────────

        record("[5] Extracting up to \(packetCount) packets…")
        let packets: [DemuxPacket]
        do {
            packets = try await demuxer.extractPackets(count: packetCount)
        } catch {
            fail("extractPackets failed: \(error.localizedDescription)")
            return
        }
        record("  ✅ Extracted \(packets.count) packets")

        if let first = packets.first {
            startPTS = first.pts
            record("  First PTS: \(String(format: "%.4f", first.pts.seconds))s  " +
                   "keyframe=\(first.isKeyframe)  size=\(first.data.count) bytes")
        }

        // ── Step 6: Create CMSampleBuffers and enqueue ────────────────────────

        record("[6] Building CMSampleBuffers and enqueuing to FrameRenderer…")
        var enqueued  = 0
        var skipped   = 0
        for pkt in packets {
            do {
                let sb = try makeSampleBuffer(packet: pkt, formatDescription: formatDescription)
                renderer.enqueue(sb)
                enqueued += 1
            } catch {
                skipped += 1
                if skipped <= 3 {   // cap noise for repeated errors
                    record("  ⚠️ Packet \(pkt.index): \(error.localizedDescription)")
                }
            }
        }

        framesLoaded = enqueued
        record("  ✅ Enqueued \(enqueued) buffers (skipped \(skipped))")
        record("  Layer status: \(renderer.layerStatusDescription)")
        record("  First frame PTS: \(String(format: "%.4f", renderer.firstFramePTS.seconds))s")

        state = .ready
        record("Ready — call play() to start timed presentation")
    }

    // MARK: - Play / Pause (Sprint 11)

    func play() {
        switch state {
        case .ready:
            renderer.play(from: startPTS)
            state = .playing
            record("▶ play() — timebase started at PTS=\(String(format: "%.4f", startPTS.seconds))s")
        case .paused:
            renderer.resume()
            state = .playing
            record("▶ resume()")
        default:
            break
        }
    }

    func pause() {
        guard case .playing = state else { return }
        renderer.pause()
        state = .paused
        record("⏸ pause()")
    }

    func stop() {
        renderer.flush()
        state        = .idle
        framesLoaded = 0
        detectedCodec = "—"
        firstFrameSize = .zero
        record("⏹ stop() — renderer flushed")
    }

    // MARK: - CMSampleBuffer construction
    //
    // Each DemuxPacket contains raw AVCC / HVCC compressed data.
    // We malloc-copy it into a CMBlockBuffer (VT/AVSBDL will free via
    // kCFAllocatorMalloc when done), then wrap in a CMSampleBuffer with
    // correct PTS/DTS timing.  The kCMSampleAttachmentKey_NotSync attachment
    // tells AVSBDL which frames are sync points so it can manage reference
    // frame flushing correctly.

    private func makeSampleBuffer(
        packet:            DemuxPacket,
        formatDescription: CMVideoFormatDescription
    ) throws -> CMSampleBuffer {

        let dataLen = packet.data.count

        // Malloc-copy — kCFAllocatorMalloc means the framework calls free()
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

        // Timing: use PTS and DTS from the packet.
        // Duration is .invalid — AVSBDL derives presentation duration from
        // the difference between consecutive PTS values.
        var timing = CMSampleTimingInfo(
            duration:               .invalid,
            presentationTimeStamp:  packet.pts,
            decodeTimeStamp:        packet.dts
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

        // kCMSampleAttachmentKey_NotSync:
        //   kCFBooleanFalse → sync/keyframe (IDR)
        //   kCFBooleanTrue  → non-sync (P/B frame)
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true
        ), let dict = (attachmentsArray as NSArray).firstObject as? NSMutableDictionary {
            dict[kCMSampleAttachmentKey_NotSync as NSString] =
                packet.isKeyframe ? kCFBooleanFalse : kCFBooleanTrue
        }

        return sampleBuffer
    }

    // MARK: - Helpers

    private func fail(_ message: String) {
        record("❌ \(message)")
        state = .failed(message)
    }

    func record(_ msg: String) {
        log.append(msg)
        fputs("[PlayerLabPlaybackController] \(msg)\n", stderr)
    }

    private func formatBytes(_ n: Int64) -> String {
        if n < 1_048_576     { return String(format: "%.1f KB",  Double(n) / 1_024) }
        if n < 1_073_741_824 { return String(format: "%.2f MB",  Double(n) / 1_048_576) }
        return                        String(format: "%.2f GB",  Double(n) / 1_073_741_824)
    }
}
