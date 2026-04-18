// MARK: - PlayerLab / Render / PlayerLabPlaybackController
//
// Sprint 10  — Frame Rendering Proof
// Sprint 11  — Timed Presentation / Playback Clock
// Sprint 12  — HEVC path
// Sprint 13  — AAC audio via AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer
// Sprint 14  — Seek, restart, duration / currentTime tracking
// Sprint 15  — Controlled app integration (feature flag)
// Sprint 16  — Incremental packet pipeline: initial window only, cursor-based streaming
// Sprint 17  — Rolling feed loop: background Task refills queues on low-watermark trigger
// Sprint 18  — Index-based seek: reset cursors → flush → re-feed window → re-anchor clock
// Sprint 18.5 — Zero-freeze seek: pre-fetch window before flush (fetch → flush → enqueue → clock)
// Sprint 19  — Buffering state: underrun detection, pipeline pause, auto-recovery
// Sprint 22  — MKV AAC audio extraction (CodecPrivate = raw AudioSpecificConfig)
// Sprint 23  — MKV audio track model: structured logging of available tracks, default selection
// Sprint 24  — AC3 / EAC3 audio format descriptions + fallback logic
// Sprint 25  — Audio track switching (restart-based) + AudioPreferencePolicy wiring
// Sprint 26  — Subtitle integration: PlayerLabSubtitleController, time-tracking cue updates
// Sprint 27  — Chapter parsing, seekToChapter(), onPlaybackEnded() transport polish
//
// Architecture (Sprints 16–19):
//   prepare()  → parse metadata + load initial window (3 s) → .ready
//   play()     → start synchronizer + feed loop + time-tracking loop
//   Feed loop  → polls every 100 ms:
//                  playing   → normal low-watermark refill
//                  buffering → aggressive refill until resumeThreshold, then resume
//   seek()     → find keyframe idx → PRE-FETCH new window (IO done here)
//              → flush renderers → enqueue pre-fetched frames (no IO gap) → re-anchor clock
//
// feedWindow() is now split into two phases:
//   fetchPackets(...)      — async IO only; returns FetchResult (CMSampleBuffers in memory)
//   enqueueAndAdvance(_:)  — synchronous enqueue + cursor update; no IO
//
// All packet IO is done via extractVideoPackets(from:count:) and
// extractAudioPackets(count:from:) on the retained MP4Demuxer.
// No full packet arrays are stored in memory between calls.
//
// Sprint 25 audio switching:  switchAudioTrack(to:) stores trackNumber, re-runs prepare()
//   at the saved playhead position, then resumes if previously playing.
//   MKVDemuxer.setPreferredAudioTrack / setAudioPolicy are called before parse().
//
// Sprint 26 subtitle flow:  subtitleController (PlayerLabSubtitleController) is populated
//   from mkv.availableSubtitleTracks / subtitleCues after parse().
//   The time-tracking loop calls subtitleController.update(forTime:) every 250 ms.
//
// NOT production-ready. Debug / lab use only.

import Foundation
import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreMedia
import VideoToolbox
import UIKit   // AVAudioSession

// MARK: - Errors

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

// MARK: - PlayerLabPlaybackController

@MainActor
final class PlayerLabPlaybackController: ObservableObject {

    // MARK: - State

    enum State: Equatable {
        case idle
        case loading
        case ready
        case playing
        /// Sprint 19: pipeline stalled due to buffer underrun; feed loop is
        /// aggressively refilling; synchronizer clock is paused at current position.
        case buffering
        case paused
        case ended
        case failed(String)

        static func == (l: State, r: State) -> Bool {
            switch (l, r) {
            case (.idle, .idle), (.loading, .loading), (.ready, .ready),
                 (.playing, .playing), (.buffering, .buffering),
                 (.paused, .paused), (.ended, .ended): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }

        var statusLabel: String {
            switch self {
            case .idle:          return "Idle"
            case .loading:       return "Loading…"
            case .ready:         return "Ready"
            case .playing:       return "▶ Playing"
            case .buffering:     return "⏳ Buffering…"
            case .paused:        return "⏸ Paused"
            case .ended:         return "Ended"
            case .failed(let m): return "❌ \(m)"
            }
        }

        var canPlay:  Bool { switch self { case .ready, .paused: return true; default: return false } }
        /// User can pause even while buffering — feed loop stops, state → .paused.
        var canPause: Bool { switch self { case .playing, .buffering: return true; default: return false } }
        var canSeek:  Bool { switch self { case .playing, .buffering, .paused, .ready: return true; default: return false } }
    }

    // MARK: - Published

    @Published private(set) var state:          State        = .idle
    @Published private(set) var log:            [String]     = []
    @Published private(set) var firstFrameSize: CGSize       = .zero
    @Published private(set) var framesLoaded:   Int          = 0      // video samples fed so far
    @Published private(set) var detectedCodec:  String       = "—"
    @Published private(set) var hasAudio:       Bool         = false
    @Published private(set) var duration:       TimeInterval = 0
    @Published private(set) var currentTime:    TimeInterval = 0
    /// Seconds of video ahead of the current playhead (Sprint 17: live buffer depth).
    @Published private(set) var videoBuffered:  Double       = 0
    @Published private(set) var audioBuffered:  Double       = 0

    // Sprint 25: available MKV audio tracks + currently selected track
    @Published private(set) var availableAudioTracks: [MKVAudioTrackDescriptor] = []
    @Published private(set) var selectedAudioTrack:   MKVAudioTrackDescriptor?  = nil

    // Sprint 27: chapter list populated after parse
    @Published private(set) var chapters: [ChapterInfo] = []

    // MARK: - Renderer

    let renderer = FrameRenderer()

    // MARK: - Demuxers (retained for incremental reads — Sprint 16 / Sprint 21)
    //
    // Exactly one of these is non-nil after a successful prepare().
    // Sprint 21 adds MKV routing: prepare() inspects the file extension and
    // selects the appropriate demuxer.  All packet extraction goes through the
    // typed helpers below so the feed loop stays container-agnostic.

