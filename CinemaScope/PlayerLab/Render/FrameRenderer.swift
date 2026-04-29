// MARK: - PlayerLab / Render / FrameRenderer
//
// Sprint 10 — Frame Rendering Proof
// Sprint 11 — Timed Presentation / Playback Clock
// Sprint 13 — AVSampleBufferRenderSynchronizer for A/V sync
// Sprint 14 — Seek support
// Sprint 52 — Phase 4 audio: dual-synchronizer architecture.
//             Deployed but confirmed broken on tvOS hardware AND simulator:
//             aTbRate=0.0 even with dedicated audioSynchronizer — the
//             underlying CMTimebase never starts.  Replaced in Sprint 54.
// Sprint 54 — Phase 4 audio fix: AVSampleBufferAudioRenderer is gone.
//             New path: CMSampleBuffer (AAC)
//                       → AVAudioConverter (AAC → Float32 PCM)
//                       → AVAudioPlayerNode  (sequential buffer scheduling)
//                       → AVAudioEngine      → hardware output
//
//             playerNode.play() is called at the same wall-clock instant as
//             synchronizer.setRate(1, time: startPTS), anchoring A/V together.
//             Both run on system-clock-backed hardware; typical drift is
//             < 1 ms/minute for standard content.
//
// Thread safety:
//   All public methods must be called from @MainActor / the main thread.
//
// Usage:
//   let renderer = FrameRenderer()
//   someUIView.layer.addSublayer(renderer.layer)
//   renderer.enqueueVideo(sampleBuffer)
//   renderer.enqueueAudio(sampleBuffer)            // no-op if videoOnly=true
//   renderer.startAudioEngine(inputDesc: fmtDesc)  // call after AVAudioSession.setActive
//   renderer.play(from: firstPTS)                  // starts video clock + audio player
//   renderer.pause() / renderer.resume()
//   renderer.seek(to: pts)                         // after flushForSeek() + re-enqueue

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore

final class FrameRenderer {

    // MARK: - Public surface

    /// The display layer — add to a UIView's layer hierarchy before enqueuing frames.
    let layer = AVSampleBufferDisplayLayer()

    /// The synchronizer that drives the video display layer.
    /// Exposed so the controller can read `synchronizer.timebase` for currentTime.
    let synchronizer = AVSampleBufferRenderSynchronizer()

    // MARK: - Audio Engine (Sprint 54)
    //
    // AVSampleBufferRenderSynchronizer.setRate(1) is confirmed broken on tvOS
    // for audio: the underlying CMTimebase stays at rate=0 even when the audio
    // renderer is on a dedicated synchronizer with no display layer attached.
    // Confirmed on both tvOS simulator and real Apple TV hardware.
    //
    // Sprint 54 replaces the broken path with:
    //   CMSampleBuffer (AAC)  →  AVAudioConverter  →  AVAudioPCMBuffer
    //   →  AVAudioPlayerNode (sequential schedule)  →  AVAudioEngine  →  output
    //
    // startAudioEngine(inputDesc:) is the new entry point (was attachAudioRenderer()).
    // playerNode is exposed so the controller can call isPlaying for diagnostics.

    // Lazy so that AVAudioEngine() is NOT created at object-init time.
    // Creating AVAudioEngine() eagerly can trap on tvOS simulator when the
    // audio HAL is in a bad state (AQMEIO_HAL timeout / "no device with given ID").
    // Deferring creation to startAudioEngine() means the view loads cleanly even
    // if the audio subsystem is temporarily broken.
    private lazy var audioEngine  = AVAudioEngine()

    /// The audio player node within the engine.  Exposed for controller diagnostics.
    /// Lazy for the same reason as audioEngine — deferred creation avoids HAL-state crashes.
    lazy var playerNode = AVAudioPlayerNode()

    private var audioConverter:  AVAudioConverter?
    private var pcmOutputFormat: AVAudioFormat?
    private var aacInputFormat:  AVAudioFormat?

    // MARK: - Counters / callbacks

    /// Number of video sample buffers successfully enqueued to the display layer.
    private(set) var framesEnqueued: Int = 0

