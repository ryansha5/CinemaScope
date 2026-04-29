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
        /// Total number of video packets fetched from the demuxer, including those
        /// skipped by the DV BL frame filter and those that failed to build.
        /// enqueueAndAdvance uses this (not videoBuffers.count) to advance the
        /// video cursor so that skipped/failed frames don't cause re-fetches.
        var totalVideoAttempted: Int = 0
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

    // MARK: - Synthetic HEVC DTS (Sprint 50)
    //
    // HEVC MKV stores frames in decode order (non-monotonic PTS: IDR at 0.000,
    // B-anchor at 0.209, B-frames at 0.125, 0.083, 0.042...).  Our pipeline
    // fileOffset-sorts each batch, preserving decode order.  AVSampleBufferDisplayLayer
    // requires a valid DTS to schedule decode before display reordering.  With
    // dts=.invalid, the layer uses PTS as decode time, which causes B-frames that
    // reference a future-PTS anchor to be scheduled before that anchor is decoded →
    // chroma corruption on every affected B-frame group.
    //
    // Fix: synthesise DTS[n] = basePTS + n × frameDuration.  Each HEVC frame that
    // completes makeVideoSampleBuffer increments the counter; BL-filtered frames
    // do not (they never reach VideoToolbox).  Reset on prepare/stop (reset()) and
    // seek (setCursors → resetHEVCDTSState()).

    /// Monotonic counter for HEVC frames handed to VideoToolbox.
    /// Skipped BL-filter frames do NOT count.
    private var hevcDecodeCounter: Int = 0

    /// PTS of the first HEVC frame after prepare/seek — the DTS origin.
    /// Set on the very first makeVideoSampleBuffer call; reset on seek.
    private var hevcDTSBasePTS: CMTime = .invalid

    /// Duration of one HEVC video frame.
    /// Derived once from videoSamplesTotal/duration; reset on prepare/stop only
    /// (seek keeps it — same file, same fps).
    private var hevcFrameDuration: CMTime = .invalid

    /// Previous synthetic DTS — used to assert strict monotonicity each frame.
    private var hevcLastSynthDTS: CMTime = .invalid

    // MARK: - Sprint 46: DV stripping toggle + BL frame filter

    /// Set to false to disable Dolby Vision NAL stripping entirely.
    /// Use for diagnosing whether the strip path breaks sample delivery or
    /// decoder initialisation.  When false, all NAL types (including 62/63)
    /// are passed to VideoToolbox unchanged.
    /// Default: true (strip DV NALs before handing to VT).
    static var stripDolbyVisionNALsEnabled: Bool = true

    /// When true, the GOP batch validator emits detailed [GOP-TAIL] lines for
    /// the last ~10 frames before each IDR boundary.  The tail lines include
    /// synthDTS and firstNALType sourced from FrameDiagnosticStore (populated
    /// by makeVideoSampleBuffer immediately before the tail log fires).
    ///
    /// Disable in production — output is verbose (one line per B-frame, every
    /// GOP, every ~10 seconds of playback).  Toggle from the debug console or
    /// a hidden Settings switch during regression investigations.
    static var gopDeepDebugEnabled: Bool = false

    /// Maximum raw byte size of a DV Base Layer frame.
    /// Any video packet below this threshold is treated as a BL skip/trailing
    /// frame and silently discarded when DV stripping is enabled AND the file
    /// is confirmed to be DV dual-layer (isDolbyVisionDualLayer == true).
    ///
    /// Empirical threshold for DV Profile 7:
    ///   BL frames: 114 – 362 B (TRAIL_N / TRAIL_R skip frames)
    ///   EL frames: ≥ 1002 B (CRA keyframe, then large inter-frames)
    ///
    /// 600 B sits safely between the two populations with >3× margin on the
    /// high end.  Raise only if a legitimate EL frame ever falls below this.
    ///
    /// IMPORTANT: this filter must ONLY fire on confirmed DV dual-layer files.
    /// Non-DV HEVC encodes can produce legitimate frames below 600 B in
    /// low-motion or static scenes — dropping them causes periodic decode
    /// corruption as the decoder loses reference frames.
    static let kDVBLFrameSizeThreshold: Int = 600

    /// Set to true when the source file is confirmed to be Dolby Vision Profile 7
    /// dual-layer (interleaved BL+EL frames on the video track).  Gates the BL
    /// frame size filter in fetchPackets — the filter must NEVER run on non-DV
    /// content regardless of stripDolbyVisionNALsEnabled.
    /// Set by PlayerLabPlaybackController.prepare() from mkvDemuxer.isDolbyVisionDualLayer.
    var isDolbyVisionDualLayer: Bool = false

    /// The exclusive upper bound of the DV BL preamble cluster, expressed as a
    /// video frame index.  Equals mkvDemuxer.firstVideoKeyframeIndex for DV
    /// dual-layer files and 0 for all other files.
    ///
    /// The BL size filter in fetchPackets must only apply to frames whose index
    /// is LESS THAN this value (the pre-EL BL-only preamble).  Frames at or
    /// beyond this index are EL frames and must never be filtered by size —
    /// legitimate EL B-frames in low-motion scenes can be well below 600 B.
    ///
    /// Sprint 66: restricting the filter scope here eliminates the false positive
    /// that dropped 83 EL inter-frames from the initial batch on DV P7 files whose
    /// EL starts at a CRA keyframe (e.g. idx=24).
    var dvBLPreambleEndIndex: Int = 0

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
        hevcDecodeCounter     = 0
        hevcDTSBasePTS        = .invalid
        hevcFrameDuration     = .invalid
        hevcLastSynthDTS      = .invalid
        isDolbyVisionDualLayer = false
        dvBLPreambleEndIndex  = 0
    }

    // MARK: - Cursor teleport (seek)

    /// Atomically reset all cursor and tail state to a new seek position.
    /// Called by the controller between the flush and enqueue phases of seek().
    func setCursors(videoIdx: Int, audioIdx: Int, videoPTS: Double, audioPTS: Double) {
        nextVideoSampleIdx   = videoIdx
        nextAudioSampleIdx   = audioIdx
        lastEnqueuedVideoPTS = videoPTS
        lastEnqueuedAudioPTS = audioPTS
        resetHEVCDTSState()
    }

    /// Reset the HEVC synthetic-DTS counter and base for a seek.
    /// Called from setCursors() so the DTS sequence restarts from the seek IDR.
    /// hevcFrameDuration is intentionally kept — same file, same fps.
    private func resetHEVCDTSState() {
        hevcDecodeCounter = 0
        hevcDTSBasePTS    = .invalid
        hevcLastSynthDTS  = .invalid
        feederLog("[HEVC-DTS] state reset (seek/cursor reposition)")
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

        var limitedVideo = min(videoCount, videoSamplesTotal - fromVideoIdx)
        guard limitedVideo > 0 else { return result }

        // ── Sprint 51: Snap batch end to next GOP (IDR) boundary ─────────────
        //
        // The frameIndex is sorted by PTS, so a batch of N frames starting at
        // fromVideoIdx covers frames [fromVideoIdx, fromVideoIdx+N).  Inside
        // extractVideoPackets those frames are RE-SORTED by fileOffset (decode
        // order) before being handed to VideoToolbox.
        //
        // Problem: if the desired batch-end (fromVideoIdx+N) falls in the middle
        // of a GOP, the B-frames of the last sub-GOP are included in this batch
        // but their reference P-frame has a HIGHER PTS (→ higher index → next
        // batch).  In fileOffset order the P-frame precedes the B-frames it
        // anchors, so those B-frames end up at VT without a decoded reference
        // frame → VideoToolbox produces deterministic chroma corruption at the
        // same positions every run.
        //
        // Fix: extend limitedVideo so the batch ends at nextIDR−1, giving VT
        // complete GOPs.  Extension ≤ (gopSize−1) frames ≈ 23 frames for 24fps.
        // Only applied for MKV HEVC (fileOffset-sort path); MP4 is PTS-order and
        // does not need this.
        let videoIsHEVC = CMFormatDescriptionGetMediaSubType(vFmt) == kCMVideoCodecType_HEVC

        // Sprint 64: tracks the IDR index added by the GOP snap so the
        // pre-IDR tail diagnostic (inside the do-block below) can reference it.
        var gopSnapIDR: Int? = nil

        if let mkv = mkvDemuxer, videoIsHEVC {
            let desiredEnd = fromVideoIdx + limitedVideo
            if desiredEnd < videoSamplesTotal {
                let nextIDR  = mkv.nextVideoKeyframeSampleIndex(from: desiredEnd)

                // Sprint 64 root-cause fix: include the IDR frame itself (+1).
                //
                // Previous snap ended at nextIDR-1 (the frame just before the IDR).
                // HEVC hierarchical B-frames at the tail of the current GOP use the
                // IDR as their FORWARD reference anchor; when the IDR is absent VT
                // decodes those B-frames with a missing reference and produces
                // deterministic corruption in the last mini-GOP (~12–16 frames)
                // before every GOP boundary.
                //
                // The IDR always has the smallest fileOffset in its mini-GOP
                // (it must be decoded before the B-frames that depend on it).
                // extractVideoPackets' fileOffset sort therefore places it first
                // in the batch regardless of its PTS order position — VT sees the
                // IDR before any of the B-frames that reference it.  ✅
                //
                // The next batch starts at nextIDR+1 (one past the IDR).  VT's
                // decoder state for AVSampleBufferDisplayLayer persists across
                // enqueue calls, so the IDR decoded in this batch is available as
                // a reference frame for the next batch's inter-frames.  ✅
                let extended = min(nextIDR + 1, videoSamplesTotal) - fromVideoIdx
                if extended > limitedVideo {
                    feederLog("[fetchPackets] GOP-snap [\(label)]:"
                            + " extended video batch \(limitedVideo)→\(extended)"
                            + " (desiredEnd=\(desiredEnd) non-IDR"
                            + " → IDR@\(nextIDR) INCLUDED ✅)")
                    limitedVideo = extended
                    gopSnapIDR   = nextIDR
                }
            }
        }

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
            // Track how many packets were attempted so the cursor advances past
            // BL-filtered and build-failed frames (see totalVideoAttempted below).
            result.totalVideoAttempted = packets.count

            // Codec type — used for the BL frame filter and makeVideoSampleBuffer branching.
            let isHEVC = CMFormatDescriptionGetMediaSubType(vFmt) == kCMVideoCodecType_HEVC

            // ── HEVC batch boundary diagnostic ────────────────────────────────
            // Log the first and last 3 packets in the order delivered by the
            // demuxer (decode / fileOffset order after Sprint 47 sort).  This
            // lets us verify that B-frame reference frames are present at both
            // ends of each batch and identify cross-batch reference gaps.
            if isHEVC, !packets.isEmpty {
                let n = packets.count
                let logIndices: [Int] = n <= 6
                    ? Array(0..<n)
                    : [0, 1, 2, n-3, n-2, n-1]
                for i in logIndices {
                    let p    = packets[i]
                    let pos  = (n <= 6 || i < 3) ? "HEAD" : "TAIL"
                    feederLog("[HEVC-\(label)-\(pos)[\(i)/\(n)]]"
                            + " idx=\(p.index)"
                            + " pts=\(String(format: "%.3f", p.pts.seconds))s"
                            + " off=\(p.byteOffset)"
                            + " kf=\(p.isKeyframe)"
                            + " sz=\(p.data.count)B")
                }

                // Sprint 64: Pre-IDR tail diagnostic — fires on every GOP snap.
                //
                // Shows the last 30 frames sorted by PTS so we can see the
                // temporal approach to the IDR boundary and verify:
                //   1. The IDR (largest PTS, smallest fileOffset) IS present.
                //   2. Its fileOffset is smaller than the B-frames before it,
                //      confirming the sort puts it first in VT's decode queue.
                //   3. All B-frames near the tail share the same batch label
                //      as the IDR (same enqueue call → VT has the reference).
                if let snapIDR = gopSnapIDR {
                    let ptsSorted = packets.sorted { $0.pts < $1.pts }
                    let tail      = ptsSorted.suffix(min(30, ptsSorted.count))
                    feederLog("[S64-\(label)-PreIDR] IDR=idx\(snapIDR)"
                            + "  last \(tail.count) frames by PTS (batch=\(label)):")
                    for p in tail {
                        let tag = p.isKeyframe ? "✅IDR" : "   B"
                        feederLog("  \(tag) idx=\(p.index)"
                                + "  pts=\(String(format: "%.4f", p.pts.seconds))s"
                                + "  off=\(p.byteOffset)"
                                + "  sz=\(p.data.count)B")
                    }
                }

                // ── GOP batch validation (Sprint 64) ──────────────────────────
                //
                // Verifies every HEVC batch is decode-complete BEFORE any frame
                // reaches makeVideoSampleBuffer / VideoToolbox.
                //
                // Invariant: the last frame by PTS must be the IDR that anchors
                // the tail B-frames as their forward reference.  If it is not,
                // those B-frames will decode with a missing reference → the
                // deterministic corruption we fixed in Sprint 64.
                //
                // [GOP-CHECK]  — always; one line per batch boundary
                // [GOP-WINDOW] — always; prev/next keyframe context
                // [GOP-ERROR]  — only on invariant violation (+ assertionFailure)

                let ptsForCheck = packets.sorted { $0.pts < $1.pts }
                if let firstP = ptsForCheck.first, let lastP = ptsForCheck.last {

                    // 1. Batch boundary log
                    feederLog("[GOP-CHECK] batch=\(label)"
                            + "  startIdx=\(firstP.index)"
                            + "  pts=\(String(format: "%.4f", firstP.pts.seconds))s"
                            + "  kf=\(firstP.isKeyframe)")
                    feederLog("[GOP-CHECK] batch=\(label)"
                            + "  endIdx=\(lastP.index)"
                            + "  pts=\(String(format: "%.4f", lastP.pts.seconds))s"
                            + "  kf=\(lastP.isKeyframe ? "✅" : "❌")")

                    // 3. Keyframe window — prevKF (the IDR that opened this GOP)
                    //    and nextKF (the first IDR after the batch, outside it).
                    if let mkv = mkvDemuxer {
                        let prevKFIdx = fromVideoIdx == 0
                            ? 0
                            : mkv.findVideoKeyframeSampleIndex(nearestBeforePTS:
                                mkv.videoPTS(forSample: fromVideoIdx))
                        let nextKFIdx = mkv.nextVideoKeyframeSampleIndex(
                                            from: lastP.index + 1)
                        let prevKFPTS = String(format: "%.4f",
                                               mkv.videoPTS(forSample: prevKFIdx).seconds)
                        let nextKFPTS: String
                        if nextKFIdx < videoSamplesTotal {
                            nextKFPTS = String(format: "%.4f",
                                               mkv.videoPTS(forSample: nextKFIdx).seconds)
                        } else {
                            nextKFPTS = "EOF"
                        }
                        feederLog("[GOP-WINDOW] batch=\(label)"
                                + "  prevKF=idx\(prevKFIdx)/\(prevKFPTS)s"
                                + "  batchEnd=idx\(lastP.index)/\(String(format: "%.4f", lastP.pts.seconds))s"
                                + " \(lastP.isKeyframe ? "✅" : "❌")"
                                + "  nextKF=idx\(nextKFIdx)/\(nextKFPTS)s")
                    }

                    // 2. Invalid boundary check + safety assertion
                    //    Last frame by PTS MUST be a keyframe unless we are at
                    //    end-of-file (no more samples to snap to).
                    let isAtEOF = lastP.index >= videoSamplesTotal - 1
                    if !lastP.isKeyframe && !isAtEOF {
                        let errMsg = "[GOP-ERROR] batch=\(label)"
                                   + " last frame idx=\(lastP.index)"
                                   + " pts=\(String(format: "%.4f", lastP.pts.seconds))s"
                                   + " is NOT a keyframe — tail B-frames lack"
                                   + " forward reference → corruption imminent"
                        feederLog(errMsg)
                        assertionFailure(errMsg)  // debug builds only
                    }

                    // 5. First-batch keyframe check.
                    //    Batch 0 must start with an IDR so VT has a clean base.
                    if fromVideoIdx == 0, !firstP.isKeyframe {
                        let errMsg = "[GOP-ERROR] batch=\(label)"
                                   + " first batch (fromIdx=0) does not start"
                                   + " with a keyframe!"
                                   + " startIdx=\(firstP.index)"
                                   + " pts=\(String(format: "%.4f", firstP.pts.seconds))s"
                        feederLog(errMsg)
                        assertionFailure(errMsg)  // debug builds only
                    }
                }
            }

            for pkt in packets {
                // ── DV BL frame filter (HEVC / Dolby Vision only) ────────────────
                // DV Profile 7 BL preamble filter.
                //
                // The FIRST cluster of a DV P7 MKV contains Base Layer (BL) skip
                // frames (~114–362 B) that a standard HEVC decoder cannot process.
                // These live at indices 0 ..< dvBLPreambleEndIndex (typically 0 ..< 24).
                //
                // Sprint 66: The filter is now restricted to the BL preamble range
                // (pkt.index < dvBLPreambleEndIndex).  Previous code applied the
                // size threshold throughout the whole file, which incorrectly dropped
                // legitimate EL B-frames in low-motion scenes (e.g. 83/227 frames in
                // the initial batch of a DV P7 TV episode → decode graph holes → distortion).
                //
                // Frames at or beyond dvBLPreambleEndIndex are EL frames and are
                // never filtered by size, regardless of their byte count.
                // H.264 content never has DV BL frames — filter is HEVC-only.
                if isHEVC
                    && PacketFeeder.stripDolbyVisionNALsEnabled
                    && isDolbyVisionDualLayer
                    && dvBLPreambleEndIndex > 0
                    && pkt.index < dvBLPreambleEndIndex
                    && pkt.data.count < PacketFeeder.kDVBLFrameSizeThreshold {
                    feederLog("  [\(label)] DV BL skip  pkt=\(pkt.index)"
                            + "  pts=\(String(format: "%.3f", pkt.pts.seconds))s"
                            + "  size=\(pkt.data.count)B  keyframe=\(pkt.isKeyframe)")
                    FrameDiagnosticStore.shared.append(FrameDiagnosticRecord(
                        sampleIndex:  pkt.index,
                        pts:          pkt.pts.seconds,
                        synthDTS:     Double.nan,
                        fileOffset:   pkt.byteOffset,
                        rawSize:      pkt.data.count,
                        finalSize:    0,
                        isKeyframe:   pkt.isKeyframe,
                        firstNALType: "?",
                        batchLabel:   label,
                        state:        .filtered,
                        filterReason: "DV-BL-size"
                    ))
                    continue
                }

                // Sprint 46: replace try? with explicit catch so buffer-construction
                // failures are visible (try? was silently discarding them, causing
                // SampleDiag to fire while enqueueAndAdvance received 0 buffers).
                do {
                    let sb = try makeVideoSampleBuffer(packet: pkt, formatDescription: vFmt,
                                                       batchLabel: label)
                    result.videoBuffers.append((sb, pkt.pts.seconds))
                    result.lastVideoPTS = max(result.lastVideoPTS, pkt.pts.seconds)
                } catch {
                    feederLog("  ⚠️ [\(label)] makeVideoSampleBuffer failed  "
                            + "pkt.index=\(pkt.index)  pts=\(String(format: "%.3f", pkt.pts.seconds))s  "
                            + "size=\(pkt.data.count)B  keyframe=\(pkt.isKeyframe)  "
                            + "error=\(error.localizedDescription)")
                    FrameDiagnosticStore.shared.append(FrameDiagnosticRecord(
                        sampleIndex:  pkt.index,
                        pts:          pkt.pts.seconds,
                        synthDTS:     Double.nan,
                        fileOffset:   pkt.byteOffset,
                        rawSize:      pkt.data.count,
                        finalSize:    0,
                        isKeyframe:   pkt.isKeyframe,
                        firstNALType: "?",
                        batchLabel:   label,
                        state:        .filtered,
                        filterReason: "make-failed"
                    ))
                }
            }

            // ── GOP deep-debug tail (Sprint 64, optional) ─────────────────────
            //
            // Fires after makeVideoSampleBuffer has run for every packet in the
            // batch so FrameDiagnosticStore contains synthDTS and firstNALType.
            // Queries those records to produce a fully-annotated per-frame table
            // for the last ~10 frames before each IDR boundary.
            //
            // Gate: gopDeepDebugEnabled must be true (default false).
            // Overhead when disabled: one Bool check per batch — negligible.

            if isHEVC, PacketFeeder.gopDeepDebugEnabled, let snapIDR = gopSnapIDR {
                let ptsTail = packets
                    .sorted  { $0.pts < $1.pts }
                    .suffix(min(10, packets.count))
                let idrPresent = packets.contains { $0.isKeyframe }
                feederLog("[GOP-TAIL] batch=\(label)"
                        + "  IDRinBatch=\(idrPresent ? "✅" : "❌")"
                        + "  snapIDR=idx\(snapIDR)"
                        + "  last \(ptsTail.count) frames:")
                for p in ptsTail {
                    let kfTag = p.isKeyframe ? "✅IDR" : "   B"
                    // Pull DTS + NAL type from FrameDiagnosticStore — populated
                    // by makeVideoSampleBuffer moments ago in the loop above.
                    let rec = FrameDiagnosticStore.shared.record(
                                nearPTS: p.pts.seconds, batchLabel: label)
                    let dtsStr  = rec.flatMap {
                        $0.synthDTS.isNaN ? nil : String(format: "%.4f", $0.synthDTS)
                    } ?? "?"
                    let typeStr = rec?.firstNALType ?? "?"
                    feederLog("  [GOP-TAIL] \(kfTag)"
                            + "  idx=\(p.index)"
                            + "  pts=\(String(format: "%.4f", p.pts.seconds))s"
                            + "  dts=\(dtsStr)s"
                            + "  type=\(typeStr)"
                            + "  sz=\(p.data.count)B"
                            + "  nextKFInBatch=\(idrPresent)")
                }
            }

        } catch {
            log("  ⚠️ [\(label)] video fetch failed: \(error.localizedDescription)")
        }

        // ── Audio ─────────────────────────────────────────────────────────────
        //
        // GOP-snap (Sprint 51) silently extends the video batch beyond the
        // originally-requested `audioSeconds` window.  If we fetch audio for
        // only `audioSeconds` worth of content, the audio playerNode runs dry
        // before the next refill fires, causing periodic silence.
        //
        // Fix: after GOP-snap we know the actual video frames fetched
        // (limitedVideo).  Convert that back to seconds using the indexed fps,
        // then size the audio window to cover at least that many seconds.
        //
        // Example: toFill=6.0s, but GOP-snap extended video from 144→243 frames
        // (≈10.1s at 24fps).  Without this fix audio gets 6.0s; with it audio
        // gets ≈10.1s — matching the video window and eliminating the gap.

        if hasAudio, let aFmt = audioFormatDesc {
            // Scale audio to cover the actual (post-GOP-snap) video window.
            let effectiveAudioSeconds: Double
            if duration > 0, videoSamplesTotal > 0 {
                let fps = Double(videoSamplesTotal) / duration
                let videoSecondsActual = fps > 0 ? Double(limitedVideo) / fps : audioSeconds
                effectiveAudioSeconds = max(audioSeconds, videoSecondsActual)
            } else {
                effectiveAudioSeconds = audioSeconds
            }
            let limitedAudio = min(audioSamplesFor(seconds: effectiveAudioSeconds),
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
        feederLog("[enqueue] [\(result.label)] called  videoBuffers=\(vCount)"
                + "/\(result.totalVideoAttempted)  audioBuffers=\(aCount)")
        if vCount == 0 && result.totalVideoAttempted > 0 {
            // All attempted frames were either BL-filtered or failed to build.
            feederLog("[enqueue] [\(result.label)] ⚠️ zero video buffers — "
                    + "all \(result.totalVideoAttempted) packets were BL-filtered or "
                    + "makeVideoSampleBuffer failed; check lines above for detail")
            log("  [\(result.label)] ⚠️ enqueueAndAdvance: 0 video buffers built — "
              + "no frames enqueued this cycle")
        }

        if vCount > 0 || result.totalVideoAttempted > 0 {
            let vStart = nextVideoSampleIdx
            // Advance the cursor by totalVideoAttempted (the number of frameIndex
            // slots consumed this batch) rather than vCount (the number actually
            // enqueued).  This keeps the cursor aligned when BL frames were skipped
            // by the DV filter or when makeVideoSampleBuffer threw for some frames.
            // Using vCount alone would leave the cursor short by the number of
            // skipped/failed packets, causing those frame indices to be re-fetched
            // on the next call — and EL frames after them to be double-enqueued.
            let cursorAdvance = max(vCount, result.totalVideoAttempted)
            feederLog("[enqueue] [\(result.label)] video cursor=\(vStart)  "
                    + "enqueueing \(vCount)/\(result.totalVideoAttempted) buffers  "
                    + "tail=\(String(format: "%.3f", result.lastVideoPTS))s")
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
            nextVideoSampleIdx  += cursorAdvance
            let skipped = result.totalVideoAttempted - vCount
            let skippedStr = skipped > 0 ? "  blSkipped=\(skipped)" : ""
            log("  [\(result.label)] video [\(vStart)…\(nextVideoSampleIdx - 1)]  "
              + "\(vCount) pkts  tail=\(String(format: "%.2f", lastEnqueuedVideoPTS))s\(skippedStr)")
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
        formatDescription: CMVideoFormatDescription,
        batchLabel:        String
    ) throws -> CMSampleBuffer {

        // ── Codec detection ───────────────────────────────────────────────────
        //
        // H.264 and HEVC share this path but differ in:
        //   • nalUnitLength extraction API (avcC vs hvcC parameter set query)
        //   • NAL header width (1 byte vs 2 bytes)
        //   • DV NAL stripping (HEVC only — H.264 never carries type 62/63)
        //   • BL frame filter (HEVC-only, handled upstream in fetchPackets)
        //
        // Detect codec once here so all downstream steps branch correctly.

        let isHEVC = CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_HEVC

        // ── Sprint 44: Annex B detection + conversion ─────────────────────────
        //
        // MKV stores NAL units in Annex B bytestream format (start-code
        // delimited: 00 00 01 or 00 00 00 01 before each NAL unit).  VideoToolbox
        // requires length-prefixed format (big-endian nalUnitLength bytes before
        // each NAL unit), matching the format description built from hvcC/avcC.
        //
        // This conversion must happen for every sample, not just keyframes.
        // Passing Annex B bytes to VT causes it to read start-code bytes as a
        // length field (typically 00 00 00 01 = length 1), producing completely
        // wrong NAL unit boundaries and corrupted output.
        //
        // nalUnitLength is extracted from the format description (usually 4).

        let nalUnitLength = isHEVC
            ? PacketFeeder.hevcNalUnitLength(from: formatDescription)
            : PacketFeeder.avcNalUnitLength(from: formatDescription)
        let rawBytes = Array(packet.data)   // flatten to 0-based [UInt8]

        // detectNALFormat does full LP validation.  If the buffer isn't a
        // well-formed LP stream it falls back to Annex B conversion, which is
        // the correct path for MKV HEVC/AVC content.
        let fmt = PacketFeeder.detectNALFormat(rawBytes, nalUnitLength: nalUnitLength)
        let normalizedBytes: Data
        if fmt == .annexB {
            normalizedBytes = PacketFeeder.convertAnnexBToLengthPrefixed(rawBytes,
                                                                          nalUnitLength: nalUnitLength)
        } else {
            // LP format: trim any trailing padding bytes before handing to VT.
            //
            // Some MKV muxers append 1–3 alignment/padding bytes after the last
            // LP NAL unit.  isValidLengthPrefixed requires i == n (all bytes
            // consumed exactly) — trailing bytes make it return false, causing
            // detectNALFormat to fall back to Annex B classification on data
            // that is already correctly length-prefixed.  convertAnnexBToLengthPrefixed
            // then finds no start codes in the LP payload and produces empty output,
            // or in rare cases finds a false start code match and corrupts the frame.
            //
            // trimLPTrailingBytes walks the LP NAL units and returns the data
            // trimmed to the last valid NAL boundary.  This is the fix for the
            // "specific HEVC frames consistently distort" issue observed in Phase 3.
            normalizedBytes = PacketFeeder.trimLPTrailingBytes(rawBytes,
                                                               nalUnitLength: nalUnitLength,
                                                               original: packet.data)
        }

        // ── HEVC extended diagnostics ──────────────────────────────────────────
        //
        // 1. Log all HEVC keyframes — gives us the GOP structure, IDR vs. CRA type,
        //    and confirms the NAL format detected for each random-access point.
        // 2. Log any Annex B detections beyond the first kDiagnosticSampleCount
        //    frames — these indicate LP validation failures on specific frames,
        //    which is the symptom the trailing-byte fix addresses.
        if isHEVC {
            if packet.isKeyframe {
                let nalTypes = PacketFeeder.nalTypesFromLengthPrefixed(
                    Array(normalizedBytes), nalUnitLength: nalUnitLength, isHEVC: true)
                let typeDesc = nalTypes.isEmpty ? "—" : nalTypes.map {
                    "\(PacketFeeder.hevcNALTypeName($0.type)):\($0.size)B"
                }.joined(separator: " ")
                feederLog("[HEVC-KF] idx=\(packet.index)"
                        + "  pts=\(String(format: "%.3f", packet.pts.seconds))s"
                        + "  offset=\(packet.byteOffset)"
                        + "  raw=\(packet.data.count)B  norm=\(normalizedBytes.count)B"
                        + "  fmt=\(fmt == .annexB ? "AnnexB→LP" : "LP")"
                        + "  NALs: \(typeDesc)")
            }
            if fmt == .annexB && videoSamplesDiagnosed >= PacketFeeder.kDiagnosticSampleCount {
                feederLog("[HEVC-AnnexB] idx=\(packet.index)"
                        + "  pts=\(String(format: "%.3f", packet.pts.seconds))s"
                        + "  offset=\(packet.byteOffset)"
                        + "  size=\(packet.data.count)B"
                        + "  ⚠️ LP validation failed → AnnexB conversion applied")
            }
        }

        // Strip Dolby Vision NAL types 62 (RPU) and 63 (EL wrapper) before
        // handing to VideoToolbox.  HEVC only — H.264 never contains DV NALs.
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
        if isHEVC && PacketFeeder.stripDolbyVisionNALsEnabled {
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
            // H.264: never strip.  HEVC with stripping disabled: pass through.
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
                isHEVC:        isHEVC,
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

        // ── Synthetic DTS for HEVC B-frame decode ordering ───────────────────
        //
        // H.264: frames arrive in PTS order (monotonic) → dts=.invalid is fine;
        //        the layer treats PTS as decode time with no ill effect.
        //
        // HEVC: frames arrive in fileOffset (decode) order → PTS is non-monotonic
        //        (e.g. 0.000, 0.209, 0.125, 0.083...).  With dts=.invalid the layer
        //        uses PTS as decode time, scheduling B-frames before their reference
        //        P-frame is decoded → chroma corruption every affected B-group.
        //
        //        Fix: DTS[n] = basePTS + n × frameDuration.  Strictly increasing,
        //        matches decode (enqueue) order, gives the layer the ordering signal
        //        it needs.  PTS is unchanged — display order is unaffected.
        let decodeTSForBuffer: CMTime
        if isHEVC {

            // ── Derive frame duration (once, lazily) ──────────────────────────
            // Primary: sampleCount / indexedDuration (set by prepare, accurate at
            //          even the smallest initial window of 8–9 s of content).
            // Fallback: 24 fps (covers the vast majority of cinematic content).
            if !hevcFrameDuration.isValid {
                if duration > 0, videoSamplesTotal > 0 {
                    let fps = Double(videoSamplesTotal) / duration
                    hevcFrameDuration = CMTime(seconds: 1.0 / fps,
                                              preferredTimescale: 90_000)
                    feederLog("[HEVC-DTS] frameDuration derived:"
                            + " \(String(format: "%.6f", hevcFrameDuration.seconds))s"
                            + " (fps=\(String(format: "%.4f", fps))"
                            + " from \(videoSamplesTotal) samples"
                            + " / \(String(format: "%.3f", duration))s)")
                } else {
                    hevcFrameDuration = CMTime(value: 3_750, timescale: 90_000) // 1/24 s
                    feederLog("[HEVC-DTS] frameDuration fallback: 1/24 s"
                            + " (videoSamplesTotal=\(videoSamplesTotal)"
                            + " duration=\(duration))")
                }
            }

            // ── Anchor base PTS on the first frame after prepare/seek ─────────
            if !hevcDTSBasePTS.isValid {
                hevcDTSBasePTS = packet.pts
                feederLog("[HEVC-DTS] basePTS anchored:"
                        + " \(String(format: "%.4f", hevcDTSBasePTS.seconds))s"
                        + " (first HEVC frame after prepare/seek,"
                        + " kf=\(packet.isKeyframe))")
            }

            // ── DTS[n] = basePTS + n × frameDuration ──────────────────────────
            decodeTSForBuffer = CMTimeAdd(
                hevcDTSBasePTS,
                CMTimeMultiply(hevcFrameDuration, multiplier: Int32(hevcDecodeCounter))
            )

            // ── Diagnostic: first 20 HEVC frames ─────────────────────────────
            if hevcDecodeCounter < 20 {
                let delta = CMTimeSubtract(packet.pts, decodeTSForBuffer)
                feederLog("[HEVC-DTS] [\(String(format: "%3d", hevcDecodeCounter))]"
                        + "  off=\(packet.byteOffset)"
                        + "  pts=\(String(format: "%.4f", packet.pts.seconds))s"
                        + "  synDTS=\(String(format: "%.4f", decodeTSForBuffer.seconds))s"
                        + "  Δ(pts-dts)=\(String(format: "%+.4f", delta.seconds))s"
                        + "  kf=\(packet.isKeyframe)")
            }

            // ── Assert strict monotonicity ────────────────────────────────────
            if hevcLastSynthDTS.isValid,
               CMTimeCompare(decodeTSForBuffer, hevcLastSynthDTS) <= 0 {
                feederLog("[HEVC-DTS] ❌ DTS did not increase!"
                        + "  prev=\(String(format: "%.6f", hevcLastSynthDTS.seconds))s"
                        + "  new=\(String(format: "%.6f", decodeTSForBuffer.seconds))s"
                        + "  counter=\(hevcDecodeCounter)")
                assertionFailure("[HEVC-DTS] synthetic DTS must strictly increase — "
                               + "check hevcDecodeCounter/reset logic")
            }
            hevcLastSynthDTS = decodeTSForBuffer

            // Counter increments after DTS is computed so counter 0 → DTS = basePTS.
            hevcDecodeCounter += 1

        } else {
            // H.264: dts=.invalid correct — presentation order == decode order.
            decodeTSForBuffer = packet.dts
        }

        // ── CMSampleBuffer ────────────────────────────────────────────────────
        var timing = CMSampleTimingInfo(
            duration:              .invalid,
            presentationTimeStamp: packet.pts,
            decodeTimeStamp:       decodeTSForBuffer
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

        // ── FrameDiagnosticStore: record successful frame (Sprint 61) ─────────
        let diagFirstNAL: String = {
            let nals = PacketFeeder.nalTypesFromLengthPrefixed(
                Array(normalizedBytes), nalUnitLength: nalUnitLength, isHEVC: isHEVC)
            guard let first = nals.first else { return "?" }
            return isHEVC ? PacketFeeder.hevcNALTypeName(first.type)
                          : PacketFeeder.avcNALTypeName(first.type)
        }()
        let diagSynthDTS: Double = isHEVC ? decodeTSForBuffer.seconds : Double.nan
        FrameDiagnosticStore.shared.append(FrameDiagnosticRecord(
            sampleIndex:  packet.index,
            pts:          packet.pts.seconds,
            synthDTS:     diagSynthDTS,
            fileOffset:   packet.byteOffset,
            rawSize:      packet.data.count,
            finalSize:    sampleBytes.count,
            isKeyframe:   packet.isKeyframe,
            firstNALType: diagFirstNAL,
            batchLabel:   batchLabel,
            state:        .fetched,
            filterReason: nil
        ))

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
    ///   1. Try exact full LP validation (`isValidLengthPrefixed`).
    ///      If every length field accounts for exactly the total buffer size,
    ///      the data is length-prefixed.
    ///   2. Try LP with trailing-byte tolerance (`looksLikeLPWithTrailingBytes`).
    ///      Some MKV muxers append 1–3 alignment bytes after the last LP NAL;
    ///      these cause the exact check to fail even though the data is LP.
    ///   3. Otherwise fall back to Annex B conversion.
    ///
    /// ⚠️  The former fast-path start-code checks are intentionally removed:
    ///
    ///   OLD (broken):
    ///     if b[0]==0 && b[1]==0 && b[2]==1 { return .annexB }   // FALSE POSITIVE
    ///
    ///   For LP streams with 4-byte length fields and NAL sizes 256–511 bytes
    ///   the length prefix is  00 00 01 XX  — b[2] == 1 is a coincidence of the
    ///   size encoding, not an Annex B start code.  Returning .annexB here causes
    ///   `convertAnnexBToLengthPrefixed` to treat `01` as the end of a 3-byte
    ///   start code, shifting the entire NAL payload by one byte and feeding
    ///   VideoToolbox a corrupt HEVC NAL header → visible distortion on every
    ///   frame in that size range (~260–510 B, typical of non-reference/skip
    ///   frames at low motion).
    ///
    ///   The full LP walk is the only reliable disambiguation.
    private static func detectNALFormat(_ b: [UInt8], nalUnitLength: Int) -> NALFormat {
        // Primary: exact LP validation — all bytes consumed by valid NAL units.
        if isValidLengthPrefixed(b, nalUnitLength: nalUnitLength) { return .lengthPrefixed }
        // Secondary: LP with 1–(nalUnitLength-1) trailing padding bytes.
        if looksLikeLPWithTrailingBytes(b, nalUnitLength: nalUnitLength) { return .lengthPrefixed }
        // Neither LP check passed → data is not length-prefixed; convert from Annex B.
        return .annexB
    }

    /// Returns true when `b` looks like a length-prefixed NAL stream with a small
    /// number of trailing padding/alignment bytes at the end.
    ///
    /// `isValidLengthPrefixed` requires `i == n` after the walk — it rejects buffers
    /// whose last valid NAL ends before byte `n`.  This companion check succeeds when:
    ///   • At least one complete LP NAL unit was parsed successfully, AND
    ///   • The remaining bytes after the last valid NAL are fewer than `nalUnitLength`
    ///     (i.e. not enough bytes to start another LP length field — they are padding,
    ///     not a truncated NAL).
    private static func looksLikeLPWithTrailingBytes(_ b: [UInt8], nalUnitLength: Int) -> Bool {
        var i = 0
        let n = b.count
        var lastValidEnd = 0
        while i < n {
            guard i + nalUnitLength <= n else { break }
            var len = 0
            for k in 0..<nalUnitLength { len = (len << 8) | Int(b[i + k]) }
            guard len > 0 else { break }
            let naluEnd = i + nalUnitLength + len
            guard naluEnd <= n else { break }
            lastValidEnd = naluEnd
            i = naluEnd
        }
        // At least one valid NAL found and the leftover is too small to be another NAL header.
        return lastValidEnd > 0 && (n - lastValidEnd) < nalUnitLength
    }

    // MARK: - LP trailing-byte trimmer

    /// Walk `b` as length-prefixed HEVC/AVC NAL units and return a `Data`
    /// slice that ends at the last complete NAL boundary, stripping any
    /// trailing padding bytes that follow.
    ///
    /// **Why this is needed:**
    /// `isValidLengthPrefixed` requires `i == n` after walking all NALs —
    /// it rejects buffers with trailing bytes.  Some MKV muxers append 1–3
    /// alignment/padding bytes after the last LP NAL unit (common with
    /// 4-byte block alignment).  When that strict check fails, `detectNALFormat`
    /// falls back to treating the buffer as Annex B and calls
    /// `convertAnnexBToLengthPrefixed`.  Since HEVC LP payloads use RBSP
    /// encoding (emulation-prevention bytes), there are no bare `00 00 01`
    /// start codes inside them — the conversion produces empty output, the
    /// sample is thrown as `.emptyPayload`, and the frame is silently dropped.
    /// Dropped reference frames cause the consistent per-frame corruption seen
    /// in Phase 3.
    ///
    /// - Returns: `original` unchanged when there are no trailing bytes
    ///   (no allocation).  Returns a trimmed prefix when 1–3 trailing bytes
    ///   are present, and logs the trim for diagnostic visibility.
    ///   Returns `original` if the walk produces zero valid NALs (corrupt data
    ///   — let downstream error handling deal with it rather than silently
    ///   truncating).
    private static func trimLPTrailingBytes(
        _ b:           [UInt8],
        nalUnitLength: Int,
        original:      Data
    ) -> Data {
        var i            = 0
        let n            = b.count
        var lastValidEnd = 0

        while i < n {
            guard i + nalUnitLength <= n else { break }
            var len = 0
            for k in 0..<nalUnitLength { len = (len << 8) | Int(b[i + k]) }
            guard len > 0 else { break }          // zero-length NAL → padding reached
            let naluEnd = i + nalUnitLength + len
            guard naluEnd <= n else { break }     // NAL overruns buffer → stop
            lastValidEnd = naluEnd
            i = naluEnd
        }

        // No valid NALs found at all — return original and let VT / error
        // handling surface the problem rather than truncating to 0 bytes.
        guard lastValidEnd > 0 else { return original }

        // All bytes consumed — no trailing bytes, nothing to trim.
        if lastValidEnd == n { return original }

        // Trailing bytes found: trim and log.
        let trailing = n - lastValidEnd
        feederLog("[LP-Trim] trailing bytes removed"
                + "  total=\(n)B  validLP=\(lastValidEnd)B  trailing=\(trailing)B"
                + "  (MKV alignment padding — harmless once trimmed)")
        return original.prefix(lastValidEnd)
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

        // Returns true if the NAL unit starting at `naluStart` in `b` should
        // be stripped as Dolby Vision–specific data.
        //
        // Two detection criteria:
        //   1. NAL type 62 (RPU) or 63 (EL wrapper) — explicit DV types.
        //   2. nuh_temporal_id_plus1 == 0 — illegal in HEVC (spec §7.4.2.2
        //      requires this field to be > 0), but DV encoders set it to 0
        //      on EL-wrapper and RPU NALs that use non-standard type IDs.
        //      VideoToolbox emits "nuh_temporal_id_plus1 == 0" and
        //      "PullNALU failed to get a valid NALU" for these.
        @inline(__always)
        func isDVNAL(_ naluStart: Int) -> Bool {
            guard naluStart + 1 < b.count else { return false }
            let nalType          = Int((b[naluStart] >> 1) & 0x3F)
            let temporalIdPlus1  = Int(b[naluStart + 1] & 0x07)
            return nalType == 62 || nalType == 63 || temporalIdPlus1 == 0
        }

        // First pass: check if there are any DV NALs at all (cheap early exit)
        var probe = 0
        while probe + nalUnitLength <= n {
            var len = 0
            for k in 0..<nalUnitLength { len = (len << 8) | Int(b[probe + k]) }
            guard len > 0 else { break }
            let naluStart = probe + nalUnitLength
            guard naluStart < n else { break }
            if isDVNAL(naluStart) { hadDV = true; break }
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
            if !isDVNAL(naluStart) {
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

    /// Extract the H.264 NAL unit header length from a CMVideoFormatDescription.
    /// Returns 4 if the query fails (covers virtually all real content).
    private static func avcNalUnitLength(from desc: CMVideoFormatDescription) -> Int {
        var nal: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
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

    /// Returns the H.264 NAL unit type name for a type number.
    private static func avcNALTypeName(_ t: Int) -> String {
        switch t {
        case  1: return "non-IDR slice"
        case  2: return "slice DPA"
        case  3: return "slice DPB"
        case  4: return "slice DPC"
        case  5: return "IDR slice ✅"
        case  6: return "SEI"
        case  7: return "SPS"
        case  8: return "PPS"
        case  9: return "AUD"
        case 10: return "end of seq"
        case 11: return "end of stream"
        case 12: return "filler"
        case 13: return "SPS_EXT"
        case 19: return "aux coded slice"
        default: return "type\(t)"
        }
    }

    /// Parse NAL unit types from length-prefixed bytes.
    /// Returns array of (nalType, sizeBytes) pairs.
    /// `sizeBytes` is the NAL payload size (NOT including the length prefix field).
    ///
    /// - Parameter isHEVC: When true, NAL type is extracted from the HEVC 2-byte
    ///   header `(byte0 >> 1) & 0x3F`.  When false (H.264), uses the 1-byte
    ///   header `byte0 & 0x1F`.
    private static func nalTypesFromLengthPrefixed(_ b: [UInt8], nalUnitLength: Int, isHEVC: Bool = true) -> [(type: Int, size: Int)] {
        var result: [(Int, Int)] = []
        var i = 0
        let n = b.count
        // Use <= (not <) so the final NAL whose length field starts at n-nalUnitLength is parsed.
        while i + nalUnitLength <= n {
            var len = 0
            for k in 0..<nalUnitLength { len = (len << 8) | Int(b[i + k]) }
            i += nalUnitLength
            guard len > 0, i + len <= n else { break }
            let nalType = isHEVC
                ? Int((b[i] >> 1) & 0x3F)   // HEVC: 6-bit type in bits [14:9] of 2-byte header
                : Int(b[i] & 0x1F)           // H.264: 5-bit type in bits [4:0] of 1-byte header
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
        isHEVC:        Bool,
        diagIdx:       Int
    ) {
        let codecTag = isHEVC ? "HEVC" : "H.264"
        let tag = "[SampleDiag #\(diagIdx) \(codecTag)]"

        // Basic info
        let dtsStr = packet.dts.isValid
            ? String(format: "%.3f", packet.dts.seconds) + "s"
            : "invalid"
        let dvStripped = isHEVC ? (normalized.count - stripped.count) : 0
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

        // Parse NAL types from the normalized (length-prefixed) data.
        // isHEVC controls whether the HEVC 2-byte or H.264 1-byte header is used.
        let nalList = nalTypesFromLengthPrefixed(normalized, nalUnitLength: nalUnitLength, isHEVC: isHEVC)
        feederLog("\(tag) NAL units found: \(nalList.count)")
        if nalList.isEmpty && normalized.count > nalUnitLength {
            // If the parse finds nothing in a non-empty buffer, the length field is probably
            // being misread — dump the raw 4-byte prefix so we can see what VT is getting
            let prefix8 = normalized.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            feederLog("\(tag) ⚠️  nalList empty — first8 of normalized: \(prefix8)  "
                    + "(if first 4 bytes look like a start code, Annex B detection missed)")
        }
        // Log each NAL: type, size, and first 8 bytes of NAL payload.
        // HEVC NAL header is 2 bytes; H.264 NAL header is 1 byte.
        let nalHeaderSize = isHEVC ? 2 : 1
        var nalCursor = nalUnitLength   // skip first length prefix to get to byte 0 of first NAL
        for (i, (t, sz)) in nalList.enumerated() {
            let naluStart    = nalCursor
            let payloadStart = naluStart + nalHeaderSize
            let payloadBytes = payloadStart < normalized.count
                ? normalized[payloadStart..<min(payloadStart + 8, normalized.count)]
                    .map { String(format: "%02X", $0) }.joined(separator: " ")
                : "—"
            let typeName = isHEVC ? hevcNALTypeName(t) : avcNALTypeName(t)
            feederLog("\(tag)   [\(i)] type=\(t) (\(typeName))  size=\(sz)B  "
                    + "payload[0..7]: \(payloadBytes)")
            nalCursor += sz + nalUnitLength   // advance past this NAL + next length prefix
        }

        if isHEVC {
            // HEVC: IDR = type 19 (IDR_W_RADL) or 20 (IDR_N_LP); CRA = 21
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
            // Dolby Vision detection (HEVC only)
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
        } else {
            // H.264: IDR = type 5; SPS = 7; PPS = 8
            let isIDR  = nalList.contains { $0.type == 5 }
            let hasSPS = nalList.contains { $0.type == 7 }
            let hasPPS = nalList.contains { $0.type == 8 }
            feederLog("\(tag) IDR=\(isIDR ? "✅" : "❌")  "
                    + "SPS=\(hasSPS ? "✅" : "—")  PPS=\(hasPPS ? "✅" : "—")")
            if packet.isKeyframe && !isIDR {
                feederLog("\(tag) ⚠️  MKV marks this as keyframe but no IDR NAL (type 5) found — "
                        + "VT may need prior state")
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