    private var demuxer:    MP4Demuxer?    // MP4 / MOV
    private var mkvDemuxer: MKVDemuxer?   // Sprint 21: MKV / WebM

    /// Published so the HUD can show "MKV" vs "MP4" container.
    @Published private(set) var detectedContainer: String = "—"

    // MARK: - Sprint 25: Audio preference state

    /// URL of the most recently prepared file; used by switchAudioTrack() to re-prepare.
    private var currentURL: URL? = nil

    /// Policy forwarded to MKVDemuxer before parse().  Default: compatibility mode.
    var audioPreferences: AudioPreferencePolicy = .default

    /// Explicit track override set by switchAudioTrack().  nil = rely on policy.
    private var requestedAudioTrackNumber: UInt64? = nil

    // MARK: - Sprint 26: Subtitle controller

    /// Cue-timing controller.  Updated every 250 ms by the time-tracking loop.
    let subtitleController = PlayerLabSubtitleController()

    // MARK: - Format descriptions

    private var videoFormatDesc: CMVideoFormatDescription?
    private var audioFormatDesc: CMAudioFormatDescription?

    // MARK: - Streaming state (Sprint 16)

    private var startPTS:             CMTime = .zero

    /// 0-based index of the next video sample to read from the demuxer.
    private var nextVideoSampleIdx:   Int    = 0
    /// 0-based index of the next audio sample to read from the demuxer.
    private var nextAudioSampleIdx:   Int    = 0
    /// Total samples in the video track (from parsed metadata).
    private var videoSamplesTotal:    Int    = 0
    /// Total samples in the audio track (from parsed metadata).
    private var audioSamplesTotal:    Int    = 0

    /// PTS (seconds) of the last video sample enqueued to the renderer.
    /// Used to compute buffer depth: depth = lastEnqueuedVideoPTS − currentTime.
    private var lastEnqueuedVideoPTS: Double = 0
    private var lastEnqueuedAudioPTS: Double = 0

    /// Lower bound for the current-time reading used in buffer depth calculations.
    ///
    /// After a seek, CMTimebaseGetTime(synchronizer.timebase) can transiently
    /// return the PRE-seek time even though the synchronizer has already jumped
    /// its internal clock (the display layer shows the right frame, but the
    /// timebase reference visible to the CPU hasn't refreshed yet).
    ///
    /// If we naively compute buffered = lastEnqueuedVideoPTS − staleTime, we
    /// get an inflated value (e.g. 35 − 3 = 32 s when the real buffer is 3 s),
    /// and the feed loop stops refilling for ~30 real seconds while the clock
    /// slowly "catches up."
    ///
    /// Fix: clamp nowSec with this floor so a stale timebase cannot inflate the
    /// perceived buffer depth.  The floor is set to keyframePTS on every seek
    /// and becomes irrelevant once renderer.currentTime naturally surpasses it.
    private var currentTimeFloor: Double = 0

    // MARK: - Buffer config (Sprint 16/17/19)

    /// Seconds of media loaded before play() is called.
    private let initialWindowSeconds: Double = 3.0
    /// Target buffer to maintain ahead of playhead during playback.
    private let targetBufferSeconds:  Double = 8.0
    /// Refill trigger (Sprint 17): refill when buffer drops below this.
    private let lowWatermarkSeconds:  Double = 2.0
    /// Chunk size requested per feed cycle.
    private let feedChunkSeconds:     Double = 2.0
    /// Sprint 19 — buffer depth that triggers .buffering (synchronizer pause).
    private let underrunThreshold:    Double = 0.5
    /// Sprint 19 — buffer depth required to leave .buffering and resume playback.
    private let resumeThreshold:      Double = 1.5

    // MARK: - Background tasks

    private var feedTask: Task<Void, Never>?
    private var timeTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        renderer.onFirstFrame = { [weak self] size in
            self?.firstFrameSize = size
        }
    }

    // MARK: - Prepare  (Sprint 16)
    //
    // Sprints 16–18 architecture change:
    //   OLD: extract ALL packets → build ALL CMSampleBuffers → enqueue ALL → .ready
    //   NEW: parse metadata → load initial window (3 s) → .ready
    //        remaining packets are loaded by the feed loop during playback.
    //
    // The MP4Demuxer is stored as self.demuxer for the lifetime of the session.