    /// PTS of the last frame actually handed to layer.enqueue() inside performLayerEnqueue().
    ///
    /// Sprint 59: This is the *real* video buffer tail — updated only when the frame
    /// physically reaches AVSampleBufferDisplayLayer, not when it is appended to
    /// pendingVideoQueue.  feeder.lastEnqueuedVideoPTS advances immediately when frames
    /// are appended to pendingVideoQueue; this property lags behind until
    /// isReadyForMoreMediaData fires and drainVideoQueue() delivers the frames.
    ///
    /// Use this (not feeder.lastEnqueuedVideoPTS) for buffer-depth calculations that
    /// drive underrun detection and watermark triggers.  The difference between the two
    /// is the "pending lag" — frames the pipeline thinks are buffered but the display
    /// layer hasn't accepted yet.
    private(set) var actualLayerEnqueuedMaxPTS: CMTime = .invalid

    /// Number of frames currently sitting in pendingVideoQueue, waiting for
    /// isReadyForMoreMediaData to become true so drainVideoQueue() can deliver them.
    /// Non-zero means the display layer's internal queue is full; these frames have
    /// NOT yet been handed to layer.enqueue().
    var pendingVideoQueueCount: Int { pendingVideoQueue.count }

    /// PTS of the first enqueued video sample.
    private(set) var firstFramePTS: CMTime = .invalid

    /// Called on main thread when the very first video frame is enqueued.
    var onFirstFrame: ((CGSize) -> Void)?

    // MARK: - Video pull-model queue (Sprint 56)
    //
    // AVSampleBufferDisplayLayer should be fed via requestMediaDataWhenReady, not by
    // calling enqueue() in a tight loop.  When enqueue() is called while
    // isReadyForMoreMediaData=false, the documentation states the call has no effect
    // (frames are silently dropped).  This caused the "same frames distorted every run"
    // symptom: the 285-frame initial batch saturated the layer's queue at ~50 frames,
    // and all subsequent enqueue() calls were silently no-ops.
    //
    // Fix: pendingVideoQueue buffers all incoming CMSampleBuffers.  drainVideoQueue()
    // feeds them to the layer at the layer's own pace, gated on isReadyForMoreMediaData.
    // requestMediaDataWhenReady is registered whenever the queue is non-empty, ensuring
    // the layer calls back to drain remaining frames as it consumes prior ones.

    private var pendingVideoQueue: [(buffer: CMSampleBuffer, sampleIndex: Int)] = []
    private var mediaCallbackActive: Bool = false

    // MARK: - Diagnostic constants

    /// Log per-frame layer status for this many frames, then go quiet.
    private static let kPerFrameStatusCount = 20

    // MARK: - Video-only diagnostic mode
    //
    // When true, the audio engine is not started and audio samples are silently
    // dropped.  This is an INSTANCE property so that the Playback Quarantine
    // Sprint can create a dedicated renderer with audio enabled (videoOnly: false)
    // without affecting any shared video-only renderer.
    // Default is true (audio off).
    let videoOnlyDiagnostic: Bool

    // MARK: - Audio engine state

    /// Whether startAudioEngine(inputDesc:) has succeeded.
    /// False until the engine is running and the player node is wired.
    private(set) var audioRendererAttached: Bool = false

    // MARK: - Init

    /// - Parameter videoOnly: When `true` (default) the audio engine is NOT started
    ///   and `enqueueAudio()` is a no-op.  Pass `false` only from the Playback
    ///   Quarantine audio-isolation phase (Phase 4).
    init(videoOnly: Bool = true) {
        videoOnlyDiagnostic = videoOnly

        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        synchronizer.addRenderer(layer)
        synchronizer.rate = 0   // start paused

        fputs("[FrameRenderer] init videoOnly=\(videoOnly) — "
            + (videoOnly
               ? "video synchronizer created (audio engine will not be used)"
               : "video synchronizer created — call startAudioEngine(inputDesc:) after AVAudioSession.setActive")
            + "\n", stderr)
    }

