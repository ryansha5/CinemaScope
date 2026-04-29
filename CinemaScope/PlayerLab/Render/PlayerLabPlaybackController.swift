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
// Sprint 47  — B-frame decode order: video fetch sorted by fileOffset (decode order, not PTS)
//              Codec-aware branching: H.264 vs HEVC NAL parsing, avcC vs hvcC NAL length
//              Indexer bandwidth fix (rev 2): hysteresis thresholds (fire≥3s, cancel<1.5s);
//              cancel only when frame fetch has pending work; cooperative cancellation in
//              MKVDemuxer.continueIndexing (cluster-boundary checkCancellation + per-cluster
//              cursor save prevents duplicate frame-index entries on cancel/restart).
// SC1        — AudioFormatFactory: audio format-description logic extracted to Audio/
// SC2        — ContainerPreparation: container routing + parsing extracted to Core/
// SC7        — PacketFeeder: fetch/enqueue pipeline + cursor state extracted to Core/
// SC3A       — VideoFormatFactory: video format-description logic extracted to Decode/
// SC6        — BufferPolicy: buffer thresholds + feed-decision helpers extracted to Core/
// SC5        — SubtitleSetupCoordinator: subtitle wiring extracted to Subtitle/
// Sprint 59  — Split buffer measures: optimisticBuffered (feeder tail) for watermark/refill;
//              actualBuffered (layer-only tail via FrameRenderer.actualLayerEnqueuedMaxPTS)
//              for underrun detection.  PENDING-LAG warning logged when actualBuf < 1.5 s
//              and lag > 1 s — diagnostic signal for backpressure analysis.
//
// Controller is now an orchestrator:
//   prepare()    → reset → open reader → ContainerPreparation → apply result
//                → VideoFormatFactory + AudioFormatFactory → configure PacketFeeder
//                → load initial window → .ready
//   play/pause/seek → direct transport calls
//   feedIfNeeded    → ask PacketFeeder to fill / enqueue (thresholds via BufferPolicy)
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

    // MARK: - Sprint 42: Fallback callback

    /// Set by the host before calling prepare(url:).
    /// Called when PlayerLab cannot play the content and AVPlayer must take over
    /// (e.g. audio codec has no compatible decode path). The String argument is a
    /// short reason label suitable for logging and routing decisions.
    var onFallbackRequired: ((String) -> Void)?

    // MARK: - Sprint 44: First Frame Mode

    /// When true, prepare() stops after enqueuing exactly one keyframe.
    /// Used to prove the raw-MKV → HEVC → CMSampleBuffer → displayLayer pipeline
    /// before enabling continuous feed. Set by PlayerLabHostView from AppSettings.
    var firstFrameMode: Bool = false

    // MARK: - Prepare instance counter (Sprint 44 diagnostics)

    /// Incremented at the start of every prepare() call.
    /// Used to tag log lines so concurrent / repeated prepares are distinguishable.
    private var prepareCounter: Int = 0

    // MARK: - Sprint 25: Audio preference state

    private var currentURL: URL? = nil
    var audioPreferences: AudioPreferencePolicy = .default
    private var requestedAudioTrackNumber: UInt64? = nil

    // MARK: - Sprint 26 / 28: Subtitle controllers
    //
    // Owned here so the view can bind directly; SubtitleSetupCoordinator (SC5)
    // holds matching references and orchestrates reset / apply / selectOff calls.
    // Declared without inline defaults so they can be forwarded to the
    // coordinator in the two-phase init without triggering a "use before init" error.

    let subtitleController: PlayerLabSubtitleController
    let pgsController:      PGSSubtitleController

    // MARK: - SubtitleSetupCoordinator (SC5)

    private let subtitleCoordinator: SubtitleSetupCoordinator

    // MARK: - Streaming state

    private var startPTS: CMTime = .zero

    /// Lower bound for currentTime; guards against a stale timebase after seek.
    private var currentTimeFloor: Double = 0

    // MARK: - Buffer policy (SC6)

    private let policy = BufferPolicy()

    // MARK: - Background tasks

    private var feedTask:            Task<Void, Never>?
    private var timeTask:            Task<Void, Never>?
    /// Sprint 46: non-blocking MKV index-extension task.
    /// Nil when idle; non-nil while a continueIndexing() call is in flight.
    private var backgroundIndexTask: Task<Void, Never>? = nil

    // MARK: - Init

    /// - Parameter videoOnly: Passed through to `FrameRenderer`.  When `true`
    ///   (default) the audio renderer is NOT attached to the synchronizer and
    ///   `enqueueAudio()` is a no-op — matches existing production behaviour.
    ///   Pass `false` only from the Playback Quarantine audio-isolation phase
    ///   (Phase 4) where audio is being tested in a dedicated controller instance.
    init(videoOnly: Bool = true) {
        let r   = FrameRenderer(videoOnly: videoOnly)
        let srt = PlayerLabSubtitleController()
        let pgs = PGSSubtitleController()
        renderer            = r
        feeder              = PacketFeeder(renderer: r)
        subtitleController  = srt
        pgsController       = pgs
        subtitleCoordinator = SubtitleSetupCoordinator(srtController: srt,
                                                       pgsController:  pgs)
        r.onFirstFrame = { [weak self] size in
            self?.firstFrameSize = size
        }
    }

    // MARK: - Prepare
    //
    // SC1/SC2/SC7 restructure:
    //   1. Reset state (incl. feeder.reset())
    //   2. Open MediaReader
    //   3. ContainerPreparation.prepare()  → ContainerResult (incl. audioDecision)
    //   4. Apply result to controller + feeder; log audioDecision action
    //   5. Build CMVideoFormatDescription  → feeder.videoFormatDesc
    //   6. Build CMAudioFormatDescription  via AudioFormatFactory → feeder.audioFormatDesc
    //   7. feeder.feedWindow()             → initial window
    //   8. Transition to .ready

    func prepare(url: URL) async {
        prepareCounter += 1
        let prepareID = prepareCounter

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
        subtitleCoordinator.reset()   // SC5
        feeder.reset()

        renderer.flushAll()
        stopFeedLoop()
        stopTimeTracking()

        record("[Prepare #\(prepareID)] \(url.lastPathComponent)")
        // Sprint 46: log DV stripping state so it's visible in every run.
        // To disable: PacketFeeder.stripDolbyVisionNALsEnabled = false (before prepare).
        record("[Prepare #\(prepareID)] dvStrip=\(PacketFeeder.stripDolbyVisionNALsEnabled ? "enabled" : "⚠️ DISABLED")")

        // Sprint 43: wall-clock timestamps for each startup phase.
        // Filter "[StartupTiming]" in the Xcode console to see the breakdown.
        let t0 = Date()

        // ── Step 1: Open MediaReader ──────────────────────────────────────────
        let isRawStream = url.pathExtension.lowercased() != "m3u8"
            && url.query?.contains("Static=true") == true
        record("[1] Opening MediaReader… "
             + "(type: \(isRawStream ? "raw static stream" : "HLS/other"), "
             + "path: \(url.path.prefix(60)))")
        let reader = MediaReader(url: url)
        do {
            try await reader.open()
            let tOpen = Date().timeIntervalSince(t0)
            record("  ✅ Opened — \(formatBytes(reader.contentLength))"
                 + "  byteRanges=\(reader.supportsByteRanges)"
                 + (reader.contentType.map { "  type=\($0)" } ?? ""))
            record("[StartupTiming] open: \(String(format: "%.3f", tOpen))s")
        } catch {
            // Emit a structured diagnostic so raw-stream failures are immediately
            // actionable without digging through MediaReader's stderr logs.
            let errDesc = error.localizedDescription
            record("""
  ❌ Open failed: \(errDesc)
  ── Raw stream open diagnostic ──────────────────────────────────
  URL:              \(url.absoluteString.prefix(120))
  URL type:         \(isRawStream ? "raw static stream (Static=true)" : "HLS or other")
  Content-Type:     \(reader.contentType ?? "not received (HEAD failed)")
  Content-Length:   \(reader.contentLength < 0 ? "unknown" : formatBytes(reader.contentLength))
  Byte-range:       \(reader.supportsByteRanges ? "✅ supported" : "❌ NOT supported")
  Error:            \(errDesc)
  ── If this is a raw stream HTTP error ───────────────────────────
  • 401/403: api_key missing or token expired
  • 404: itemId or MediaSourceId wrong
  • 503: Emby server overloaded or file path unavailable
  • No Accept-Ranges: Emby proxy/CDN is stripping range headers
""")
            fail("Open failed: \(errDesc)")
            return
        }

        // ── Step 2: Route + parse container (SC2) ────────────────────────────
        let prepared: ContainerResult
        let tParseStart = Date()
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
        let tParse = Date().timeIntervalSince(tParseStart)
        record("[StartupTiming] parse+index: \(String(format: "%.3f", tParse))s  "
             + "(total so far: \(String(format: "%.3f", Date().timeIntervalSince(t0)))s)")
        for msg in prepared.logMessages { record(msg) }

        // ── Step 3: Apply container result ───────────────────────────────────
        switch prepared {
        case .mkv(let r):
            mkvDemuxer           = r.demuxer
            feeder.mkvDemuxer    = r.demuxer
            feeder.isDolbyVisionDualLayer = r.demuxer.isDolbyVisionDualLayer
            detectedContainer    = "MKV"
            record("[Prepare] isDolbyVisionDualLayer=\(r.demuxer.isDolbyVisionDualLayer)  "
                 + "firstKF=\(r.demuxer.firstVideoKeyframeIndex)")

            availableAudioTracks = r.availableAudioTracks
            selectedAudioTrack   = r.availableAudioTracks
                .first { $0.trackNumber == r.selectedAudioTrackNumber }

            subtitleCoordinator.apply(mkvResult: r)   // SC5
            chapters = r.chapters

            // Sprint 31/32/34/35/37: log audio decision action ---------------
            switch r.audioDecision.action {
            case .useDirect(let n):
                record("[Audio] Direct playback — track \(n)")
            case .useFallback(let n, let fromCodec, let toCodec):
                record("[Audio] Fallback — \(fromCodec) → \(toCodec) (track \(n))")
            case .attemptPassthrough(let n, let codec):
                record("[Audio] ⚠️ \(codec) passthrough attempt — track \(n) "
                     + "(device: \(DTSCapabilityHeuristic.capabilityLabel); "
                     + "silence possible if device lacks DTS hardware)")
            case .useTrueHDAC3Core(let n):
                // Sprint 36/37: use audioPlaybackMode for accurate log.
                record("[Audio] \(r.audioPlaybackMode.displayLabel) — track \(n)")
            case .fallbackToAVPlayer(let reason):
                record("[Audio] No compatible PlayerLab audio path — \(reason)")
                fail("No compatible audio — route to AVPlayer: \(reason)")
                // Sprint 42: notify host so it can hand off to AVPlayer cleanly.
                // Capture before returning so the callback fires after fail().
                onFallbackRequired?("audio: \(reason)")
                return
            case .videoOnly:
                record("[Audio] No audio tracks — video-only playback")
            }

        case .mp4(let r):
            demuxer           = r.demuxer
            feeder.mp4Demuxer = r.demuxer
            detectedContainer = "MP4"
        }

        // ── Step 4: Identify video track + configure feeder totals ───────────
        let videoTrack = prepared.videoTrack
        let fourCC     = videoTrack.codecFourCC ?? "?"
        detectedCodec  = fourCC
        // duration (seek bar) uses the true file duration from videoTrack.durationSeconds,
        // which is computed from fileDurationSeconds in parse().
        duration                 = videoTrack.durationSeconds
        feeder.videoSamplesTotal = videoTrack.sampleCount

        // Sprint 43: feeder.duration must reflect the INDEXED portion (not the full file
        // duration) so that videoSamplesFor(seconds:) computes the correct fps.
        // Example: 200 frames / 8 s = 25 fps.  If we used the true 2h file duration,
        // fps would be 200/7200 = 0.028 — catastrophically wrong for refill sizing.
        if let mkv = mkvDemuxer {
            feeder.duration = mkv.indexedDurationSeconds > 0 ? mkv.indexedDurationSeconds
                                                             : videoTrack.durationSeconds
        } else {
            feeder.duration = videoTrack.durationSeconds
        }

        record("[4] Video track configured  "
             + "codec=\(fourCC)  "
             + "\(videoTrack.displayWidth ?? 0)×\(videoTrack.displayHeight ?? 0)  "
             + "\(videoTrack.sampleCount) startup samples  "
             + "fileDur=\(String(format: "%.1f", videoTrack.durationSeconds))s  "
             + "feederDur=\(String(format: "%.1f", feeder.duration))s"
             + (mkvDemuxer?.isFullyIndexed == true ? "  ✅ fully indexed" : "  ⏳ background indexing pending"))

        // ── Step 5: Build CMVideoFormatDescription (SC3A — VideoFormatFactory) ─
        let t5    = Date()
        let label = "Prepare #\(prepareID)"
        record("[5][\(label)] Building CMVideoFormatDescription (\(fourCC))…  "
             + "codec=\(fourCC)  "
             + "\(videoTrack.displayWidth ?? 0)×\(videoTrack.displayHeight ?? 0)  "
             + "hvcC=\(videoTrack.hvcCData.map { "\($0.count)B" } ?? "none")  "
             + "avcC=\(videoTrack.avcCData.map { "\($0.count)B" } ?? "none")")

        // Watchdog: if VideoFormatFactory.make hangs (e.g. VideoToolbox waiting
        // on a system resource), log a clear hang marker after 2 s.
        // DispatchWorkItem runs on the global queue independently of the Swift
        // cooperative thread pool, so it fires even if this async task is blocked.
        let hangWork = DispatchWorkItem { [weak self] in
            let msg = "[StartupHang][\(label)] HEVC format description exceeded 2 s — "
                    + "possible VideoToolbox hang or missing entitlement"
            FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
            self?.record(msg)
        }
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 2.0,
                                                          execute: hangWork)

        do {
            feeder.videoFormatDesc = try VideoFormatFactory.make(for: videoTrack,
                                                                 label: label,
                                                                 record: record(_:))
            hangWork.cancel()
            let t5elapsed = Date().timeIntervalSince(t5)
            record("  ✅ [5][\(label)] CMVideoFormatDescription built  "
                 + "elapsed=\(String(format: "%.3f", t5elapsed))s")
        } catch {
            hangWork.cancel()
            record("  ❌ [5][\(label)] VideoFormatFactory.make failed: \(error.localizedDescription)")
            fail("Format description failed: \(error.localizedDescription)"); return
        }

        // ── Sprint 44: First Frame Mode — skip audio, feed one keyframe ─────────
        if firstFrameMode, let mkv = mkvDemuxer {
            await runFirstFrameMode(mkv: mkv, t0: t0)
            return
        }

        // ── Step 6: Build CMAudioFormatDescription (SC1 — AudioFormatFactory) ─
        let t6 = Date()
        let activeAudioTrack:    TrackInfo?
        let mkvCodecPrivate:     Data?
        let activePlaybackMode:  AudioTrackPlaybackMode  // Sprint 36
        switch prepared {
        case .mkv(let r): activeAudioTrack   = r.demuxer.audioTrack
                          mkvCodecPrivate    = r.demuxer.audioCodecPrivate
                          activePlaybackMode = r.audioPlaybackMode
        case .mp4(let r): activeAudioTrack   = r.demuxer.audioTrack
                          mkvCodecPrivate    = nil
                          activePlaybackMode = .native
        }

        if let at = activeAudioTrack, let ch = at.channelCount, let sr = at.audioSampleRate {
            record("[6] Building CMAudioFormatDescription  "
                 + "codec=\(at.codecFourCC ?? "?")  ch=\(ch)  sr=\(Int(sr))Hz  "
                 + "mode=\(activePlaybackMode.displayLabel)  "
                 + "esds=\(mkvCodecPrivate.map { "\($0.count)B" } ?? "none")")
            let fmtDesc = AudioFormatFactory.make(for: at,
                                                  playbackMode: activePlaybackMode,
                                                  codecPrivate: mkvCodecPrivate,
                                                  record: record(_:))
            let t6elapsed = Date().timeIntervalSince(t6)
            if let fmtDesc {
                feeder.audioFormatDesc   = fmtDesc
                feeder.audioSamplesTotal = at.sampleCount
                feeder.hasAudio          = true
                hasAudio                 = true
                record("  ✅ [6] CMAudioFormatDescription built  elapsed=\(String(format: "%.3f", t6elapsed))s  \(at.sampleCount) samples")
                if t6elapsed > 5 { record("[StartupHang] phase=6 (AudioFormatFactory) exceeded 5s") }
            } else {
                record("  ⚠️ [6] AudioFormatFactory.make returned nil — video only  elapsed=\(String(format: "%.3f", t6elapsed))s")
            }
        } else if activeAudioTrack == nil {
            if demuxer?.audioTrack == nil && mkvDemuxer?.audioTrack == nil {
                record("[6] ℹ️ No audio track in this file")
            } else {
                record("[6] ⚠️ Audio track present but codec unsupported — video only")
            }
        }

        // ── Step 7: Load initial window (SC7 — feeder.feedWindow) ────────────
        //
        // Activate AVAudioSession before the first audio buffer is enqueued,
        // then start the AVAudioEngine (Sprint 54 path).  Order matters:
        // AVAudioSession must be active before AVAudioEngine starts.
        if hasAudio {
            activateAudioSession()
            // Sprint 54: startAudioEngine replaces attachAudioRenderer.
            // AVSampleBufferAudioRenderer is gone — AVAudioEngine + AVAudioConverter
            // + AVAudioPlayerNode bypass the broken tvOS synchronizer clock.
            if let afd = feeder.audioFormatDesc {
                renderer.startAudioEngine(inputDesc: afd)
            } else {
                record("  ⚠️ [7] hasAudio=true but feeder.audioFormatDesc is nil — audio engine not started")
            }
        }

        // For Dolby Vision Profile 7 dual-layer MKV, the first MKV cluster
        // contains BL-only skip frames (~110 B each) that a standard HEVC
        // decoder cannot decode.  firstVideoKeyframeIndex detects this pattern
        // and returns the second keyframe (the EL IDR) as the usable start.
        // Advance the feeder cursor past the BL preamble before filling the
        // initial window so VT never receives undecodeble BL frames.
        if let mkv = mkvDemuxer {
            let startIdx = mkv.firstVideoKeyframeIndex
            if startIdx > 0 {
                let startPTSsec = mkv.videoPTS(forSample: startIdx).seconds
                feeder.setCursors(videoIdx: startIdx,
                                  audioIdx: 0,
                                  videoPTS: startPTSsec,
                                  audioPTS: 0)
                record("[7] DV BL preamble detected — advancing video cursor to EL IDR  "
                     + "idx=\(startIdx)  pts=\(String(format: "%.4f", startPTSsec))s")
            }
        }

        let initVideoCount = feeder.videoSamplesFor(seconds: policy.initialWindowSeconds)
        let initAudioCount = feeder.audioSamplesFor(seconds: policy.initialWindowSeconds)
        record("[7] Loading initial window  "
             + "target=\(String(format: "%.1f", policy.initialWindowSeconds))s  "
             + "≈\(initVideoCount) video / \(initAudioCount) audio  "
             + "videoTotal=\(feeder.videoSamplesTotal)  "
             + "audioTotal=\(feeder.audioSamplesTotal)")

        let tFeedStart = Date()
        let loaded = await feeder.feedWindow(videoCount:   initVideoCount,
                                             audioSeconds: policy.initialWindowSeconds,
                                             label:        "initial",
                                             log:          record(_:))

        let tFeedElapsed = Date().timeIntervalSince(tFeedStart)
        record("[7] feedWindow returned  "
             + "loaded=\(loaded)  "
             + "nextV=\(feeder.nextVideoSampleIdx)  nextA=\(feeder.nextAudioSampleIdx)  "
             + "tailV=\(String(format: "%.3f", feeder.lastEnqueuedVideoPTS))s  "
             + "tailA=\(String(format: "%.3f", feeder.lastEnqueuedAudioPTS))s  "
             + "elapsed=\(String(format: "%.3f", tFeedElapsed))s")
        if tFeedElapsed > 5 { record("[StartupHang] phase=7 (feedWindow) exceeded 5s: \(String(format: "%.1f", tFeedElapsed))s") }

        guard loaded > 0 else {
            record("  ❌ [7] No video packets loaded — videoTotal=\(feeder.videoSamplesTotal)  "
                 + "videoFormatDesc=\(feeder.videoFormatDesc != nil ? "present" : "nil")  "
                 + "mkvDemuxer=\(mkvDemuxer != nil ? "present" : "nil")")
            fail("No video packets in initial window"); return
        }
        framesLoaded = feeder.nextVideoSampleIdx

        startPTS = renderer.firstFramePTS.isValid ? renderer.firstFramePTS : .zero

        // ── Renderer / enqueue diagnostics ────────────────────────────────────
        let videoLayer = renderer.layer   // AVSampleBufferDisplayLayer
        record("[7] Renderer state after enqueue:  "
             + "startPTS=\(String(format: "%.4f", startPTS.seconds))s  "
             + "firstFramePTS=\(renderer.firstFramePTS.isValid ? String(format: "%.4f", renderer.firstFramePTS.seconds) + "s" : "invalid")  "
             + "buffered≈\(String(format: "%.1f", feeder.lastEnqueuedVideoPTS - startPTS.seconds))s  "
             + "v_idx=\(feeder.nextVideoSampleIdx)/\(feeder.videoSamplesTotal)  "
             + "a_idx=\(feeder.nextAudioSampleIdx)/\(feeder.audioSamplesTotal)")
        record("[7] layer.status=\(videoLayer.status.rawValue)  "
             + "isReadyForMoreMediaData=\(videoLayer.isReadyForMoreMediaData)  "
             + "synchronizer.rate=\(renderer.synchronizer.rate)")
        if let err = videoLayer.error {
            record("  ❌ layer.error=\(err.localizedDescription)")
        }
        if videoLayer.status == .failed {
            record("  ❌ [StartupHang] layer is in .failed state — video will not render")
        }

        // Sprint 46: timebase state immediately after initial enqueue.
        // tbRate should be 0 here (synchronizer not yet started — play() does that).
        // tbTime should be invalid or 0.  If tbRate is already 1 something reset it.
        let tbRate = CMTimebaseGetRate(renderer.synchronizer.timebase)
        let tbTime = CMTimebaseGetTime(renderer.synchronizer.timebase)
        record("[7] timebase: tbRate=\(tbRate)  "
             + "tbTime=\(tbTime.isValid ? String(format: "%.4f", tbTime.seconds) + "s" : "invalid")  "
             + "framesEnqueued=\(renderer.framesEnqueued)  "
             + "firstFramePTS=\(renderer.firstFramePTS.isValid ? String(format: "%.4f", renderer.firstFramePTS.seconds) + "s" : "invalid")  "
             + "dvStrip=\(PacketFeeder.stripDolbyVisionNALsEnabled)")

        // Sprint 43: full startup timing summary.
        let tTotal    = Date().timeIntervalSince(t0)
        let tFeed     = Date().timeIntervalSince(tFeedStart)
        let tOpen     = tTotal - tParse - tFeed   // approximate: time before parse started
        record("""
[StartupTiming] ── Startup timing summary ──────────────────────────────
  open:       \(String(format: "%.3f", tOpen))s
  parse+index:\(String(format: "%.3f", tParse))s
  feedWindow: \(String(format: "%.3f", tFeed))s
  total:      \(String(format: "%.3f", tTotal))s
  indexed:    \(mkvDemuxer.map { String(format: "%.1f", $0.indexedDurationSeconds) } ?? "N/A")s of \(String(format: "%.1f", duration))s file
  frames:     \(feeder.nextVideoSampleIdx)v / \(feeder.nextAudioSampleIdx)a enqueued
""")

        transition(to: .ready, "initial window loaded")
        record("✅ Ready — initial window loaded, feed loop will handle the rest")
    }

    // MARK: - Sprint 44: First Frame Mode helpers

    /// Probes the first keyframe without advancing any cursors.
    /// Safe to call at any point after `feeder.videoFormatDesc` is set.
    /// Logs everything under the `[FirstFrame]` prefix.
    private func diagnoseAndProbeFirstFrame(mkv: MKVDemuxer) async {
        let kfIdx = mkv.firstVideoKeyframeIndex
        let kfPTS = mkv.videoPTS(forSample: kfIdx)
        record("[FirstFrame] Keyframe probe  "
             + "idx=\(kfIdx)  "
             + "pts=\(String(format: "%.4f", kfPTS.seconds))s  "
             + "totalIndexed=\(mkv.indexedVideoFrameCount)")

        guard feeder.videoFormatDesc != nil else {
            record("[FirstFrame] ⚠️ No video format desc — skipping sample buffer probe")
            return
        }

        // fetchPackets has no cursor side effects — safe as a pure diagnostic.
        let result = await feeder.fetchPackets(
            videoCount:   1,
            audioSeconds: 0,
            fromVideoIdx: kfIdx,
            fromAudioIdx: 0,
            label:        "kf-probe",
            log:          { _ in }   // silence sub-logs during probe
        )

        if let (buf, pts) = result.videoBuffers.first {
            record("[FirstFrame] ✅ probe: sample buffer created  "
                 + "pts=\(String(format: "%.4f", pts))s  "
                 + "dataLen=\(CMSampleBufferGetTotalSampleSize(buf))B")
        } else {
            record("[FirstFrame] ❌ probe: fetchPackets returned 0 video buffers  "
                 + "videoFormatDesc=\(feeder.videoFormatDesc != nil ? "present" : "nil")  "
                 + "videoSamplesTotal=\(feeder.videoSamplesTotal)")
        }
    }

    /// Runs the full first-frame pipeline: probe → fetch → enqueue → log layer state.
    /// Called from prepare() when firstFrameMode = true.
    private func runFirstFrameMode(mkv: MKVDemuxer, t0: Date) async {
        record("[FirstFrame] ── First Frame Mode ─────────────────────────────────")
        record("[FirstFrame] indexedFrames=\(mkv.indexedVideoFrameCount)  "
             + "indexedDur=\(String(format: "%.2f", mkv.indexedDurationSeconds))s")

        // Step A: diagnostic probe (no cursor side effects).
        await diagnoseAndProbeFirstFrame(mkv: mkv)

        // Step B: locate the actual first keyframe index.
        let kfIdx = mkv.firstVideoKeyframeIndex
        guard feeder.videoFormatDesc != nil else {
            fail("[FirstFrame] videoFormatDesc is nil — cannot build sample buffer")
            return
        }

        // Step C: fetch exactly one video frame (no audio).
        record("[FirstFrame] Fetching keyframe idx=\(kfIdx)…")
        let fetchResult = await feeder.fetchPackets(
            videoCount:   1,
            audioSeconds: 0,
            fromVideoIdx: kfIdx,
            fromAudioIdx: 0,
            label:        "first-frame",
            log:          record(_:)
        )

        guard !fetchResult.videoBuffers.isEmpty else {
            record("[FirstFrame] ❌ No video buffers returned by fetchPackets")
            fail("[FirstFrame] fetchPackets returned 0 video buffers")
            return
        }
        record("[FirstFrame] fetchPackets returned \(fetchResult.videoBuffers.count) video buffer(s)")

        // Step D: enqueue and advance cursors.
        let loaded = feeder.enqueueAndAdvance(fetchResult, log: record(_:))

        // Step E: log layer state immediately after enqueue.
        let videoLayer = renderer.layer
        record("[FirstFrame] After enqueue —  "
             + "loaded=\(loaded)  "
             + "layer.status=\(videoLayer.status.rawValue)  "
             + "isReadyForMoreMediaData=\(videoLayer.isReadyForMoreMediaData)  "
             + "framesEnqueued=\(renderer.framesEnqueued)  "
             + "firstFramePTS=\(renderer.firstFramePTS.isValid ? String(format: "%.4f", renderer.firstFramePTS.seconds) + "s" : "invalid")")
        if let err = videoLayer.error {
            record("[FirstFrame] ❌ layer.error=\(err.localizedDescription)")
        }
        if videoLayer.status == .failed {
            record("[FirstFrame] ❌ layer in .failed state — video will not render")
        }

        guard loaded > 0 else {
            fail("[FirstFrame] enqueueAndAdvance returned 0 — buffer not accepted by layer")
            return
        }

        // Step F: set startPTS and transition to ready.
        framesLoaded = feeder.nextVideoSampleIdx
        startPTS = fetchResult.videoBuffers.first.map {
            CMTime(seconds: $0.pts, preferredTimescale: 1000)
        } ?? .zero

        let tTotal = Date().timeIntervalSince(t0)
        record("[FirstFrame] ✅ First frame enqueued  "
             + "startPTS=\(String(format: "%.4f", startPTS.seconds))s")
        record("[StartupTiming] first-frame mode  total=\(String(format: "%.3f", tTotal))s")

        transition(to: .ready, "first-frame mode")
        record("✅ [FirstFrame] Ready — call play() to display the frame")
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
        subtitleCoordinator.reset()   // SC5
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
        record("  [seek] pre-fetching \(String(format: "%.0f", policy.initialWindowSeconds))s window…")
        let initVideoCount = feeder.videoSamplesFor(seconds: policy.initialWindowSeconds)
        let fetched = await feeder.fetchPackets(
            videoCount:   initVideoCount,
            audioSeconds: policy.initialWindowSeconds,
            fromVideoIdx: keyframeIdx,
            fromAudioIdx: audioIdx,
            label:        "seek",
            log:          record(_:)
        )
        record("  [seek] fetch done — \(fetched.videoBuffers.count)v / \(fetched.audioBuffers.count)a ready")

        // ── Phase 2: FLUSH (display gap starts here) ──────────────────────────
        renderer.flushForSeek()
        // Sprint 39: clear stale PGS cue immediately on flush so no subtitle
        // image from the pre-seek position persists until update(forTime:) fires
        // (which otherwise arrives up to 250 ms later from the time-tracking loop).
        pgsController.clearCurrentCue(reason: "seek")

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
        // Sprint 54: playerNode was stopped by flushForSeek(); restart it if playing.
        if wasPlaying && renderer.audioRendererAttached {
            renderer.resumeAudioIfNeeded()
        }
        // Update startPTS so that a subsequent play() call (from .ready state)
        // resumes from the seeked position instead of the original prepare() PTS.
        // Without this, play() calls renderer.play(from: prepareTimePTS) which
        // overrides the keyframePTS the synchronizer was just anchored to, causing
        // the clock to run from 0 while enqueued frames start at keyframePTS —
        // producing a ~keyframePTS-second "frozen" display before the first frame appears.
        startPTS = keyframePTS
        record("  [seek] clock anchored @ \(String(format: "%.4f", keyframePTS.seconds))s  "
             + "rate=\(wasPlaying ? 1 : 0)  floor=\(String(format: "%.4f", currentTimeFloor))s  "
             + "startPTS updated=\(String(format: "%.4f", keyframePTS.seconds))s")

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
            // Sprint 54: restart audio player node if needed.
            if renderer.audioRendererAttached {
                renderer.resumeAudioIfNeeded()
            }
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
        // Sprint 46: cancel any in-flight index scan so it doesn't mutate
        // frameIndex while a seek is resetting cursors or a stop() clears state.
        backgroundIndexTask?.cancel()
        backgroundIndexTask = nil
    }

    // MARK: - Sprint 46: Non-blocking background index extension

    /// Extend the MKV index asynchronously to `targetSeconds`.
    ///
    /// Called from `feedIfNeeded` when the feed cursor approaches the end of
    /// the currently indexed window.  Runs as a concurrent Task on the main
    /// actor so the feed loop continues feeding already-indexed frames without
    /// waiting.  Safe to call from multiple feed cycles — the guard ensures
    /// only one scan runs at a time.
    private func triggerBackgroundIndex(mkv: MKVDemuxer, to targetSeconds: Double) {
        guard backgroundIndexTask == nil else { return }   // scan already in flight
        guard !mkv.isFullyIndexed           else { return }

        backgroundIndexTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (vAdded, aAdded) = try await mkv.continueIndexing(untilSeconds: targetSeconds)
                // Update feeder totals — Task inherits @MainActor so this is safe.
                feeder.videoSamplesTotal = mkv.indexedVideoFrameCount
                feeder.audioSamplesTotal = mkv.indexedAudioFrameCount
                feeder.duration          = mkv.indexedDurationSeconds
                record("[IndexTask] ✅ \(String(format: "%.1f", mkv.indexedDurationSeconds))s  "
                     + "+\(vAdded)v/+\(aAdded)a  "
                     + "total=\(feeder.videoSamplesTotal)v/\(feeder.audioSamplesTotal)a  "
                     + (mkv.isFullyIndexed ? "✅ fully indexed" : "more to scan"))
            } catch {
                record("[IndexTask] ❌ scan error: \(error.localizedDescription)")
            }
            backgroundIndexTask = nil
        }
    }

    private func feedIfNeeded(logCycle: Int) async {
        guard state == .playing || state == .buffering else { return }

        let rawTime   = renderer.currentTime.seconds
        let nowSec    = rawTime.isNaN ? currentTimeFloor : max(rawTime, currentTimeFloor)

        // Sprint 59: two buffer depth measures — used for different purposes.
        //
        // optimisticBuffered — tail of frames handed to FrameRenderer.enqueueVideo().
        //   Advances immediately when frames are appended to pendingVideoQueue.
        //   Correct for WATERMARK decisions: frames in pendingVideoQueue WILL drain
        //   into the layer via requestMediaDataWhenReady before their PTS is reached.
        //   They represent real buffer headroom against the playback clock.
        //
        // actualBuffered — tail of frames that have physically reached layer.enqueue()
        //   inside FrameRenderer.performLayerEnqueue().  The layer's internal queue
        //   depth is ~50 frames (~2s), so this is always 1–2s regardless of how many
        //   frames are in pendingVideoQueue.
        //   Correct for UNDERRUN detection: if this hits zero, the clock has outrun
        //   what the layer actually holds, regardless of what's in the pending queue.
        //
        // Watermark/refill decisions use optimisticBuffered.
        // Underrun/recovery decisions use actualBuffered.
        let optimisticBuffered: Double = max(0, feeder.lastEnqueuedVideoPTS - nowSec)
        let actualLayerPTS = renderer.actualLayerEnqueuedMaxPTS
        let actualBuffered: Double = actualLayerPTS.isValid
            ? max(0, actualLayerPTS.seconds - nowSec)
            : optimisticBuffered  // no frames through layer yet (startup) — use feeder tail

        let buffered  = optimisticBuffered   // watermark / refill uses feeder tail
        videoBuffered = actualLayerPTS.isValid ? actualBuffered : optimisticBuffered
        audioBuffered = max(0, feeder.lastEnqueuedAudioPTS - nowSec)

        // ── Periodic log (Sprint 46 + Sprint 59 diagnostics) ─────────────────────
        let pendingQ = renderer.pendingVideoQueueCount
        let pendingLag = optimisticBuffered - actualBuffered
        if logCycle % policy.periodicLogInterval == 0 {
            let idxDur    = mkvDemuxer.map { String(format: "%.1f", $0.indexedDurationSeconds) } ?? "—"
            let idxTask   = backgroundIndexTask != nil ? "🔄" : "idle"
            let fullyIdx  = mkvDemuxer?.isFullyIndexed ?? true
            record("[feed] t=\(String(format: "%.1f", nowSec))s  "
                 + "buf=\(String(format: "%.1f", actualBuffered))s  "           // actual (layer)
                 + "optBuf=\(String(format: "%.1f", optimisticBuffered))s  "    // feeder tail
                 + "pendingQ=\(pendingQ)  "                                     // frames not yet at layer
                 + "lag=\(String(format: "%.2f", pendingLag))s  "              // gap = optBuf - buf
                 + "v=\(feeder.nextVideoSampleIdx)/\(feeder.videoSamplesTotal)  "
                 + "a=\(feeder.nextAudioSampleIdx)/\(feeder.audioSamplesTotal)  "
                 + "indexedDur=\(idxDur)s  indexTask=\(idxTask)  "
                 + "fullyIndexed=\(fullyIdx)  [\(state.statusLabel)]")
            // Sprint 54: log audio engine + player node state when audio is active.
            if renderer.audioRendererAttached {
                record("[P4-diag] \(renderer.dualSyncDiagnostic)  "
                     + "audio=\(audioRendererStatusLabel())")
            }
        }

        // Sprint 59: warn when the pending lag is significant — diagnostic signal
        // for backpressure analysis.  The layer's requestMediaDataWhenReady callback
        // drains pendingVideoQueue while the clock runs; an actual underrun (0.5 s)
        // is still the hard safety net.
        if pendingLag > 1.0 && actualBuffered < policy.resumeThreshold {
            record("[feed] ⚠️ PENDING-LAG  "
                 + "actualBuf=\(String(format: "%.2f", actualBuffered))s  "
                 + "optBuf=\(String(format: "%.2f", optimisticBuffered))s  "
                 + "lag=\(String(format: "%.2f", pendingLag))s  "
                 + "pendingQ=\(pendingQ)  "
                 + "— layer has not accepted \(pendingQ) frames; clock may outrun delivery")
        }

        // ── Sprint 47 (rev 2): Proactive non-blocking background index extension ────
        //
        // Trigger a background scan when the feed cursor is within 30 s of the
        // index tail.  Use hysteresis to avoid bandwidth contention:
        //
        //   FIRE   when buffer ≥ initialWindowSeconds (3 s) — enough headroom
        //          that the indexer can run alongside frame fetch without risk.
        //
        //   CANCEL when buffer < resumeThreshold (1.5 s) — buffer is getting
        //          critical; yield ALL bandwidth to the frame-refill pipeline.
        //          The indexer will be re-triggered once the buffer recovers.
        //
        // Why not targetBufferSeconds (8 s)?  The startup index typically covers
        // only 8–10 s of content, so the buffer can never reach 8 s before the
        // cursor exhausts — meaning the indexer would never fire proactively at
        // all, instead relying solely on the reactive trigger below (cursor = total)
        // which produces a guaranteed freeze while the indexer catches up.
        //
        // With the 3 s / 1.5 s hysteresis the indexer fires immediately after the
        // initial window loads, runs alongside frame fetch while the buffer is
        // healthy, pauses if the buffer becomes critical, and resumes automatically
        // once the frame refill restores headroom.  For large-bitrate files where
        // the indexer takes >10 s, this prevents the cursor from reaching exhaustion
        // before the index is extended.
        if let mkv = mkvDemuxer, !mkv.isFullyIndexed {
            let lookahead    = feeder.videoSamplesFor(seconds: 30.0)
            let nearingTail  = feeder.nextVideoSampleIdx + lookahead >= feeder.videoSamplesTotal
            let bufferOK     = buffered >= policy.initialWindowSeconds   // fire threshold
            let bufferCrit   = buffered < policy.resumeThreshold          // cancel threshold

            // Only cancel when there are still frames the fetcher can retrieve.
            // If cursor = total, frame fetch has nothing left to do; let the
            // indexer keep running with exclusive bandwidth instead.
            let hasPendingFrames = feeder.nextVideoSampleIdx < feeder.videoSamplesTotal
            if nearingTail && bufferCrit && hasPendingFrames && backgroundIndexTask != nil {
                // Buffer is critical and frame fetch has work to do — cancel
                // indexer so ALL bandwidth goes to the frame-refill pipeline.
                record("[IndexTask] ⏸ cancelled — buffer=\(String(format: "%.2f", buffered))s "
                     + "< resume=\(policy.resumeThreshold)s; yielding bandwidth to frame fetch")
                backgroundIndexTask?.cancel()
                backgroundIndexTask = nil
            } else if nearingTail && bufferOK {
                let scanTarget = mkv.indexedDurationSeconds + 60.0
                if backgroundIndexTask == nil {
                    record("[IndexTask] ⚡ proactive trigger  "
                         + "cursor=\(feeder.nextVideoSampleIdx)/\(feeder.videoSamplesTotal)  "
                         + "indexedDur=\(String(format: "%.1f", mkv.indexedDurationSeconds))s  "
                         + "buf=\(String(format: "%.1f", buffered))s  "
                         + "→ scan to \(String(format: "%.0f", scanTarget))s")
                }
                triggerBackgroundIndex(mkv: mkv, to: scanTarget)
            }
        }

        // ── End-of-stream ─────────────────────────────────────────────────────────
        //
        // For MKV: only declare EOS once the demuxer confirms no clusters remain.
        // Without this gate, the feed loop would call onPlaybackEnded() as soon as
        // the 8-second startup index was consumed — long before the file actually ends.
        let fullyIndexed = mkvDemuxer?.isFullyIndexed ?? true
        let atEOS = feeder.nextVideoSampleIdx >= feeder.videoSamplesTotal && fullyIndexed
        if atEOS {
            if logCycle % policy.periodicLogInterval == 0 {
                record("[feed] EOS  nextV=\(feeder.nextVideoSampleIdx)/\(feeder.videoSamplesTotal)  "
                     + "buf=\(String(format: "%.2f", buffered))s  "
                     + "fullyIndexed=\(fullyIndexed)  "
                     + "layer=\(renderer.layerStatusDescription)")
            }
            if policy.isEndOfStream(isAtEOS: atEOS, bufferedSeconds: buffered) { onPlaybackEnded() }
            return
        }

        // ── Underrun detection (Sprint 19 / Sprint 59) ───────────────────────
        //
        // NOTE: This block is intentionally placed BEFORE the cursor-exhausted
        // guard below (Sprint 58 fix).  The original placement had the cursor-
        // exhausted guard returning early BEFORE this block, which meant the
        // underrun check and clock-pause logic were never reached while the
        // background indexer was running.  The video clock continued advancing
        // with no frames to enqueue, frames fell "in the past" relative to the
        // synchronizer, and the display layer discarded them silently — causing
        // deterministic visual distortion at the start of every refill cycle.
        //
        // Sprint 59: underrun uses actualBuffered (what the layer physically holds),
        // not optimisticBuffered (feeder tail including pendingVideoQueue).  A real
        // underrun means the display layer's clock has nearly outrun its accepted
        // frames — pendingVideoQueue headroom is irrelevant at that point if the
        // layer's requestMediaDataWhenReady callback hasn't fired yet.
        if state == .playing && policy.isUnderrun(bufferedSeconds: actualBuffered) {
            let idxDur   = mkvDemuxer.map { String(format: "%.1f", $0.indexedDurationSeconds) } ?? "—"
            let taskState = backgroundIndexTask != nil ? "🔄 scanning" : "idle — waiting for network?"
            transition(to: .buffering, "underrun actual=\(String(format: "%.2f", actualBuffered))s")
            renderer.synchronizer.rate = 0
            // Sprint 54: pause audio player on underrun
            if renderer.audioRendererAttached { renderer.pauseAudioPlayer() }
            record("[Buffer] UNDERRUN  actualVideo=\(String(format: "%.2f", actualBuffered))s  "
                 + "optVideo=\(String(format: "%.2f", buffered))s  "
                 + "pendingQ=\(pendingQ)  "
                 + "audio=\(String(format: "%.2f", audioBuffered))s  "
                 + "nextV=\(feeder.nextVideoSampleIdx)/\(feeder.videoSamplesTotal)  "
                 + "indexedDur=\(idxDur)s  indexTask=\(taskState)  "
                 + "fullyIndexed=\(mkvDemuxer?.isFullyIndexed ?? true)  "
                 + "layer=\(renderer.layerStatusDescription)")
        }

        if state == .buffering {
            let toFill     = policy.refillSeconds(currentlyBuffered: buffered)
            let videoCount = feeder.videoSamplesFor(seconds: toFill)
            if logCycle % policy.bufferingLogInterval == 0 {
                let idxDur    = mkvDemuxer.map { String(format: "%.1f", $0.indexedDurationSeconds) } ?? "—"
                let taskState = backgroundIndexTask != nil ? "🔄 scanning" : "idle"
                record("[Buffer] refilling \(String(format: "%.1f", toFill))s "
                     + "≈ \(videoCount) samples  "
                     + "cursor=\(feeder.nextVideoSampleIdx)/\(feeder.videoSamplesTotal)  "
                     + "tail=\(String(format: "%.2f", feeder.lastEnqueuedVideoPTS))s  "
                     + "indexedDur=\(idxDur)s  indexTask=\(taskState)")
            }
            let cursorBefore = feeder.nextVideoSampleIdx
            await feeder.feedWindow(videoCount:   videoCount,
                                    audioSeconds: toFill,
                                    label:        "buf-refill",
                                    log:          record(_:))
            framesLoaded = feeder.nextVideoSampleIdx

            let rawTime2  = renderer.currentTime.seconds
            let nowSec2   = rawTime2.isNaN ? currentTimeFloor : max(rawTime2, currentTimeFloor)
            let newBuf    = max(0, feeder.lastEnqueuedVideoPTS - nowSec2)
            videoBuffered = newBuf
            record("[Buffer] after refill: cursor \(cursorBefore)→\(feeder.nextVideoSampleIdx)  "
                 + "buf \(String(format: "%.2f", buffered))s→\(String(format: "%.2f", newBuf))s  "
                 + "layer=\(renderer.layerStatusDescription)")

            if policy.isRecovered(bufferedSeconds: newBuf) {
                transition(to: .playing, "buffer recovered \(String(format: "%.2f", newBuf))s")
                let recoverTime = renderer.currentTime
                renderer.synchronizer.setRate(1, time: recoverTime)
                // Sprint 54: resume audio player node after buffer recovery.
                if renderer.audioRendererAttached {
                    renderer.resumeAudioIfNeeded()
                }
                record("[Buffer] RESUME  video=\(String(format: "%.2f", newBuf))s")
            }
            return
        }

        // ── Cursor-exhausted guard (Sprint 57 / repositioned Sprint 58) ──────
        //
        // When the cursor has consumed all indexed frames AND the MKV indexer
        // is still running, calling feedWindow yields 0 new frames and
        // immediately triggers the LOW WATERMARK again — a tight spin loop that
        // fires many times per second.
        //
        // Sprint 57 placed this guard ABOVE the underrun detection block, but
        // that caused the clock-pause logic to be unreachable: the buffer drained
        // silently while the app waited for the indexer, frames became "late",
        // and the display layer discarded them (Sprint 58 fix).
        //
        // Correct placement: AFTER underrun/buffering so the clock can be paused
        // when the buffer gets critically low, but BEFORE LOW WATERMARK so we
        // don't spin-call feedWindow(0 frames) every cycle.
        if feeder.nextVideoSampleIdx >= feeder.videoSamplesTotal,
           let mkv = mkvDemuxer, !mkv.isFullyIndexed {
            let taskState = backgroundIndexTask != nil ? "running ✅" : "NOT running ⚠️ — re-triggering"
            record("[IndexTask] cursor exhausted but not fully indexed  "
                 + "cursor=\(feeder.nextVideoSampleIdx)=total  "
                 + "indexedDur=\(String(format: "%.1f", mkv.indexedDurationSeconds))s  "
                 + "indexTask=\(taskState)")
            triggerBackgroundIndex(mkv: mkv, to: mkv.indexedDurationSeconds + 60.0)
            return  // wait for indexer — underrun already handled above if needed
        }

        // ── Normal low-watermark refill (Sprint 17) ───────────────────────────
        //
        // Sprint 59: both threshold check and refill sizing use buffered =
        // optimisticBuffered (feeder tail, including frames in pendingVideoQueue).
        // Frames in pendingVideoQueue WILL drain into the layer via
        // requestMediaDataWhenReady — they represent real buffer headroom.
        // Using actualBuffered (layer-only, ~1-2s) here would create a permanent
        // watermark trigger loop since the layer's internal queue is always shallow.
        guard policy.isLowWatermark(bufferedSeconds: buffered) else { return }

        let toFill     = policy.refillSeconds(currentlyBuffered: buffered)
        let videoCount = feeder.videoSamplesFor(seconds: toFill)
        record("[feed] ⚠️ LOW WATERMARK  "
             + "actualBuf=\(String(format: "%.2f", actualBuffered))s  "
             + "optBuf=\(String(format: "%.2f", optimisticBuffered))s  "
             + "pendingQ=\(pendingQ)  "
             + "< \(policy.lowWatermarkSeconds)s  "
             + "cursor=\(feeder.nextVideoSampleIdx)/\(feeder.videoSamplesTotal)  "
             + "feederTail=\(String(format: "%.2f", feeder.lastEnqueuedVideoPTS))s  "
             + "layerTail=\(actualLayerPTS.isValid ? String(format: "%.2f", actualLayerPTS.seconds) : "n/a")s  "
             + "layer=\(renderer.layerStatusDescription)  "
             + "refilling \(String(format: "%.1f", toFill))s ≈\(videoCount) samples")

        let cursorBeforeRefill = feeder.nextVideoSampleIdx
        let tailBeforeRefill   = feeder.lastEnqueuedVideoPTS
        await feeder.feedWindow(videoCount:   videoCount,
                                audioSeconds: toFill,
                                label:        "refill",
                                log:          record(_:))
        framesLoaded = feeder.nextVideoSampleIdx
        record("[feed] ✅ refill done  cursor \(cursorBeforeRefill)→\(feeder.nextVideoSampleIdx)  "
             + "tail \(String(format: "%.2f", tailBeforeRefill))s→\(String(format: "%.2f", feeder.lastEnqueuedVideoPTS))s  "
             + "layer=\(renderer.layerStatusDescription)")
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
        if state == .buffering {
            renderer.synchronizer.rate = 0
            if renderer.audioRendererAttached { renderer.pauseAudioPlayer() }
        }
        stopFeedLoop()
        stopTimeTracking()
        subtitleCoordinator.onPlaybackEnded()   // SC5
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

    // Sprint 54: helper for [P4-diag] log line.
    private func audioRendererStatusLabel() -> String {
        guard renderer.audioRendererAttached else { return "engine not started" }
        return renderer.playerNode.isPlaying ? "▶ playing" : "⏸ paused/stopped"
    }
}