    func prepare(url: URL) async {
        state = .loading
        log   = []

        // Reset streaming cursors
        demuxer              = nil
        mkvDemuxer           = nil
        detectedContainer    = "—"
        nextVideoSampleIdx   = 0
        nextAudioSampleIdx   = 0
        videoSamplesTotal    = 0
        audioSamplesTotal    = 0
        lastEnqueuedVideoPTS = 0
        lastEnqueuedAudioPTS = 0
        currentTimeFloor     = 0
        videoFormatDesc      = nil
        audioFormatDesc      = nil
        hasAudio             = false
        framesLoaded         = 0
        videoBuffered        = 0
        audioBuffered        = 0

        // Sprint 25/26/27: reset track / subtitle / chapter state
        // If this is a completely new URL, discard any per-file audio preference.
        if url != currentURL { requestedAudioTrackNumber = nil }
        currentURL          = url
        availableAudioTracks = []
        selectedAudioTrack   = nil
        chapters             = []
        subtitleController.reset()

        renderer.flushAll()
        stopFeedLoop()
        stopTimeTracking()

        record("[prepare] \(url.lastPathComponent)")

        // ── Step 1: Open ──────────────────────────────────────────────────────

        record("[1] Opening MediaReader…")
        let reader = MediaReader(url: url)
        do {
            try await reader.open()
            record("  ✅ Opened — \(formatBytes(reader.contentLength))")
        } catch {
            fail("Open failed: \(error.localizedDescription)"); return
        }

        // ── Step 2: Route to correct demuxer (Sprint 21) ─────────────────────
        //
        // Routing rules:
        //   .mkv / .webm  → MKVDemuxer (Sprint 20)
        //   everything else → MP4Demuxer (existing path)
        //
        // If MKV parsing fails or yields an unsupported codec, we fail rather
        // than falling back (PlayerLabPlayerView is debug-only; AVPlayer handles
        // production).  The routing decision is logged so it's visible in the
        // Xcode console.

        let isMKV = ["mkv", "webm"].contains(url.pathExtension.lowercased())

        if isMKV {
            record("[Routing] MKV detected → MKVDemuxer")
        } else {
            record("[Routing] \(url.pathExtension.uppercased()) detected → MP4Demuxer")
        }

        let videoTrack: TrackInfo

        if isMKV {
            // ── MKV path ────────────────────────────────────────────────────────
            record("[2] Parsing MKV (EBML)…")
            let mkv = MKVDemuxer(reader: reader)

            // Sprint 25: wire audio preferences before parse so demuxer selects the right track
            mkv.setPreferredAudioTrack(trackNumber: requestedAudioTrackNumber)
            mkv.setAudioPolicy(audioPreferences)

            do {
                try await mkv.parse()
                record("  ✅ MKV parsed — \(mkv.tracks.count) track(s)  "
                     + "\(mkv.videoTrack?.sampleCount ?? 0) video frames")
            } catch {
                fail("[Routing] MKV parse failed: \(error.localizedDescription)"); return
            }
            guard let vt = mkv.videoTrack else {
                fail("[Routing] No supported video track in MKV"); return
            }
            let codec = vt.codecFourCC ?? "?"
            guard vt.isH264 || vt.isHEVC else {
                fail("[Routing] Unsupported MKV video codec '\(codec)' — fallback to AVPlayer"); return
            }
            mkvDemuxer        = mkv
            detectedContainer = "MKV"
            videoTrack = vt

            // Sprint 23 / 25: log all discovered audio tracks + publish selected track
            if !mkv.availableAudioTracks.isEmpty {
                record("[Audio] \(mkv.availableAudioTracks.count) track(s) found:")
                for t in mkv.availableAudioTracks {
                    let supportMark = t.isSupported ? "✅" : "⚠️ unsupported"
                    let defMark     = t.isDefault ? " [default]" : ""
                    record("  track \(t.trackNumber): \(t.codecID)  "
                         + "ch=\(t.channelCount)  sr=\(Int(t.sampleRate)) Hz  "
                         + "lang=\(t.language)\(defMark)  \(supportMark)")
                }
                availableAudioTracks = mkv.availableAudioTracks
                if let selNum = mkv.selectedAudioTrackNumber {
                    selectedAudioTrack = mkv.availableAudioTracks.first { $0.trackNumber == selNum }
                    record("  → Selected: track \(selNum)  (\(selectedAudioTrack?.codecID ?? "?"))")
                } else {
                    record("  → No supported audio track — video only")
                }
            } else {
                record("  ℹ️ No audio tracks in MKV")
            }

            // Sprint 26: populate subtitle controller
            subtitleController.setAvailableTracks(mkv.availableSubtitleTracks)
            if let subTrack = mkv.selectedSubtitleTrack, !mkv.subtitleCues.isEmpty {
                subtitleController.loadCues(mkv.subtitleCues, for: subTrack)
                record("[Subtitle] \(mkv.subtitleCues.count) cue(s) loaded "
                     + "for '\(subTrack.displayLabel)'")
            } else if !mkv.availableSubtitleTracks.isEmpty {
                record("[Subtitle] \(mkv.availableSubtitleTracks.count) track(s) found "
                     + "but none SRT-compatible — subtitles off")
            }

            // Sprint 27: chapters
            chapters = mkv.chapters
            if !mkv.chapters.isEmpty {
                record("[Chapters] \(mkv.chapters.count) chapter(s) loaded")
            }

        } else {
            // ── MP4 / MOV path ──────────────────────────────────────────────────
            record("[2] Parsing MP4 box tree…")
            let dmx = MP4Demuxer(reader: reader)
            do {
                try await dmx.parse()
                record("  ✅ Parsed — \(dmx.tracks.count) tracks found")
            } catch {
                fail("Parse failed: \(error.localizedDescription)"); return
            }
            guard let vt = dmx.videoTrack else {
                fail("No video track found"); return
            }
            demuxer           = dmx
            detectedContainer = "MP4"
            videoTrack = vt
        }

        // ── Step 3: Identify video track ──────────────────────────────────────
        //
        // videoTrack is set by whichever path ran above.
        let fourCC       = videoTrack.codecFourCC ?? "?"
        detectedCodec    = fourCC
        let durationSec  = videoTrack.durationSeconds
        duration         = durationSec
        videoSamplesTotal = videoTrack.sampleCount
        record("  codec=\(fourCC)  "
             + "\(videoTrack.displayWidth ?? 0)×\(videoTrack.displayHeight ?? 0)  "
             + "\(videoTrack.sampleCount) samples  "
             + "\(String(format: "%.2f", durationSec))s")

        // ── Step 4: Build CMVideoFormatDescription ────────────────────────────

        record("[4] Building CMVideoFormatDescription (\(fourCC))…")
        do {
            if videoTrack.isH264 {
                guard let avcC = videoTrack.avcCData else {
                    fail("H.264 track has no avcC data"); return
                }
                videoFormatDesc = try H264Decoder.makeFormatDescription(from: avcC)
                record("  ✅ H.264 format description (avcC \(avcC.count) bytes)")
            } else if videoTrack.isHEVC {
                guard let hvcC = videoTrack.hvcCData else {
                    fail("HEVC track has no hvcC data"); return
                }
                videoFormatDesc = try HEVCDecoder.makeFormatDescription(from: hvcC)
                record("  ✅ HEVC format description (hvcC \(hvcC.count) bytes)")
            } else {
                fail("Unsupported video codec: \(fourCC)"); return
            }
        } catch {
            fail("Format description failed: \(error.localizedDescription)"); return
        }

        // ── Step 4b: Build CMAudioFormatDescription ───────────────────────────
        //
        // Sprint 22: MKV AAC — CodecPrivate IS the raw AudioSpecificConfig (no esds wrapper).
        // Sprint 24: MKV AC3/EAC3 — self-framing; no magic cookie needed.
        // Sprint 24: fallback priority inside MKV: AAC > AC3 > EAC3 (handled by MKVDemuxer).

        if let mkv = mkvDemuxer,
           let audioTrack = mkv.audioTrack,
           let ch = audioTrack.channelCount,
           let sr = audioTrack.audioSampleRate {

            record("[4b] Building CMAudioFormatDescription (MKV \(audioTrack.codecFourCC ?? "?"))…")
            var fmtDesc: CMAudioFormatDescription? = nil

            if audioTrack.isAAC, let asc = mkv.audioCodecPrivate {
                // Sprint 22: use raw AudioSpecificConfig bytes directly as magic cookie
                fmtDesc = makeMKVAudioFormatDescription(audioSpecificConfig: asc,
                                                         channelCount: ch,
                                                         sampleRate: sr)
            } else if audioTrack.codecFourCC == "ac-3" || audioTrack.codecFourCC == "ec-3" {
                // Sprint 24: AC3 / EAC3 — no magic cookie
                let isEAC3 = audioTrack.codecFourCC == "ec-3"
                fmtDesc = makeAC3AudioFormatDescription(channelCount: ch,
                                                         sampleRate: sr,
                                                         isEAC3: isEAC3)
            }

            if let fmtDesc {
                audioFormatDesc   = fmtDesc
                hasAudio          = true
                audioSamplesTotal = audioTrack.sampleCount
                record("  ✅ Audio format description  "
                     + "ch=\(ch) sr=\(Int(sr)) Hz  \(audioTrack.sampleCount) samples")
            } else {
                record("  ⚠️ Audio format description failed — video only")
            }

        } else if let mp4 = demuxer,
                  let audioTrack = mp4.audioTrack, audioTrack.isAAC,
                  let esds = audioTrack.esdsData,
                  let ch   = audioTrack.channelCount,
                  let sr   = audioTrack.audioSampleRate {
            record("[4b] Building CMAudioFormatDescription (MP4 AAC)…")
            if let fmtDesc = makeAudioFormatDescription(esdsPayload: esds,
                                                        channelCount: ch,
                                                        sampleRate: sr) {
                audioFormatDesc   = fmtDesc
                hasAudio          = true
                audioSamplesTotal = audioTrack.sampleCount
                record("  ✅ AAC format description (ch=\(ch) sr=\(Int(sr)) Hz  "
                     + "\(audioTrack.sampleCount) samples)")
            } else {
                record("  ⚠️ AAC format description failed — audio will be silent")
            }
        } else if demuxer?.audioTrack == nil && mkvDemuxer?.audioTrack == nil {
            record("  ℹ️ No audio track in this file")
        } else {
            record("  ⚠️ Audio track found but codec unsupported — video only")
        }

        // ── Step 5: Load initial window only (Sprint 16) ─────────────────────
        //
        // OLD: extract ALL N packets at once
        // NEW: extract only initialWindowSeconds worth — feed loop handles the rest
        //
        // Activate AVAudioSession here, before the first audio buffer is enqueued.
        // If we wait until play(), AVSampleBufferAudioRenderer tries to initialise
        // the codec on the very first enqueue and logs "AudioCodecInitialize failed"
        // because no active audio session exists yet.
        if hasAudio { activateAudioSession() }

        let initVideoCount = videoSamplesFor(seconds: initialWindowSeconds)
        record("[5] Loading initial window (\(Int(initialWindowSeconds))s "
             + "≈ \(initVideoCount) video / \(audioSamplesFor(seconds: initialWindowSeconds)) audio samples)…")

        let loaded = await feedWindow(videoCount: initVideoCount,
                                      audioSeconds: initialWindowSeconds,
                                      label: "initial")
        guard loaded > 0 else {
            fail("No video packets in initial window"); return
        }

        // Anchor startPTS from first enqueued frame
        startPTS = renderer.firstFramePTS.isValid ? renderer.firstFramePTS : .zero
        record("  startPTS=\(String(format: "%.4f", startPTS.seconds))s  "
             + "buffered≈\(String(format: "%.1f", lastEnqueuedVideoPTS - startPTS.seconds))s  "
             + "v_idx=\(nextVideoSampleIdx)/\(videoSamplesTotal)")

        state = .ready
        record("✅ Ready — initial window loaded, feed loop will handle the rest")
    }