    /// Wire up the AVAudioEngine for compressed audio playback.
    ///
    /// Call this AFTER `AVAudioSession.setActive(true)` and BEFORE enqueuing
    /// the first audio sample.  Calling more than once is a no-op.
    ///
    /// No-op when `videoOnlyDiagnostic == true`.
    ///
    /// Sprint 54: replaces `attachAudioRenderer()`.  Initialises an
    /// `AVAudioConverter` (AAC → Float32 PCM) and wires `playerNode` into
    /// the engine — bypasses the broken `AVSampleBufferRenderSynchronizer`
    /// audio path that silently freezes the clock at rate=0 on tvOS.
    func startAudioEngine(inputDesc: CMAudioFormatDescription) {
        guard !videoOnlyDiagnostic, !audioRendererAttached else { return }

        // ── Input format ─────────────────────────────────────────────────────────
        // AVAudioFormat(cmAudioFormatDescription:) is the correct path for compressed
        // formats.  It was previously crashing AVAudioConverter with EXC_BAD_ACCESS
        // because AudioFormatFactory built the CMAudioFormatDescription without an
        // AudioChannelLayout (layoutSize=0).  AVAudioFormat then ended up with a nil
        // internal layout pointer, which AVAudioConverter dereferenced → crash.
        //
        // AudioFormatFactory.makeMPEG4AAC now always embeds an explicit layout
        // (e.g. kAudioChannelLayoutTag_MPEG_5_1_A for 6-ch), so this path is safe.
        let inFmt = AVAudioFormat(cmAudioFormatDescription: inputDesc)
        aacInputFormat = inFmt

        let sr = inFmt.sampleRate
        let ch = inFmt.channelCount
        fputs("[FrameRenderer] [S54-pre] inFmt sr=\(Int(sr)) ch=\(ch) "
            + "layout=\(inFmt.channelLayout?.description ?? "nil")\n", stderr)

        // PCM output format: Float32 non-interleaved (the AVAudioEngine "standard" format).
        //
        // AVAudioFormat(commonFormat:sampleRate:channels:interleaved:) returns nil for
        // multi-channel non-interleaved on the tvOS simulator.
        // AVAudioFormat(standardFormatWithSampleRate:channelLayout:) is non-failable
        // and always produces Float32 non-interleaved — exactly what AVAudioEngine needs.
        let outLayoutTag: AudioChannelLayoutTag
        switch ch {
        case 1:  outLayoutTag = kAudioChannelLayoutTag_Mono
        case 2:  outLayoutTag = kAudioChannelLayoutTag_Stereo
        case 3:  outLayoutTag = kAudioChannelLayoutTag_MPEG_3_0_A
        case 4:  outLayoutTag = kAudioChannelLayoutTag_MPEG_4_0_A
        case 5:  outLayoutTag = kAudioChannelLayoutTag_MPEG_5_0_A
        case 6:  outLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
        case 7:  outLayoutTag = kAudioChannelLayoutTag_MPEG_6_1_A
        case 8:  outLayoutTag = kAudioChannelLayoutTag_MPEG_7_1_A
        default: outLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder
                               | AudioChannelLayoutTag(ch)
        }
        guard let outChannelLayout = AVAudioChannelLayout(layoutTag: outLayoutTag) else {
            fputs("[FrameRenderer] ❌ startAudioEngine: could not create output AVAudioChannelLayout "
                + "tag=\(outLayoutTag) ch=\(ch)\n", stderr)
            return
        }
        let outFmt = AVAudioFormat(standardFormatWithSampleRate: sr, channelLayout: outChannelLayout)
        pcmOutputFormat = outFmt

        // Create the AAC → PCM converter.
        fputs("[FrameRenderer] [S54-pre] Creating AVAudioConverter…\n", stderr)
        guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
            fputs("[FrameRenderer] ❌ startAudioEngine: AVAudioConverter init failed (returned nil)\n",
                  stderr)
            return
        }

