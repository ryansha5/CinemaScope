// MARK: - PlayerLab / Render / FrameRenderer
//
// Sprint 10 — Frame Rendering Proof
// Sprint 11 — Timed Presentation / Playback Clock
// Sprint 13 — AVSampleBufferRenderSynchronizer for A/V sync
// Sprint 14 — Seek support
//
// Coordinates video (AVSampleBufferDisplayLayer) and audio
// (AVSampleBufferAudioRenderer) via a single AVSampleBufferRenderSynchronizer.
// Accepts compressed CMSampleBuffers directly — decompression happens internally.
//
// Thread safety:
//   All public methods must be called from @MainActor / the main thread.
//
// Usage:
//   let renderer = FrameRenderer()
//   someUIView.layer.addSublayer(renderer.layer)
//   renderer.enqueueVideo(sampleBuffer)
//   renderer.enqueueAudio(sampleBuffer)
//   renderer.play(from: firstPTS)          // anchors timeline at firstPTS
//   renderer.pause() / renderer.resume()
//   renderer.seek(to: pts)                 // after flushing + re-enqueuing

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore

final class FrameRenderer {

    // MARK: - Public surface

    /// The display layer — add to a UIView's layer hierarchy before enqueuing frames.
    let layer = AVSampleBufferDisplayLayer()

    /// Audio renderer — enqueue compressed audio CMSampleBuffers here.
    let audioRenderer = AVSampleBufferAudioRenderer()

    /// The synchronizer coordinates timing for both layer and audioRenderer.
    /// Exposed so the controller can read `synchronizer.timebase` for currentTime.
    let synchronizer = AVSampleBufferRenderSynchronizer()

    /// Number of video sample buffers successfully enqueued.
    private(set) var framesEnqueued: Int = 0

    /// PTS of the first enqueued video sample.
    private(set) var firstFramePTS: CMTime = .invalid

    /// Called on main thread when the very first video frame is enqueued.
    var onFirstFrame: ((CGSize) -> Void)?

    // MARK: - Diagnostic constants

    /// Log per-frame layer status for this many frames, then go quiet.
    private static let kPerFrameStatusCount = 20

    // MARK: - Video-only diagnostic mode
    //
    // When true, audioRenderer is NOT added to the synchronizer and audio
    // samples are silently dropped in enqueueAudio().  This completely
    // decouples audio from the shared AVSampleBufferRenderSynchronizer clock.
    //
    // This is an INSTANCE property (not static) so that the Playback Quarantine
    // Sprint can create a dedicated renderer with audio enabled (videoOnly: false)
    // without affecting the shared video-only renderer used by the main pipeline.
    // Default is true (audio off) — matches the previous static-var behaviour.
    let videoOnlyDiagnostic: Bool

    // MARK: - Init

    /// Whether the audio renderer has been attached to the synchronizer yet.
    /// Starts false even when videoOnly=false — attachment is deferred until
    /// attachAudioRenderer() is called (after AVAudioSession is active).
    private(set) var audioRendererAttached: Bool = false

    /// - Parameter videoOnly: When `true` (default) the audio renderer is NOT
    ///   attached to the synchronizer and `enqueueAudio()` is a no-op.  Pass
    ///   `false` only from the Playback Quarantine audio-isolation phase where
    ///   audio is being tested in a fully separate controller instance.
    init(videoOnly: Bool = true) {
        videoOnlyDiagnostic = videoOnly

        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        synchronizer.addRenderer(layer)
        // Audio renderer is NOT added here even when videoOnly=false.
        // Attaching an un-primed AVSampleBufferAudioRenderer before the
        // AVAudioSession is active causes the synchronizer to stall its
        // timebase, making the clock appear to run (rate=1) while frames
        // are never actually presented.  Call attachAudioRenderer() after
        // the audio session is active and just before audio samples flow.

        synchronizer.rate = 0   // start paused
        fputs("[FrameRenderer] Synchronizer created — "
            + (videoOnly ? "video-only (audio renderer deferred)" : "video layer only (audio deferred — call attachAudioRenderer)")
            + " attached\n", stderr)
    }

    /// Attach the audio renderer to the synchronizer.
    ///
    /// Call this AFTER `AVAudioSession.setActive(true)` and BEFORE enqueuing
    /// the first audio sample.  Calling more than once is a no-op.
    ///
    /// No-op when `videoOnlyDiagnostic == true`.
    func attachAudioRenderer() {
        guard !videoOnlyDiagnostic, !audioRendererAttached else { return }
        synchronizer.addRenderer(audioRenderer)
        audioRendererAttached = true
        fputs("[FrameRenderer] ✅ audioRenderer attached to synchronizer\n", stderr)
    }

    // MARK: - Enqueue