    // MARK: - Transport

    func play() {
        switch state {
        case .ready:
            renderer.play(from: startPTS)
            state = .playing
            startFeedLoop()
            startTimeTracking()
            record("▶ play() — synchronizer at PTS=\(String(format: "%.4f", startPTS.seconds))s")
        case .paused:
            renderer.resume()
            state = .playing
            startFeedLoop()       // resume feeding (Sprint 17)
            startTimeTracking()
            record("▶ resume() — feed loop restarted")
        default:
            break
        }
    }

    func pause() {
        guard state.canPause else { return }
        // If buffering, synchronizer is already rate=0; renderer.pause() is harmless.
        renderer.pause()
        stopFeedLoop()
        state = .paused
        stopTimeTracking()
        record("⏸ pause() — feed loop stopped, queues preserved")
    }

    func stop() {
        renderer.flushAll()
        stopFeedLoop()
        stopTimeTracking()
        demuxer            = nil
        mkvDemuxer         = nil
        detectedContainer  = "—"
        state              = .idle
        framesLoaded       = 0
        hasAudio           = false
        detectedCodec      = "—"
        firstFrameSize     = .zero
        currentTime        = 0
        videoBuffered      = 0
        audioBuffered      = 0
        currentTimeFloor   = 0
        // Sprint 25/26/27
        availableAudioTracks    = []
        selectedAudioTrack      = nil
        requestedAudioTrackNumber = nil
        chapters                = []
        subtitleController.reset()
        record("⏹ stop() — renderer + feed loop cleared")
    }

    // MARK: - Seek  (Sprint 18 / 18.5)
    //
    // Sprint 18:  cursor-based seek (replace packet-array rebuild).
    // Sprint 18.5: zero-freeze improvement — pre-fetch the new window BEFORE
    //              flushing the renderer, so the display gap between flush and
    //              first new frame is near-zero (memory ops only, no IO).
    //
    // Four-phase sequence:
    //   Phase 1 — FETCH:  async IO to load new window into memory (FetchResult)
    //   Phase 2 — FLUSH:  clear both renderer queues (display freezes here,
    //                     but only for the time it takes to do Phase 3 — µs)
    //   Phase 3 — ENQUEUE: push pre-fetched CMSampleBuffers to renderers; reset cursors
    //   Phase 4 — CLOCK:  re-anchor synchronizer at keyframe PTS, restart feed loop