        // Set the magic cookie on the converter so the AAC decoder has the
        // AudioSpecificConfig it needs.
        var cookieSize: Int = 0
        if let cookiePtr = CMAudioFormatDescriptionGetMagicCookie(inputDesc,
                                                                    sizeOut: &cookieSize),
           cookieSize > 0 {
            conv.magicCookie = Data(bytes: cookiePtr, count: cookieSize)
            fputs("[FrameRenderer] [S54-pre] magic cookie set (\(cookieSize) bytes)\n", stderr)
        } else {
            fputs("[FrameRenderer] ⚠️ startAudioEngine: no magic cookie in format desc\n", stderr)
        }

        audioConverter = conv

        // Wire the player node into the engine: playerNode → mainMixerNode → output
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: outFmt)

        do {
            try audioEngine.start()
            audioRendererAttached = true
            fputs("[FrameRenderer] ✅ AVAudioEngine started (Sprint 54 audio path)  "
                + "sr=\(Int(sr))Hz  ch=\(ch)\n", stderr)
        } catch {
            fputs("[FrameRenderer] ❌ AVAudioEngine start failed: \(error.localizedDescription)\n",
                  stderr)
        }
    }

    // MARK: - Enqueue

    /// Enqueue one compressed video CMSampleBuffer.
    ///
    /// Sprint 56: Uses a pull model (requestMediaDataWhenReady) instead of pushing
    /// directly to layer.enqueue().  The buffer is queued in pendingVideoQueue and
    /// fed to the layer only when isReadyForMoreMediaData=true, preventing silent
    /// frame drops that were causing deterministic visual distortion.
    ///
    /// - Parameter sampleIndex: Absolute 0-based index of this sample in the
    ///   video track.  Used for per-frame diagnostic logging.
    func enqueueVideo(_ sampleBuffer: CMSampleBuffer, sampleIndex: Int = -1) {
        pendingVideoQueue.append((buffer: sampleBuffer, sampleIndex: sampleIndex))
        drainVideoQueue()
        ensureMediaCallbackRegistered()
    }

    /// Feeds as many frames from pendingVideoQueue to the display layer as the
    /// layer will accept right now (while isReadyForMoreMediaData is true).
    private func drainVideoQueue() {
        while layer.isReadyForMoreMediaData, !pendingVideoQueue.isEmpty {
            let entry = pendingVideoQueue.removeFirst()
            performLayerEnqueue(entry.buffer, sampleIndex: entry.sampleIndex)
        }
    }

    /// Registers a requestMediaDataWhenReady callback if one is not already active.
    /// The callback drains pendingVideoQueue as the layer becomes ready for more data,
    /// and cancels itself when the queue is empty.
    private func ensureMediaCallbackRegistered() {
        guard !pendingVideoQueue.isEmpty, !mediaCallbackActive else { return }
        mediaCallbackActive = true
        layer.requestMediaDataWhenReady(on: .main) { [weak self] in
            guard let self else { return }
            self.drainVideoQueue()
            if self.pendingVideoQueue.isEmpty {
                self.layer.stopRequestingMediaData()
                self.mediaCallbackActive = false
            }
        }
    }

    /// Performs the actual layer.enqueue() call plus all associated diagnostics.
    /// Only called from drainVideoQueue() when isReadyForMoreMediaData is confirmed true.
    private func performLayerEnqueue(_ sampleBuffer: CMSampleBuffer, sampleIndex: Int) {

        // ── Layer status check ────────────────────────────────────────────────
        if layer.status == .failed {
            let errDesc = layer.error?.localizedDescription ?? "?"
            fputs("[FrameRenderer] ⚠️ layer.status=.failed before enqueue  "
                + "idx=\(sampleIndex)  err=\(errDesc) — flushing\n", stderr)
            layer.flush()
        }

        // ── Enqueue ───────────────────────────────────────────────────────────
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        layer.enqueue(sampleBuffer)
        let isFirst = (framesEnqueued == 0)
        framesEnqueued += 1

        // Sprint 59: track the highest PTS that has actually reached the layer.
        // This is the ground-truth buffer tail used by the feed loop for underrun
        // detection.  It lags feeder.lastEnqueuedVideoPTS by however many frames
        // are queued in pendingVideoQueue waiting for isReadyForMoreMediaData.
        if pts.isValid {
            if !actualLayerEnqueuedMaxPTS.isValid
                || CMTimeCompare(pts, actualLayerEnqueuedMaxPTS) > 0 {
                actualLayerEnqueuedMaxPTS = pts
            }
        }

        // ── Status after enqueue ──────────────────────────────────────────────
        let statusAfter = layer.status
        let readyAfter  = layer.isReadyForMoreMediaData
        let errAfter    = layer.error

        // Per-frame log for first kPerFrameStatusCount samples
        if framesEnqueued <= FrameRenderer.kPerFrameStatusCount {
            let statusName: String
            switch statusAfter {
            case .unknown:    statusName = "unknown"
            case .rendering:  statusName = "rendering"
            case .failed:     statusName = "failed"
            @unknown default: statusName = "unknownFuture"
            }
            let tbRate = CMTimebaseGetRate(synchronizer.timebase)
            let tbTime = CMTimebaseGetTime(synchronizer.timebase)
            let tbStr  = "tbRate=\(tbRate)  tbTime=\(tbTime.isValid ? String(format: "%.3f", tbTime.seconds) + "s" : "invalid")"
            fputs("[FrameRenderer] enqueue[\(framesEnqueued - 1)] "
                + "idx=\(sampleIndex)  "
                + "pts=\(String(format: "%.3f", pts.seconds))s  "
                + "dts=\(dts.isValid ? String(format: "%.3f", dts.seconds) + "s" : "invalid")  "
                + "status=\(statusName)  "
                + "ready=\(readyAfter)  "
                + tbStr + "  "
                + "\(errAfter != nil ? "❌ err=\(errAfter!.localizedDescription)" : "✅")\n",
                stderr)
        }

        if statusAfter == .failed {
            let errDesc = errAfter?.localizedDescription ?? "?"
            fputs("[FrameRenderer] ❌ layer.status=.failed after enqueue  "
                + "idx=\(sampleIndex)  err=\(errDesc)\n", stderr)
        }

        // ── First-frame callback ──────────────────────────────────────────────
        if isFirst {
            firstFramePTS = pts
            if let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
                let dims = CMVideoFormatDescriptionGetDimensions(fmt)
                let size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
                fputs("[FrameRenderer] ✅ First frame enqueued — "
                    + "PTS=\(String(format: "%.4f", firstFramePTS.seconds))s  "
                    + "dims=\(Int(size.width))×\(Int(size.height))\n", stderr)
                onFirstFrame?(size)
            }
        }
    }

    // MARK: - Audio conversion serial queue (Sprint 56)
    //
    // AAC→PCM conversion via AVAudioConverter is synchronous and takes ~14 ms per
    // packet on the tvOS simulator (~0.5 ms on real hardware, hardware-accelerated).
    // Calling enqueueAudio() in a tight loop for a 263-frame batch (513 audio packets)
    // blocked the main thread for ~7 seconds, which pushed the refill completion time
    // well past the buffer watermark and caused a ~6 s underrun.  The display layer
    // then received ~268 frames whose PTS was already "in the past" — these were the
    // deterministic distorted frames the user observed.
    //
    // Fix: a serial DispatchQueue runs each conversion off the main thread.  Converted
    // PCM buffers are scheduled onto playerNode from that same queue (AVAudioPlayerNode
    // is thread-safe; ordering is preserved by the serial queue).
    //
    // The queue is serial (not concurrent) so buffers are scheduled in the correct order
    // even if individual conversions vary in duration.

    private let audioConversionQueue = DispatchQueue(label: "com.cinemascope.audioConvert",
                                                     qos: .userInteractive)

    /// Enqueue one compressed audio CMSampleBuffer.
    ///
    /// Sprint 54: Converts AAC → Float32 PCM via AVAudioConverter, then
    /// schedules the PCM buffer sequentially on the AVAudioPlayerNode.
    ///
    /// Sprint 56: Conversion is dispatched to a serial background queue so that
    /// bulk enqueue of hundreds of packets (during a refill cycle) does not block
    /// the main thread.  Ordering is preserved by the serial queue.
    ///
    /// No-op when videoOnlyDiagnostic is true or startAudioEngine has not been called.
    func enqueueAudio(_ sampleBuffer: CMSampleBuffer) {
        guard !videoOnlyDiagnostic,
              audioRendererAttached,
              let converter = audioConverter,
              let pcmFmt    = pcmOutputFormat,
              let inFmt     = aacInputFormat else { return }

        // ── Extract compressed AAC bytes from CMSampleBuffer ──────────────────
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let dataLength = CMBlockBufferGetDataLength(blockBuffer)
        guard dataLength > 0 else { return }

        // AVAudioConverter imposes a 6144-byte maximum packet size for VBR AAC.
        let kAACMaxPacketBytes = 6144
        if dataLength > kAACMaxPacketBytes {
            fputs("[FrameRenderer] [S54] oversized AAC packet skipped: \(dataLength) B > \(kAACMaxPacketBytes) B\n",
                  stderr)
            return
        }

        var aacBytes = [UInt8](repeating: 0, count: dataLength)
        guard CMBlockBufferCopyDataBytes(blockBuffer,
                                         atOffset:    0,
                                         dataLength:  dataLength,
                                         destination: &aacBytes) == kCMBlockBufferNoErr else { return }

        // Capture everything needed for conversion before dispatching.
        // The serial queue ensures in-order scheduling even if conversion
        // durations vary.
        let node = playerNode
        audioConversionQueue.async {
            // ── Build AVAudioCompressedBuffer (converter input) ───────────────
            let compBuf = AVAudioCompressedBuffer(format:            inFmt,
                                                  packetCapacity:    1,
                                                  maximumPacketSize: dataLength)
            aacBytes.withUnsafeBytes { ptr in
                compBuf.data.copyMemory(from: ptr.baseAddress!, byteCount: dataLength)
            }
            compBuf.byteLength  = UInt32(dataLength)
            compBuf.packetCount = 1
            if let descs = compBuf.packetDescriptions {
                descs[0] = AudioStreamPacketDescription(mStartOffset:            0,
                                                        mVariableFramesInPacket: 0,
                                                        mDataByteSize:           UInt32(dataLength))
            }

            // ── Build AVAudioPCMBuffer (converter output) ─────────────────────
            let outputFrameCapacity = AVAudioFrameCount(2048)
            guard let pcmBuf = AVAudioPCMBuffer(pcmFormat:     pcmFmt,
                                                 frameCapacity: outputFrameCapacity) else { return }

            // ── Convert: AAC compressed → PCM ────────────────────────────────
            var convErr:    NSError?
            var inputGiven: Bool = false

            _ = converter.convert(to: pcmBuf, error: &convErr) { _, outStatus in
                if inputGiven {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputGiven = true
                outStatus.pointee = .haveData
                return compBuf
            }

            if let err = convErr {
                fputs("[FrameRenderer] [S54] AAC→PCM convert error: \(err.localizedDescription)\n", stderr)
                return
            }

            guard pcmBuf.frameLength > 0 else { return }

            // ── Schedule PCM buffer on the player node ────────────────────────
            // AVAudioPlayerNode.scheduleBuffer is thread-safe; the serial queue
            // guarantees in-order scheduling.
            node.scheduleBuffer(pcmBuf, completionHandler: nil)
        }
    }

    // MARK: - Transport

    /// Start playback.  `startPTS` is the video timeline position to begin from.
    /// The video synchronizer is anchored at startPTS and the audio player node
    /// is started at the same wall-clock instant to maintain A/V sync.
    func play(from startPTS: CMTime) {
        // ── Audio engine (Sprint 54) — start BEFORE video clock ──────────────
        // playerNode.play() must be called BEFORE synchronizer.setRate(1) so
        // that any HAL reconfiguration latency (up to ~2.5 s on tvOS simulator)
        // is absorbed before the video clock starts ticking.  If the clock were
        // started first, the HAL delay would cause tbTime to advance past the
        // PTS of all pre-buffered frames, leaving the display layer with nothing
        // to show → black screen.
        if !videoOnlyDiagnostic && audioRendererAttached {
            playerNode.play()
            fputs("[FrameRenderer] [P4/Sprint54] playerNode.play()  "
                + "isPlaying=\(playerNode.isPlaying)  "
                + (playerNode.isPlaying ? "✅ audio running" : "❌ player node not running")
                + "\n", stderr)
        }

        // ── Video synchronizer ────────────────────────────────────────────────
        // Clock starts here, after audio player is already running.
        synchronizer.setRate(0, time: startPTS)
        synchronizer.setRate(1, time: .invalid)
        synchronizer.rate = 1

        // ── Diagnostics ───────────────────────────────────────────────────────
        let syncRate = synchronizer.rate
        let tbRate   = CMTimebaseGetRate(synchronizer.timebase)
        let tbTime   = CMTimebaseGetTime(synchronizer.timebase)
        fputs("[FrameRenderer] play(from: \(String(format: "%.4f", startPTS.seconds))s)  "
            + "syncRate=\(syncRate)  tbRate=\(tbRate)  "
            + "tbTime=\(tbTime.isValid ? String(format: "%.3f", tbTime.seconds) + "s" : "invalid")  "
            + "framesEnqueued=\(framesEnqueued)\n", stderr)
    }

    /// Freeze playback at the current position.
    func pause() {
        synchronizer.rate = 0
        if !videoOnlyDiagnostic && audioRendererAttached {
            playerNode.pause()
        }
        fputs("[FrameRenderer] pause() — synchronizer rate=0  playerNode paused\n", stderr)
    }

    /// Resume from the current position after pause().
    func resume() {
        synchronizer.setRate(1, time: .invalid)
        if !videoOnlyDiagnostic && audioRendererAttached {
            playerNode.play()
        }
        fputs("[FrameRenderer] resume() — synchronizer rate=1  playerNode resumed\n", stderr)
    }

    /// Seek to `pts` in the video timeline.
    ///
    /// Caller must call `flushForSeek()` first to stop audio and clear queues,
    /// then re-enqueue packets before calling this, then call `resumeAudioIfNeeded()`
    /// if wasPlaying was true.
    func seek(to pts: CMTime) {
        let rate = synchronizer.rate
        synchronizer.setRate(rate, time: pts)
        // playerNode was already stopped by flushForSeek().
        // The controller calls resumeAudioIfNeeded() after re-enqueuing if wasPlaying.
        fputs("[FrameRenderer] seek(to: \(String(format: "%.4f", pts.seconds))s)  "
            + "rate=\(rate)\n", stderr)
    }

    /// Start the audio player node if it is not currently playing.
    ///
    /// Call this after a seek or underrun-recovery when the video synchronizer
    /// has been re-started and audio should resume.  Replaces the old
    /// `audioSynchronizer.setRate(1, ...)` pattern from Sprint 52.
    func resumeAudioIfNeeded() {
        guard !videoOnlyDiagnostic && audioRendererAttached else { return }
        if !playerNode.isPlaying {
            playerNode.play()
            fputs("[FrameRenderer] resumeAudioIfNeeded() → playerNode.play()\n", stderr)
        }
    }

    /// Pause the audio player node directly.
    ///
    /// Use for underrun detection and end-of-stream where the video synchronizer
    /// clock is paused independently.  Replaces `audioSynchronizer.rate = 0`.
    func pauseAudioPlayer() {
        guard !videoOnlyDiagnostic && audioRendererAttached else { return }
        playerNode.pause()
    }

    /// Current video time from the video synchronizer's timebase.
    var currentTime: CMTime {
        CMTimebaseGetTime(synchronizer.timebase)
    }

    // MARK: - Reset

    /// Flush all enqueued frames (video + audio) and reset to initial state.
    /// Call before loading a new stream or before a seek.
    func flushAll() {
        synchronizer.rate = 0
        layer.flushAndRemoveImage()

        // Clear the pending queue and cancel any outstanding media callback.
        pendingVideoQueue.removeAll()
        if mediaCallbackActive {
            layer.stopRequestingMediaData()
            mediaCallbackActive = false
        }

        if !videoOnlyDiagnostic && audioRendererAttached {
            playerNode.stop()   // stop() clears all scheduled PCM buffers
        }
        framesEnqueued = 0
        firstFramePTS  = .invalid
        actualLayerEnqueuedMaxPTS = .invalid   // Sprint 59: reset layer-tail tracking
        fputs("[FrameRenderer] flushAll() — layer + audio cleared, rate=0\n", stderr)
    }

    /// Flush only the video layer (leaves audio player running, e.g. mid-seek).
    func flushVideo() {
        layer.flush()
        pendingVideoQueue.removeAll()
        if mediaCallbackActive {
            layer.stopRequestingMediaData()
            mediaCallbackActive = false
        }
        framesEnqueued = 0
        firstFramePTS  = .invalid
        actualLayerEnqueuedMaxPTS = .invalid   // Sprint 59: reset layer-tail tracking
    }

    /// Flush only the audio player (clears all scheduled PCM buffers and stops).
    func flushAudio() {
        if !videoOnlyDiagnostic && audioRendererAttached {
            playerNode.stop()
        }
    }

    /// Flush both renderers in preparation for a seek.
    ///
    /// Correct seek-flush sequence:
    ///   1. Pause video synchronizer (quiesce pipeline).
    ///   2. flushAndRemoveImage() clears the display layer + all pending frames.
    ///   3. Clear pendingVideoQueue + stop media callback (Sprint 56 pull model).
    ///      flushAndRemoveImage() cancels any existing requestMediaDataWhenReady
    ///      registrations.  The Sprint 56 mediaCallbackActive flag is also cleared
    ///      so ensureMediaCallbackRegistered() re-registers on the next enqueueVideo.
    ///   4. playerNode.stop() clears all scheduled PCM audio buffers.
    ///
    /// After re-enqueuing, the caller must call resumeAudioIfNeeded() if
    /// wasPlaying=true to restart the audio player node.
    func flushForSeek() {
        synchronizer.rate = 0
        layer.flushAndRemoveImage()

        // Clear pending queue and reset media callback state.
        // flushAndRemoveImage() has already cancelled the existing callback in the layer;
        // we just need to clear our own state so ensureMediaCallbackRegistered re-registers.
        pendingVideoQueue.removeAll()
        mediaCallbackActive = false

        if !videoOnlyDiagnostic && audioRendererAttached {
            playerNode.stop()   // clears all scheduled PCM buffers
        }
        framesEnqueued = 0
        firstFramePTS  = .invalid
        actualLayerEnqueuedMaxPTS = .invalid   // Sprint 59: reset layer-tail tracking
        fputs("[FrameRenderer] flushForSeek() — pipeline quiesced, layer + audio cleared\n", stderr)
    }

    // MARK: - Status

    var layerStatusDescription: String {
        switch layer.status {
        case .unknown:    return "unknown"
        case .rendering:  return "rendering"
        case .failed:     return "failed(\(layer.error?.localizedDescription ?? "?"))"
        @unknown default: return "unknownFuture"
        }
    }

    /// Sprint 54 diagnostic: video synchronizer clock + audio engine state.
    /// Replaces the Sprint 52 dual-synchronizer clock diagnostic.
    var dualSyncDiagnostic: String {
        guard !videoOnlyDiagnostic && audioRendererAttached else {
            return "audioEngine=n/a"
        }
        let vRate    = CMTimebaseGetRate(synchronizer.timebase)
        let vTime    = CMTimebaseGetTime(synchronizer.timebase)
        let vTimeStr = vTime.isValid ? String(format: "%.3f", vTime.seconds) + "s" : "invalid"
        let engStr   = audioEngine.isRunning ? "✅ running" : "❌ stopped"
        let nodeStr  = playerNode.isPlaying  ? "▶ playing" : "⏸ paused/stopped"
        return "vTbRate=\(vRate)  vTime=\(vTimeStr)  audioEngine=\(engStr)  playerNode=\(nodeStr)"
    }
}
