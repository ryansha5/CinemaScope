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
    // PURPOSE: isolate whether a failing audio renderer (ParseAC3Header /
    // AudioQueueObject Prime errors) is preventing the synchronizer timebase
    // from running.  In a shared synchronizer, a renderer that fails to prime
    // can block the clock for all attached renderers.
    //
    // Set to false to re-enable audio once video-only playback is confirmed.
    static var videoOnlyDiagnostic: Bool = true

    // MARK: - Init

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        synchronizer.addRenderer(layer)

        if FrameRenderer.videoOnlyDiagnostic {
            // Audio renderer intentionally NOT attached — diagnostic mode.
            fputs("[FrameRenderer] ⚠️ videoOnlyDiagnostic=true — "
                + "audioRenderer NOT attached to synchronizer\n", stderr)
        } else {
            synchronizer.addRenderer(audioRenderer)
        }

        synchronizer.rate = 0   // start paused
        fputs("[FrameRenderer] Synchronizer created — "
            + (FrameRenderer.videoOnlyDiagnostic ? "video-only" : "layer + audioRenderer")
            + " attached\n", stderr)
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
            // Sprint 46: include timebase rate+time so we can see whether the
            // synchronizer clock is actually running when frames are enqueued.
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
        guard !FrameRenderer.videoOnlyDiagnostic else { return }
        audioRenderer.enqueue(sampleBuffer)
    }

    // MARK: - Transport

    /// Start playback.  `startPTS` is the video timeline position to begin from —
    /// the synchronizer anchors its clock there so the first frame appears immediately.
    func play(from startPTS: CMTime) {
        // Step 1: anchor the timeline at startPTS with rate=0 (time-only, no start yet).
        // This is a no-op if seek already anchored the clock here, but is safe to call.
        synchronizer.setRate(0, time: startPTS)

        // Step 2: start the clock without moving the anchor.
        // Using setRate(_:time:.invalid) changes rate only, leaving the previously
        // anchored time intact.  This two-step pattern avoids a known tvOS quirk where
        // setRate(1, time: X) correctly anchors X but silently leaves rate=0 when the
        // display layer's isReadyForMoreMediaData is false at the time of the call.
        synchronizer.setRate(1, time: .invalid)

        // Belt-and-suspenders: set the .rate property directly as well, since
        // setRate(_:time:) on tvOS sometimes does not update the underlying
        // CMTimebase rate when the display layer queue is temporarily saturated.
        synchronizer.rate = 1

        // Diagnostic log — log both synchronizer.rate property and CMTimebaseGetRate
        // so we can distinguish between "API value" and "timebase value" in the log.
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
        // setRate(_:time:kCMTimeInvalid) = change rate without moving the clock.
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
        // flushAndRemoveImage() cancels the synchronizer's internal
        // requestMediaDataWhenReady registration on the layer, leaving
        // isReadyForMoreMediaData stuck at false permanently.  On the next
        // prepare() + play() call, setRate(1) will silently refuse to run
        // because the display layer's queue management is in a broken state.
        // This one-shot request/stop cycle resets the flag immediately so the
        // next enqueue + play() sequence works correctly.
        layer.requestMediaDataWhenReady(on: .main) { [weak self] in
            self?.layer.stopRequestingMediaData()
        }

        if !FrameRenderer.videoOnlyDiagnostic { audioRenderer.flush() }
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
        if !FrameRenderer.videoOnlyDiagnostic { audioRenderer.flush() }
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

        // Re-arm isReadyForMoreMediaData.  flushAndRemoveImage() cancels the
        // synchronizer's internal requestMediaDataWhenReady registration on the
        // layer, which leaves isReadyForMoreMediaData stuck at false.  This
        // no-op request/stop cycle resets that flag immediately on the main queue.
        layer.requestMediaDataWhenReady(on: .main) { [weak self] in
            // Immediately cancel — we only want the flag reset side-effect.
            self?.layer.stopRequestingMediaData()
        }

        if !FrameRenderer.videoOnlyDiagnostic { audioRenderer.flush() }
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