    func seek(toFraction fraction: Double) async {
        guard state.canSeek else { return }
        guard demuxer != nil || mkvDemuxer != nil else { return }

        let clampedFraction = max(0, min(1, fraction))
        let targetSeconds   = clampedFraction * duration
        let targetPTS       = CMTime(seconds: targetSeconds, preferredTimescale: 90_000)

        record("[seek] → \(String(format: "%.2f", targetSeconds))s "
             + "(\(Int(clampedFraction * 100))% of \(String(format: "%.0f", duration))s)")

        // Find nearest video keyframe — dispatch to active demuxer (Sprint 21)
        let keyframeIdx: Int
        let keyframePTS: CMTime
        let audioIdx:    Int
        if let mkv = mkvDemuxer {
            keyframeIdx = mkv.findVideoKeyframeSampleIndex(nearestBeforePTS: targetPTS)
            keyframePTS = mkv.videoPTS(forSample: keyframeIdx)
            audioIdx    = mkv.findAudioSampleIndex(nearestBeforePTS: keyframePTS)  // Sprint 22
        } else if let mp4 = demuxer {
            keyframeIdx = mp4.findVideoKeyframeSampleIndex(nearestBeforePTS: targetPTS)
            keyframePTS = mp4.videoPTS(forSample: keyframeIdx)
            audioIdx    = mp4.findAudioSampleIndex(nearestBeforePTS: keyframePTS)
        } else { return }

        record("  keyframe[\(keyframeIdx)] @ \(String(format: "%.4f", keyframePTS.seconds))s  "
             + "audio_idx=\(audioIdx)")

        // Treat .buffering as "was playing" — seek should resume afterwards.
        let wasPlaying = (state == .playing || state == .buffering)
        stopFeedLoop()

        // ── Phase 1: PRE-FETCH (async IO happens here, before any flush) ─────
        //
        // By doing IO now — while the old frames are still displayed — the
        // time between flush and first new frame is reduced to memory ops only.
        record("  [seek] pre-fetching \(String(format: "%.0f", initialWindowSeconds))s window…")
        let initVideoCount = videoSamplesFor(seconds: initialWindowSeconds)
        let fetched = await fetchPackets(videoCount: initVideoCount,
                                         audioSeconds: initialWindowSeconds,
                                         fromVideoIdx: keyframeIdx,
                                         fromAudioIdx: audioIdx,
                                         label: "seek")
        record("  [seek] fetch done — \(fetched.videoBuffers.count)v / \(fetched.audioBuffers.count)a ready")

        // ── Phase 2: FLUSH (display gap starts here — lasts only µs) ─────────
        //
        // flushForSeek() pauses the synchronizer (rate=0) THEN calls
        // flushAndRemoveImage() so the pipeline is fully quiescent before we
        // start enqueueing.  This prevents a race where background AVFoundation
        // queues process the flush AFTER our new frames are already enqueued,
        // discarding them and leaving the display layer empty.
        renderer.flushForSeek()

        // ── Phase 3: RESET CURSORS + ENQUEUE (no IO — gap ends here) ─────────
        nextVideoSampleIdx   = keyframeIdx
        nextAudioSampleIdx   = audioIdx
        lastEnqueuedVideoPTS = keyframePTS.seconds
        lastEnqueuedAudioPTS = keyframePTS.seconds

        // Set the time floor BEFORE enqueueAndAdvance so the feed loop never
        // sees a nowSec below keyframePTS even if the timebase is briefly stale.
        currentTimeFloor = keyframePTS.seconds

        let loaded = enqueueAndAdvance(fetched)
        record("  [seek] \(loaded) video packets enqueued  "
             + "buffered≈\(String(format: "%.1f", lastEnqueuedVideoPTS - keyframePTS.seconds))s")

        // ── Phase 4: CLOCK — re-anchor synchronizer at keyframe PTS ──────────
        //
        // setRate(_:time:) both jumps the media clock to keyframePTS AND
        // restores the desired playback rate (1 = playing, 0 = paused).
        // The synchronizer was paused in Phase 2; this is what restarts it.
        renderer.synchronizer.setRate(wasPlaying ? 1 : 0, time: keyframePTS)
        record("  [seek] clock anchored @ \(String(format: "%.4f", keyframePTS.seconds))s  "
             + "rate=\(wasPlaying ? 1 : 0)  floor=\(String(format: "%.4f", currentTimeFloor))s")

        if wasPlaying {
            startFeedLoop()
            record("  [seek] feed loop restarted")
        }
    }

    func restart() async {
        let wasPlaying = (state == .playing || state == .ended)
        await seek(toFraction: 0)
        // If ended or paused, force play after seek-to-0
        if wasPlaying, state != .playing {
            renderer.synchronizer.setRate(1, time: startPTS)
            state = .playing
            startFeedLoop()
            startTimeTracking()
        }
        record("⏮ restart()")
    }

    // MARK: - Feed Loop  (Sprint 17)
    //
    // Background Task that wakes every 100 ms and checks whether the video
    // buffer depth has fallen below the low-watermark threshold.  When it
    // does, feedWindow() is called to load another chunk from the demuxer.
    //
    // The loop is started by play() / resume(), stopped by pause() / stop() / seek().
    // It does not block the main thread — feedWindow() is async and suspends
    // naturally between packet reads.

    private func startFeedLoop() {
        stopFeedLoop()
        feedTask = Task { [weak self] in
            var logCycle = 0
            while !Task.isCancelled {
                guard let self else { break }
                await self.feedIfNeeded(logCycle: logCycle)
                logCycle += 1
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
            }
        }
        record("[feed] loop started")
    }

    private func stopFeedLoop() {
        feedTask?.cancel()
        feedTask = nil
    }