    /// Enqueue one compressed video CMSampleBuffer.
    ///
    /// - Parameter sampleIndex: Absolute 0-based index of this sample in the
    ///   video track.  Used for per-frame diagnostic logging.
    func enqueueVideo(_ sampleBuffer: CMSampleBuffer, sampleIndex: Int = -1) {

        // ── Layer status before enqueue ───────────────────────────────────────
        let statusBefore = layer.status
        let readyBefore  = layer.isReadyForMoreMediaData

        if statusBefore == .failed {
            let errDesc = layer.error?.localizedDescription ?? "?"
            fputs("[FrameRenderer] ⚠️ layer.status=.failed before enqueue  "
                + "idx=\(sampleIndex)  err=\(errDesc) — flushing\n", stderr)
            layer.flush()
        }

        if !readyBefore {
            fputs("[FrameRenderer] ⚠️ isReadyForMoreMediaData=false  "
                + "idx=\(sampleIndex) — layer queue may be full\n", stderr)
        }

        // ── Enqueue ───────────────────────────────────────────────────────────
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        layer.enqueue(sampleBuffer)
        let isFirst = (framesEnqueued == 0)
        framesEnqueued += 1

        // ── Status after enqueue ──────────────────────────────────────────────
        let statusAfter = layer.status
        let readyAfter  = layer.isReadyForMoreMediaData
        let errAfter    = layer.error

        // Per-frame log for first kPerFrameStatusCount samples (always on stderr)
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

    /// Enqueue one compressed audio CMSampleBuffer.
    /// No-op when videoOnlyDiagnostic is true.
    func enqueueAudio(_ sampleBuffer: CMSampleBuffer) {
        guard !videoOnlyDiagnostic, audioRendererAttached else { return }
        audioRenderer.enqueue(sampleBuffer)
    }

    // MARK: - Transport

    /// Start playback.  `startPTS` is the video timeline position to begin from —
    /// the synchronizer anchors its clock there so the first frame appears immediately.
    func play(from startPTS: CMTime) {
        // Step 1: anchor the timeline at startPTS with rate=0 (time-only, no start yet).
        synchronizer.setRate(0, time: startPTS)

        // Step 2: start the clock without moving the anchor.
        synchronizer.setRate(1, time: .invalid)

        // Belt-and-suspenders: set the .rate property directly as well.
        synchronizer.rate = 1

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
        fputs("[FrameRenderer] pause() — synchronizer rate=0\n", stderr)
    }

    /// Resume from the current position after pause().
    func resume() {
        synchronizer.setRate(1, time: .invalid)
        fputs("[FrameRenderer] resume() — synchronizer rate=1\n", stderr)
    }

    /// Seek to `pts` in the video timeline.
    /// Caller must flush the appropriate renderer(s) and re-enqueue packets
    /// before calling this — the synchronizer will start presenting from `pts`.
    func seek(to pts: CMTime) {
        synchronizer.setRate(synchronizer.rate, time: pts)
        fputs("[FrameRenderer] seek(to: \(String(format: "%.4f", pts.seconds))s)\n", stderr)
    }

    /// Current video time from the synchronizer's timebase.
    var currentTime: CMTime {
        CMTimebaseGetTime(synchronizer.timebase)
    }

    // MARK: - Reset

    /// Flush all enqueued frames (video + audio) and reset to initial state.
    /// Call before loading a new stream or before a seek.
    func flushAll() {
        synchronizer.rate = 0
        layer.flushAndRemoveImage()

        // Re-arm isReadyForMoreMediaData.
        layer.requestMediaDataWhenReady(on: .main) { [weak self] in
            self?.layer.stopRequestingMediaData()
        }

        if !videoOnlyDiagnostic && audioRendererAttached { audioRenderer.flush() }
        framesEnqueued = 0
        firstFramePTS  = .invalid
        fputs("[FrameRenderer] flushAll() — layer + audio cleared, rate=0\n", stderr)
    }

    /// Flush only the video layer (keeps audio running, e.g. mid-seek).
    func flushVideo() {
        layer.flush()
        framesEnqueued = 0
        firstFramePTS  = .invalid
    }

    /// Flush only the audio renderer.
    func flushAudio() {
        if !videoOnlyDiagnostic && audioRendererAttached { audioRenderer.flush() }
    }

    /// Flush both renderers in preparation for a seek.
    ///
    /// This is the correct seek-flush sequence recommended by Apple:
    ///   1. Set synchronizer rate to 0 (pause) so the pipeline is quiescent.
    ///   2. Call flushAndRemoveImage() on the display layer to clear the
    ///      visible image and all pending frames synchronously.
    ///   3. Call requestMediaDataWhenReady (immediately cancelled) to reset
    ///      the layer's isReadyForMoreMediaData flag.  flushAndRemoveImage()
    ///      cancels any outstanding requestMediaDataWhenReady registrations,
    ///      which leaves isReadyForMoreMediaData=false permanently.  This
    ///      one-shot call (immediately followed by stopRequestingMediaData)
    ///      re-arms the flag without setting up a persistent callback.
    ///   4. Flush the audio renderer.
    ///
    /// The caller is responsible for calling setRate(_:time:) after
    /// re-enqueuing frames to restart the clock at the new position.
    func flushForSeek() {
        synchronizer.rate = 0           // quiesce pipeline before flush
        layer.flushAndRemoveImage()     // clears displayed image + pending frames

        // Re-arm isReadyForMoreMediaData.
        layer.requestMediaDataWhenReady(on: .main) { [weak self] in
            self?.layer.stopRequestingMediaData()
        }

        if !videoOnlyDiagnostic && audioRendererAttached { audioRenderer.flush() }
        framesEnqueued = 0
        firstFramePTS  = .invalid
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
}
