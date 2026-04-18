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
// Sprint 28  — PGS subtitle support and PGSSubtitleController integration
// Sprint 29  — TrueHD/DTS audio classification and logging
// Sprint 30  — State transition logging, restart() from .ended fix, dts:.invalid for B-frame H.264
// SC1        — AudioFormatFactory: audio format-description logic extracted to Audio/
// SC2        — ContainerPreparation: container routing + parsing extracted to Core/
// SC7        — PacketFeeder: fetch/enqueue pipeline + cursor state extracted to Core/
//
// Controller is now an orchestrator:
//   prepare()    → reset → open reader → ContainerPreparation → apply result
//                → build format descriptions (AudioFormatFactory / H264/HEVCDecoder)
//                → configure PacketFeeder → load initial window → .ready
//   play/pause/seek → direct transport calls
//   feedIfNeeded    → ask PacketFeeder to fill / enqueue
//
// NOT production-ready. Debug / lab use only.

import Foundation
import AVFoundation
import CoreGraphics  // CGSize for firstFrameSize
import CoreMedia
import UIKit         // AVAudioSession, CGSize (via UIKit → CoreGraphics)

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
        var canPause: Bool { switch self { case .playing, .buffering: return true; default: return false } }
        var canSeek:  Bool { switch self { case .playing, .buffering, .paused, .ready: return true; default: return false } }
    }

    // MARK: - Published

    @Published private(set) var state:          State        = .idle
    @Published private(set) var log:            [String]     = []
    @Published private(set) var firstFrameSize: CGSize       = .zero
    @Published private(set) var framesLoaded:   Int          = 0
    @Published private(set) var detectedCodec:  String       = "—"
    @Published private(set) var hasAudio:       Bool         = false
    @Published private(set) var duration:       TimeInterval = 0
    @Published private(set) var currentTime:    TimeInterval = 0
    /// Seconds of video ahead of the current playhead (Sprint 17: live buffer depth).
    @Published private(set) var videoBuffered:  Double       = 0
    @Published private(set) var audioBuffered:  Double       = 0

    /// Sprint 25: available MKV audio tracks + currently selected track.
    @Published private(set) var availableAudioTracks: [MKVAudioTrackDescriptor] = []
    @Published private(set) var selectedAudioTrack:   MKVAudioTrackDescriptor?  = nil

    /// Sprint 27: chapter list populated after parse.
    @Published private(set) var chapters: [ChapterInfo] = []

    // MARK: - Renderer

    let renderer: FrameRenderer

    // MARK: - PacketFeeder (SC7)

    private let feeder: PacketFeeder

    // MARK: - Demuxers (retained for seek helpers — Sprint 16 / Sprint 21)
    //
    // Exactly one is non-nil after prepare(). The feeder holds matching refs;
    // these copies let seek() call the demuxer's index/PTS helpers directly.

    private var demuxer:    MP4Demuxer?   // MP4 / MOV
    private var mkvDemuxer: MKVDemuxer?  // Sprint 21: MKV / WebM

    /// Published so the HUD can show "MKV" vs "MP4".
    @Published private(set) var detectedContainer: String = "—"

    // MARK: - Sprint 25: Audio preference state

    private var currentURL: URL? = nil
    var audioPreferences: AudioPreferencePolicy = .default
    private var requestedAudioTrackNumber: UInt64? = nil

    // MARK: - Sprint 26 / 28: Subtitle controllers

    let subtitleController = PlayerLabSubtitleController()
    let pgsController      = PGSSubtitleController()

    // MARK: - Streaming state

    private var startPTS: CMTime = .zero

    /// Lower bound for currentTime; guards against a stale timebase after seek.
    private var currentTimeFloor: Double = 0

    // MARK: - Buffer config

    private let initialWindowSeconds: Double = 3.0
    private let targetBufferSeconds:  Double = 8.0
    private let lowWatermarkSeconds:  Double = 2.0
    private let feedChunkSeconds:     Double = 2.0
    private let underrunThreshold:    Double = 0.5
    private let resumeThreshold:      Double = 1.5

    // MARK: - Background tasks

    private var feedTask: Task<Void, Never>?
    private var timeTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        let r = FrameRenderer()
        renderer = r
        feeder   = PacketFeeder(renderer: r)
        r.onFirstFrame = { [weak self] size in
            self?.firstFrameSize = size
        }
    }

    // MARK: - Prepare
    //
    // SC1/SC2/SC7 restructure:
    //   1. Reset state (incl. feeder.reset())
    //   2. Open MediaReader
    //   3. ContainerPreparation.prepare()  → ContainerResult
    //   4. Apply result to controller + feeder
    //   5. Build CMVideoFormatDescription  → feeder.videoFormatDesc
    //   6. Build CMAudioFormatDescription  via AudioFormatFactory → feeder.audioFormatDesc
    //   7. feeder.feedWindow()             → initial window
    //   8. Transition to .ready

    func prepare(url: URL) async {
        state = .loading
        log   = []

        // ── Reset all per-file state ──────────────────────────────────────────
        demuxer              = nil
        mkvDemuxer           = nil
        detectedContainer    = "—"
        currentTimeFloor     = 0
        hasAudio             = false
        framesLoaded         = 0
        videoBuffered        = 0
        audioBuffered        = 0

        if url != currentURL { requestedAudioTrackNumber = nil }
        currentURL           = url
        availableAudioTracks = []
        selectedAudioTrack   = nil
        chapters             = []
        subtitleController.reset()
        pgsController.reset()
        feeder.reset()

        renderer.flushAll()
        stopFeedLoop()
        stopTimeTracking()

        record("[prepare] \(url.lastPathComponent)")

        // ── Step 1: Open MediaReader ──────────────────────────────────────────
        record("[1] Opening MediaReader…")
        let reader = MediaReader(url: url)
        do {
            try await reader.open()
            record("  ✅ Opened — \(formatBytes(reader.contentLength))")
        } catch {
            fail("Open failed: \(error.localizedDescription)"); return
        }

        // ── Step 2: Route + parse container (SC2) ────────────────────────────
        let prepared: ContainerResult
        do {
            prepared = try await ContainerPreparation.prepare(
                url:                 url,
                reader:              reader,
                audioPolicy:         audioPreferences,
                preferredAudioTrack: requestedAudioTrackNumber
            )
        } catch {
            fail(error.localizedDescription); return
        }
        for msg in prepared.logMessages { record(msg) }

        // ── Step 3: Apply container result ───────────────────────────────────
        switch prepared {
        case .mkv(let r):
            mkvDemuxer           = r.demuxer
            feeder.mkvDemuxer    = r.demuxer
            detectedContainer    = "MKV"

            availableAudioTracks = r.availableAudioTracks
            selectedAudioTrack   = r.availableAudioTracks
                .first { $0.trackNumber == r.selectedAudioTrackNumber }

            subtitleController.setAvailableTracks(r.availableSubtitleTracks)
            if let subTrack = r.selectedSubtitleTrack, !r.subtitleCues.isEmpty {
                subtitleController.loadCues(r.subtitleCues, for: subTrack)
            }
            if let pgsTrack = r.selectedPGSTrack, !r.pgsCues.isEmpty {
                pgsController.setAvailableTracks(r.availableSubtitleTracks)
                pgsController.loadCues(r.pgsCues, for: pgsTrack)
            }
            chapters = r.chapters

        case .mp4(let r):
            demuxer           = r.demuxer
            feeder.mp4Demuxer = r.demuxer
            detectedContainer = "MP4"
        }

        // ── Step 4: Identify video track + configure feeder totals ───────────
        let videoTrack       = prepared.videoTrack
        let fourCC           = videoTrack.codecFourCC ?? "?"
        detectedCodec        = fourCC
        duration             = videoTrack.durationSeconds
        feeder.videoSamplesTotal = videoTrack.sampleCount
        feeder.duration          = videoTrack.durationSeconds

        record("  codec=\(fourCC)  "
             + "\(videoTrack.displayWidth ?? 0)×\(videoTrack.displayHeight ?? 0)  "
             + "\(videoTrack.sampleCount) samples  "
             + "\(String(format: "%.2f", videoTrack.durationSeconds))s")

        // ── Step 5: Build CMVideoFormatDescription ────────────────────────────
        record("[5] Building CMVideoFormatDescription (\(fourCC))…")
        do {
            if videoTrack.isH264 {
                guard let avcC = videoTrack.avcCData else {
                    fail("H.264 track has no avcC data"); return
                }
                feeder.videoFormatDesc = try H264Decoder.makeFormatDescription(from: avcC)
                record("  ✅ H.264 format description (avcC \(avcC.count) bytes)")
            } else if videoTrack.isHEVC {
                guard let hvcC = videoTrack.hvcCData else {
                    fail("HEVC track has no hvcC data"); return
                }
                feeder.videoFormatDesc = try HEVCDecoder.makeFormatDescription(from: hvcC)
                record("  ✅ HEVC format description (hvcC \(hvcC.count) bytes)")
            } else {
                fail("Unsupported video codec: \(fourCC)"); return
            }
        } catch {
            fail("Format description failed: \(error.localizedDescription)"); return
        }

        // ── Step 6: Build CMAudioFormatDescription (SC1 — AudioFormatFactory) ─
        let activeAudioTrack: TrackInfo?
        let mkvCodecPrivate: Data?
        switch prepared {
        case .mkv(let r): activeAudioTrack = r.demuxer.audioTrack
                          mkvCodecPrivate  = r.demuxer.audioCodecPrivate
        case .mp4(let r): activeAudioTrack = r.demuxer.audioTrack
                          mkvCodecPrivate  = nil
        }

        if let at = activeAudioTrack, let ch = at.channelCount, let sr = at.audioSampleRate {
            let fmtDesc = AudioFormatFactory.make(for: at, codecPrivate: mkvCodecPrivate,
                                                  record: record(_:))
            if let fmtDesc {
                feeder.audioFormatDesc   = fmtDesc
                feeder.audioSamplesTotal = at.sampleCount
                feeder.hasAudio          = true
                hasAudio                 = true
                record("  ✅ Audio format description  "
                     + "ch=\(ch) sr=\(Int(sr)) Hz  \(at.sampleCount) samples")
            } else {
                record("  ⚠️ Audio format description failed — video only")
            }
        } else if activeAudioTrack == nil {
            if demuxer?.audioTrack == nil && mkvDemuxer?.audioTrack == nil {
                record("  ℹ️ No audio track in this file")
            } else {
                record("  ⚠️ Audio track found but codec unsupported — video only")
            }
        }

        // ── Step 7: Load initial window (SC7 — feeder.feedWindow) ────────────
        //
        // Activate AVAudioSession before the first audio buffer is enqueued.
        if hasAudio { activateAudioSession() }

        let initVideoCount = feeder.videoSamplesFor(seconds: initialWindowSeconds)
        record("[7] Loading initial window (\(Int(initialWindowSeconds))s "
             + "≈ \(initVideoCount) video "
             + "/ \(feeder.audioSamplesFor(seconds: initialWindowSeconds)) audio samples)…")

        let loaded = await feeder.feedWindow(videoCount:   initVideoCount,
                                             audioSeconds: initialWindowSeconds,
                                             label:        "initial",
                                             log:          record(_:))
        guard loaded > 0 else {
            fail("No video packets in initial window"); return
        }
        framesLoaded = feeder.nextVideoSampleIdx

        startPTS = renderer.firstFramePTS.isValid ? renderer.firstFramePTS : .zero
        record("  startPTS=\(String(format: "%.4f", startPTS.seconds))s  "
             + "buffered≈\(String(format: "%.1f", feeder.lastEnqueuedVideoPTS - startPTS.seconds))s  "
             + "v_idx=\(feeder.nextVideoSampleIdx)/\(feeder.videoSamplesTotal)")

        transition(to: .ready, "initial window loaded")
        record("✅ Ready — initial window loaded, feed loop will handle the rest")
    }

    // MARK: - Transport

    func play() {
        switch state {
        case .ready:
            renderer.play(from: startPTS)
            transition(to: .playing, "play()")
            startFeedLoop()
            startTimeTracking()
            record("▶ play() — synchronizer at PTS=\(String(format: "%.4f", startPTS.seconds))s")
        case .paused:
            renderer.resume()
            transition(to: .playing, "resume()")
            startFeedLoop()
            startTimeTracking()
            record("▶ resume() — feed loop restarted")
        default:
            break
        }
    }

    func pause() {
        guard state.canPause else { return }
        renderer.pause()
        stopFeedLoop()
        transition(to: .paused, "pause()")
        stopTimeTracking()
        record("⏸ pause() — feed loop stopped, queues preserved")
    }

    func stop() {
        renderer.flushAll()
        stopFeedLoop()
        stopTimeTracking()
        demuxer           = nil
        mkvDemuxer        = nil
        detectedContainer = "—"
        transition(to: .idle, "stop()")
        framesLoaded      = 0
        hasAudio          = false
        detectedCodec     = "—"
        firstFrameSize    = .zero
        currentTime       = 0
        videoBuffered     = 0
        audioBuffered     = 0
        currentTimeFloor  = 0
        availableAudioTracks      = []
        selectedAudioTrack        = nil
        requestedAudioTrackNumber = nil
        chapters                  = []
        subtitleController.reset()
        pgsController.reset()
        feeder.reset()
        record("⏹ stop() — renderer + feed loop cleared")
    }

    // MARK: - Seek  (Sprint 18 / 18.5)
    //
    // Four-phase sequence:
    //   Phase 1 — FETCH:   async IO into FetchResult (feeder.fetchPackets)
    //   Phase 2 — FLUSH:   renderer queues cleared (display freezes here, µs)
    //   Phase 3 — ENQUEUE: feeder.setCursors + feeder.enqueueAndAdvance
    //   Phase 4 — CLOCK:   re-anchor synchronizer at keyframe PTS

    func seek(toFraction fraction: Double) async {
        guard state.canSeek else { return }
        guard demuxer != nil || mkvDemuxer != nil else { return }

        let clampedFraction = max(0, min(1, fraction))
        let targetSeconds   = clampedFraction * duration
        let targetPTS       = CMTime(seconds: targetSeconds, preferredTimescale: 90_000)

        record("[seek] → \(String(format: "%.2f", targetSeconds))s "
             + "(\(Int(clampedFraction * 100))% of \(String(format: "%.0f", duration))s)")

        let keyframeIdx: Int
        let keyframePTS: CMTime
        let audioIdx:    Int
        if let mkv = mkvDemuxer {
            keyframeIdx = mkv.findVideoKeyframeSampleIndex(nearestBeforePTS: targetPTS)
            keyframePTS = mkv.videoPTS(forSample: keyframeIdx)
            audioIdx    = mkv.findAudioSampleIndex(nearestBeforePTS: keyframePTS)
        } else if let mp4 = demuxer {
            keyframeIdx = mp4.findVideoKeyframeSampleIndex(nearestBeforePTS: targetPTS)
            keyframePTS = mp4.videoPTS(forSample: keyframeIdx)
            audioIdx    = mp4.findAudioSampleIndex(nearestBeforePTS: keyframePTS)
        } else { return }

        record("  keyframe[\(keyframeIdx)] @ \(String(format: "%.4f", keyframePTS.seconds))s  "
             + "audio_idx=\(audioIdx)")

        let wasPlaying = (state == .playing || state == .buffering)
        stopFeedLoop()

        // ── Phase 1: PRE-FETCH (async IO, no flush yet) ───────────────────────
        record("  [seek] pre-fetching \(String(format: "%.0f", initialWindowSeconds))s window…")
        let initVideoCount = feeder.videoSamplesFor(seconds: initialWindowSeconds)
        let fetched = await feeder.fetchPackets(
            videoCount:   initVideoCount,
            audioSeconds: initialWindowSeconds,
            fromVideoIdx: keyframeIdx,
            fromAudioIdx: audioIdx,
            label:        "seek",
            log:          record(_:)
        )
        record("  [seek] fetch done — \(fetched.videoBuffers.count)v / \(fetched.audioBuffers.count)a ready")

        // ── Phase 2: FLUSH (display gap starts here) ──────────────────────────
        renderer.flushForSeek()

        // ── Phase 3: RESET CURSORS + ENQUEUE (gap ends here) ─────────────────
        feeder.setCursors(videoIdx: keyframeIdx, audioIdx: audioIdx,
                          videoPTS: keyframePTS.seconds, audioPTS: keyframePTS.seconds)
        currentTimeFloor = keyframePTS.seconds

        let loaded = feeder.enqueueAndAdvance(fetched, log: record(_:))
        framesLoaded = feeder.nextVideoSampleIdx
        record("  [seek] \(loaded) video packets enqueued  "
             + "buffered≈\(String(format: "%.1f", feeder.lastEnqueuedVideoPTS - keyframePTS.seconds))s")

        // ── Phase 4: CLOCK — re-anchor synchronizer at keyframe PTS ──────────
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
        // Sprint 30: seek() guards canSeek which excludes .ended.
        if state == .ended { state = .paused }
        await seek(toFraction: 0)
        if wasPlaying, state != .playing {
            renderer.synchronizer.setRate(1, time: startPTS)
            state = .playing
            startFeedLoop()
            startTimeTracking()
        }
        record("⏮ restart()")
    }

    // MARK: - Feed Loop  (Sprint 17)

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

        let rawTime   = renderer.currentTime.seconds
        let nowSec    = rawTime.isNaN ? currentTimeFloor : max(rawTime, currentTimeFloor)
        let buffered  = max(0, feeder.lastEnqueuedVideoPTS - nowSec)
        videoBuffered = buffered
        audioBuffered = max(0, feeder.lastEnqueuedAudioPTS - nowSec)

        if logCycle % 10 == 0 {
            record("[feed] t=\(String(format: "%.1f", nowSec))s  "
                 + "buf=\(String(format: "%.1f", buffered))s  "
                 + "v=\(feeder.nextVideoSampleIdx)/\(feeder.videoSamplesTotal)  "
                 + "a=\(feeder.nextAudioSampleIdx)/\(feeder.audioSamplesTotal)  "
                 + "[\(state.statusLabel)]")
        }

        // End-of-stream: all samples fed, wait for buffer to drain.
        if feeder.nextVideoSampleIdx >= feeder.videoSamplesTotal {
            if buffered < 0.5 { onPlaybackEnded() }
            return
        }

        // ── Underrun detection (Sprint 19) ────────────────────────────────────
        if state == .playing && buffered < underrunThreshold {
            transition(to: .buffering, "underrun \(String(format: "%.2f", buffered))s")
            renderer.synchronizer.rate = 0
            record("[Buffer] video=\(String(format: "%.2f", buffered))s  "
                 + "audio=\(String(format: "%.2f", audioBuffered))s → ENTER BUFFERING")
        }

        if state == .buffering {
            let toFill     = targetBufferSeconds - buffered
            let videoCount = feeder.videoSamplesFor(seconds: max(toFill, feedChunkSeconds))
            if logCycle % 5 == 0 {
                record("[Buffer] refilling \(String(format: "%.1f", toFill))s "
                     + "≈ \(videoCount) samples…")
            }
            await feeder.feedWindow(videoCount:   videoCount,
                                    audioSeconds: max(toFill, feedChunkSeconds),
                                    label:        "buf-refill",
                                    log:          record(_:))
            framesLoaded = feeder.nextVideoSampleIdx

            let rawTime2  = renderer.currentTime.seconds
            let nowSec2   = rawTime2.isNaN ? currentTimeFloor : max(rawTime2, currentTimeFloor)
            let newBuf    = max(0, feeder.lastEnqueuedVideoPTS - nowSec2)
            videoBuffered = newBuf

            if newBuf >= resumeThreshold {
                transition(to: .playing, "buffer recovered \(String(format: "%.2f", newBuf))s")
                renderer.synchronizer.setRate(1, time: renderer.currentTime)
                record("[Buffer] video=\(String(format: "%.2f", newBuf))s → RESUME PLAYBACK")
            }
            return
        }

        // ── Normal low-watermark refill (Sprint 17) ───────────────────────────
        guard buffered < lowWatermarkSeconds else { return }

        let toFill     = targetBufferSeconds - buffered
        let videoCount = feeder.videoSamplesFor(seconds: toFill)
        record("[feed] ⚠️ low watermark (\(String(format: "%.1f", buffered))s < \(lowWatermarkSeconds)s) "
             + "— refilling \(String(format: "%.1f", toFill))s ≈\(videoCount) samples")

        await feeder.feedWindow(videoCount:   videoCount,
                                audioSeconds: toFill,
                                label:        "refill",
                                log:          record(_:))
        framesLoaded = feeder.nextVideoSampleIdx
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
                    self.subtitleController.update(forTime: ct.seconds)
                    self.pgsController.update(forTime: ct.seconds)
                }
            }
        }
    }

    private func stopTimeTracking() {
        timeTask?.cancel()
        timeTask = nil
    }

    // MARK: - End-of-stream  (Sprint 27)

    private func onPlaybackEnded() {
        if state == .buffering { renderer.synchronizer.rate = 0 }
        stopFeedLoop()
        stopTimeTracking()
        subtitleController.selectOff()
        pgsController.selectOff()
        transition(to: .ended, "end of stream")
        record("⏹ Playback ended — all \(feeder.videoSamplesTotal) video samples delivered")
    }

    // MARK: - Sprint 25: Audio track switching

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

    func seekToChapter(_ chapter: ChapterInfo) async {
        guard duration > 0 else { return }
        let fraction = max(0, min(1, chapter.startTime.seconds / duration))
        record("[Chapter] → '\(chapter.title)'  @\(String(format: "%.2f", chapter.startTime.seconds))s")
        await seek(toFraction: fraction)
    }

    var currentChapter: ChapterInfo? {
        guard !chapters.isEmpty else { return nil }
        let t = currentTime
        return chapters.last { $0.startTime.seconds <= t }
    }

    // MARK: - Sprint 30: State transition helper

    private func transition(to newState: State, _ reason: String = "") {
        guard state != newState else { return }
        let reasonStr = reason.isEmpty ? "" : " — \(reason)"
        record("[State] \(state.statusLabel) → \(newState.statusLabel)\(reasonStr)")
        state = newState
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