    private func feedIfNeeded(logCycle: Int) async {
        guard state == .playing || state == .buffering else { return }

        // Clamp with currentTimeFloor to guard against a transiently stale
        // timebase reading immediately after a seek (Sprint 18.5 fix).
        let rawTime   = renderer.currentTime.seconds
        let nowSec    = rawTime.isNaN ? currentTimeFloor : max(rawTime, currentTimeFloor)
        let buffered  = max(0, lastEnqueuedVideoPTS - nowSec)
        videoBuffered = buffered
        audioBuffered = max(0, lastEnqueuedAudioPTS - nowSec)

        // Log queue depth every 10 cycles (~1 s)
        if logCycle % 10 == 0 {
            record("[feed] t=\(String(format: "%.1f", nowSec))s  "
                 + "buf=\(String(format: "%.1f", buffered))s  "
                 + "v=\(nextVideoSampleIdx)/\(videoSamplesTotal)  "
                 + "a=\(nextAudioSampleIdx)/\(audioSamplesTotal)  "
                 + "[\(state.statusLabel)]")
        }

        // End-of-stream: all samples fed, wait for buffer to drain
        if nextVideoSampleIdx >= videoSamplesTotal {
            if buffered < 0.5 { onPlaybackEnded() }
            return
        }

        // ── Sprint 19: Underrun detection ─────────────────────────────────────
        //
        // When buffer drops below underrunThreshold while playing, pause the
        // synchronizer and enter .buffering.  The feed loop then refills
        // aggressively until resumeThreshold is reached.

        if state == .playing && buffered < underrunThreshold {
            state = .buffering
            renderer.synchronizer.rate = 0     // freeze clock, keep position
            record("[Buffer] video=\(String(format: "%.2f", buffered))s  "
                 + "audio=\(String(format: "%.2f", audioBuffered))s → ENTER BUFFERING")
        }

        if state == .buffering {
            // Aggressive fill: always top up to target regardless of watermark.
            let toFill     = targetBufferSeconds - buffered
            let videoCount = videoSamplesFor(seconds: max(toFill, feedChunkSeconds))
            if logCycle % 5 == 0 {
                record("[Buffer] refilling \(String(format: "%.1f", toFill))s "
                     + "≈ \(videoCount) samples…")
            }
            await feedWindow(videoCount: videoCount,
                             audioSeconds: max(toFill, feedChunkSeconds),
                             label: "buf-refill")

            // Re-sample buffer depth after refill
            let rawTime2  = renderer.currentTime.seconds
            let nowSec2   = rawTime2.isNaN ? currentTimeFloor : max(rawTime2, currentTimeFloor)
            let newBuf    = max(0, lastEnqueuedVideoPTS - nowSec2)
            videoBuffered = newBuf

            if newBuf >= resumeThreshold {
                state = .playing
                // Resume clock at current media position (rate 1, time unchanged).
                renderer.synchronizer.setRate(1, time: renderer.currentTime)
                record("[Buffer] video=\(String(format: "%.2f", newBuf))s → RESUME PLAYBACK")
            }
            return
        }

        // ── Normal low-watermark refill (Sprint 17) ───────────────────────────

        guard buffered < lowWatermarkSeconds else { return }

        let toFill     = targetBufferSeconds - buffered
        let videoCount = videoSamplesFor(seconds: toFill)
        record("[feed] ⚠️ low watermark (\(String(format: "%.1f", buffered))s < \(lowWatermarkSeconds)s) "
             + "— refilling \(String(format: "%.1f", toFill))s ≈\(videoCount) samples")

        await feedWindow(videoCount: videoCount,
                         audioSeconds: toFill,
                         label: "refill")
    }

    // MARK: - FetchResult  (Sprint 18.5)
    //
    // Plain value type holding pre-built CMSampleBuffers ready for enqueue.
    // Produced by fetchPackets(), consumed by enqueueAndAdvance().
    // Splitting the old feedWindow() into these two phases lets seek()
    // do IO before flushing the renderer, collapsing the display gap to µs.

    private struct FetchResult {
        /// Video sample buffers paired with their PTS (seconds) for tracking.
        var videoBuffers: [(buffer: CMSampleBuffer, pts: Double)] = []
        /// Audio sample buffers in presentation order.
        var audioBuffers: [CMSampleBuffer] = []
        /// PTS of the last video sample (used to update lastEnqueuedVideoPTS).
        var lastVideoPTS: Double = 0
        /// PTS of the last audio sample (used to update lastEnqueuedAudioPTS).
        var lastAudioPTS: Double = 0
        /// Log label forwarded to enqueueAndAdvance for consistent log output.
        let label: String
    }

    // MARK: - fetchPackets  (Sprint 18.5 — Phase 1 of the split)
    //
    // Pure IO: reads packets from the demuxer, builds CMSampleBuffers into
    // memory, and returns them as a FetchResult.
    // Has NO side effects on cursors, renderer, or any published state.
    // Safe to call before flushing the renderer.

    private func fetchPackets(videoCount:    Int,
                              audioSeconds:  Double,
                              fromVideoIdx:  Int,
                              fromAudioIdx:  Int,
                              label:         String) async -> FetchResult {
        var result = FetchResult(label: label)
        guard let vFmt = videoFormatDesc else { return result }

        let limitedVideo = min(videoCount, videoSamplesTotal - fromVideoIdx)
        guard limitedVideo > 0 else { return result }

        // ── Video — dispatch to active demuxer (Sprint 21) ─────────────────────

        do {
            let packets: [DemuxPacket]
            if let mkv = mkvDemuxer {
                packets = try await mkv.extractVideoPackets(from: fromVideoIdx, count: limitedVideo)
            } else if let mp4 = demuxer {
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
            record("  ⚠️ [\(label)] video fetch failed: \(error.localizedDescription)")
        }

        // ── Audio — dispatch to active demuxer (Sprint 22) ───────────────────

        if hasAudio, let aFmt = audioFormatDesc {
            let limitedAudio = min(audioSamplesFor(seconds: audioSeconds),
                                   audioSamplesTotal - fromAudioIdx)
            if limitedAudio > 0 {
                do {
                    let packets: [DemuxPacket]
                    if let mkv = mkvDemuxer {
                        packets = try await mkv.extractAudioPackets(from: fromAudioIdx,
                                                                     count: limitedAudio)
                    } else if let mp4 = demuxer {
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
                    record("  ⚠️ [\(label)] audio fetch failed: \(error.localizedDescription)")
                }
            }
        }

        return result
    }

    // MARK: - enqueueAndAdvance  (Sprint 18.5 — Phase 2 of the split)
    //
    // Pure enqueue: pushes pre-built CMSampleBuffers to the renderer and
    // advances the streaming cursors.  No IO.  Safe to call immediately
    // after flushing the renderer.
    //
    // Returns the number of video packets enqueued.

    @discardableResult
    private func enqueueAndAdvance(_ result: FetchResult) -> Int {
        let vCount = result.videoBuffers.count
        let aCount = result.audioBuffers.count

        // ── Video ──────────────────────────────────────────────────────────────

        if vCount > 0 {
            let vStart = nextVideoSampleIdx
            for (sb, _) in result.videoBuffers { renderer.enqueueVideo(sb) }
            lastEnqueuedVideoPTS  = max(lastEnqueuedVideoPTS, result.lastVideoPTS)
            nextVideoSampleIdx   += vCount
            framesLoaded          = nextVideoSampleIdx
            record("  [\(result.label)] video [\(vStart)…\(nextVideoSampleIdx - 1)]  "
                 + "\(vCount) pkts  tail=\(String(format: "%.2f", lastEnqueuedVideoPTS))s")
        }

        // ── Audio ──────────────────────────────────────────────────────────────

        if aCount > 0 {
            let aStart = nextAudioSampleIdx
            for sb in result.audioBuffers { renderer.enqueueAudio(sb) }
            lastEnqueuedAudioPTS  = max(lastEnqueuedAudioPTS, result.lastAudioPTS)
            nextAudioSampleIdx   += aCount
            record("  [\(result.label)] audio [\(aStart)…\(nextAudioSampleIdx - 1)]  "
                 + "\(aCount) pkts  tail=\(String(format: "%.2f", lastEnqueuedAudioPTS))s")
        }

        return vCount
    }

    // MARK: - feedWindow  (Sprint 16 — thin wrapper over fetch + enqueue)
    //
    // Convenience for prepare() and the feed loop, which read and enqueue
    // in a single step from the current cursor positions.
    // seek() calls fetchPackets() + enqueueAndAdvance() directly so it can
    // flush the renderer between the two phases.

    @discardableResult
    private func feedWindow(videoCount:  Int,
                            audioSeconds: Double,
                            label:        String) async -> Int {
        let result = await fetchPackets(videoCount:   videoCount,
                                        audioSeconds:  audioSeconds,
                                        fromVideoIdx:  nextVideoSampleIdx,
                                        fromAudioIdx:  nextAudioSampleIdx,
                                        label:         label)
        return enqueueAndAdvance(result)
    }

    // MARK: - Audio Session

    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            record("  🔊 AVAudioSession activated (.playback / .moviePlayback)")
        } catch {
            record("  ⚠️ AVAudioSession activation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Time Tracking

    private func startTimeTracking() {
        stopTimeTracking()
        timeTask = Task { [weak self] in
            while !Task.isCancelled {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 250_000_000)  // 250 ms
                guard let self, !Task.isCancelled else { break }
                let ct = self.renderer.currentTime
                if ct.isValid && ct.seconds > 0 {
                    self.currentTime = ct.seconds
                    // Sprint 26: push playhead to subtitle controller every 250 ms
                    self.subtitleController.update(forTime: ct.seconds)
                }
            }
        }
    }

    private func stopTimeTracking() {
        timeTask?.cancel()
        timeTask = nil
    }

    // MARK: - Sample-count helpers

    private func videoSamplesFor(seconds: Double) -> Int {
        guard duration > 0, videoSamplesTotal > 0 else { return 150 }
        let fps = Double(videoSamplesTotal) / duration
        return max(1, Int(seconds * fps))
    }

    private func audioSamplesFor(seconds: Double) -> Int {
        guard duration > 0, audioSamplesTotal > 0 else { return 200 }
        let aps = Double(audioSamplesTotal) / duration
        return max(1, Int(seconds * aps))
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
            decodeTimeStamp:       packet.dts
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

    // MARK: - Audio Format Description

    private func makeAudioFormatDescription(
        esdsPayload:  Data,
        channelCount: UInt16,
        sampleRate:   Double
    ) -> CMAudioFormatDescription? {
        guard let magicCookie = parseAudioSpecificConfig(from: esdsPayload) else {
            record("  ⚠️ Failed to parse AudioSpecificConfig from esds")
            return nil
        }
        var asbd = AudioStreamBasicDescription(
            mSampleRate:       sampleRate,
            mFormatID:         kAudioFormatMPEG4AAC,
            mFormatFlags:      0,
            mBytesPerPacket:   0,
            mFramesPerPacket:  1024,
            mBytesPerFrame:    0,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel:   0,
            mReserved:         0
        )
        var desc: CMAudioFormatDescription?
        let status = magicCookie.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
            CMAudioFormatDescriptionCreate(
                allocator:            kCFAllocatorDefault,
                asbd:                 &asbd,
                layoutSize:           0,
                layout:               nil,
                magicCookieSize:      magicCookie.count,
                magicCookie:          ptr.baseAddress!,
                extensions:           nil,
                formatDescriptionOut: &desc
            )
        }
        guard status == noErr else {
            record("  ⚠️ CMAudioFormatDescriptionCreate failed: \(status)")
            return nil
        }
        return desc
    }

    // MARK: - Audio Format Description — MKV AAC  (Sprint 22)
    //
    // MKV AAC CodecPrivate IS the raw AudioSpecificConfig bytes —
    // no esds wrapping to strip.  Pass directly as the magic cookie.

    private func makeMKVAudioFormatDescription(
        audioSpecificConfig: Data,
        channelCount: UInt16,
        sampleRate:   Double
    ) -> CMAudioFormatDescription? {
        guard !audioSpecificConfig.isEmpty else {
            record("  ⚠️ MKV AAC CodecPrivate is empty")
            return nil
        }
        var asbd = AudioStreamBasicDescription(
            mSampleRate:       sampleRate,
            mFormatID:         kAudioFormatMPEG4AAC,
            mFormatFlags:      0,
            mBytesPerPacket:   0,
            mFramesPerPacket:  1024,
            mBytesPerFrame:    0,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel:   0,
            mReserved:         0
        )
        var desc: CMAudioFormatDescription?
        let status = audioSpecificConfig.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
            CMAudioFormatDescriptionCreate(
                allocator:            kCFAllocatorDefault,
                asbd:                 &asbd,
                layoutSize:           0,
                layout:               nil,
                magicCookieSize:      audioSpecificConfig.count,
                magicCookie:          ptr.baseAddress!,
                extensions:           nil,
                formatDescriptionOut: &desc
            )
        }
        guard status == noErr else {
            record("  ⚠️ CMAudioFormatDescriptionCreate (MKV AAC) failed: \(status)")
            return nil
        }
        return desc
    }

    // MARK: - Audio Format Description — AC3 / EAC3  (Sprint 24)
    //
    // AC3 and EAC3 are self-framing — each DemuxPacket payload is a complete
    // sync frame.  No magic cookie is needed; the decoder initialises from the
    // stream header.  AVSampleBufferAudioRenderer supports both via Apple TV
    // pass-through when the sink is an HDMI receiver.

    private func makeAC3AudioFormatDescription(
        channelCount: UInt16,
        sampleRate:   Double,
        isEAC3:       Bool
    ) -> CMAudioFormatDescription? {
        let formatID: AudioFormatID = isEAC3 ? kAudioFormatEnhancedAC3 : kAudioFormatAC3
        let label = isEAC3 ? "E-AC3" : "AC3"
        var asbd = AudioStreamBasicDescription(
            mSampleRate:       sampleRate > 0 ? sampleRate : 48_000,
            mFormatID:         formatID,
            mFormatFlags:      0,
            mBytesPerPacket:   0,
            mFramesPerPacket:  1536,           // standard AC3/EAC3 frame = 1536 samples
            mBytesPerFrame:    0,
            mChannelsPerFrame: UInt32(channelCount > 0 ? channelCount : 6),
            mBitsPerChannel:   0,
            mReserved:         0
        )
        var desc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator:            kCFAllocatorDefault,
            asbd:                 &asbd,
            layoutSize:           0,
            layout:               nil,
            magicCookieSize:      0,
            magicCookie:          nil,
            extensions:           nil,
            formatDescriptionOut: &desc
        )
        guard status == noErr else {
            record("  ⚠️ CMAudioFormatDescriptionCreate (\(label)) failed: \(status)")
            return nil
        }
        return desc
    }

    private func parseAudioSpecificConfig(from esds: Data) -> Data? {
        guard esds.count > 4 else { return nil }
        var idx = 4   // skip version (1) + flags (3)

        func parseLength() -> Int? {
            var length = 0
            for _ in 0..<4 {
                guard idx < esds.count else { return nil }
                let b = Int(esds[idx]); idx += 1
                length = (length << 7) | (b & 0x7F)
                if b & 0x80 == 0 { break }
            }
            return length
        }

        guard idx < esds.count, esds[idx] == 0x03 else { return nil }
        idx += 1
        guard parseLength() != nil else { return nil }
        guard idx + 3 <= esds.count else { return nil }
        idx += 3

        guard idx < esds.count, esds[idx] == 0x04 else { return nil }
        idx += 1
        guard parseLength() != nil else { return nil }
        guard idx + 13 <= esds.count else { return nil }
        idx += 13

        guard idx < esds.count, esds[idx] == 0x05 else { return nil }
        idx += 1
        guard let magicLen = parseLength() else { return nil }
        guard idx + magicLen <= esds.count else { return nil }

        return esds.subdata(in: idx..<(idx + magicLen))
    }

    // MARK: - Sprint 27: End-of-stream handler

    /// Called when the video sample cursor reaches the end and the buffer drains.
    /// Stops the synchroniser clock, clears subtitles, and transitions to .ended.
    private func onPlaybackEnded() {
        if state == .buffering { renderer.synchronizer.rate = 0 }
        stopFeedLoop()
        stopTimeTracking()
        subtitleController.selectOff()   // clear any lingering cue from screen
        state = .ended
        record("⏹ Playback ended — all \(videoSamplesTotal) video samples delivered")
    }

    // MARK: - Sprint 25: Audio track switching

    /// Restart-based audio track switch.  Saves the current playhead, re-prepares
    /// the same URL with the requested track, then seeks back and resumes if playing.
    func switchAudioTrack(to trackNumber: UInt64) async {
        guard let url = currentURL else { return }
        let resumeSec  = currentTime
        let wasPlaying = (state == .playing || state == .buffering)
        record("[Audio] switching to track \(trackNumber) — re-preparing…")
        requestedAudioTrackNumber = trackNumber
        await prepare(url: url)
        guard state == .ready else { return }
        if resumeSec > 0, duration > 0 {
            await seek(toFraction: resumeSec / duration)
        }
        if wasPlaying { play() }
        record("[Audio] switch complete — resumed at \(String(format: "%.2f", resumeSec))s")
    }

    // MARK: - Sprint 27: Chapter navigation

    /// Seek to the start of the given chapter.
    func seekToChapter(_ chapter: ChapterInfo) async {
        guard duration > 0 else { return }
        let fraction = max(0, min(1, chapter.startTime.seconds / duration))
        record("[Chapter] → '\(chapter.title)'  @\(String(format: "%.2f", chapter.startTime.seconds))s")
        await seek(toFraction: fraction)
    }

    /// The chapter that contains the current playhead position, if any.
    var currentChapter: ChapterInfo? {
        guard !chapters.isEmpty else { return nil }
        let t = currentTime
        // Walk backwards: last chapter whose startTime ≤ currentTime
        return chapters.last { $0.startTime.seconds <= t }
    }

    // MARK: - Logging / helpers

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
