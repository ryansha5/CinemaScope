// MARK: - PlayerLab / Render / FrameRenderer
//
// Sprint 10 — Frame Rendering Proof
// Sprint 11 — Timed Presentation / Playback Clock
//
// Wraps AVSampleBufferDisplayLayer with a CMTimebase.
// Accepts compressed CMSampleBuffers (H.264 AVCC or HEVC HVCC format) and
// drives timed presentation without a separate VT decode session —
// AVSampleBufferDisplayLayer handles decompression internally.
//
// Thread safety:
//   All methods must be called from the main thread / @MainActor.
//   The layer itself is safe to add to any UIView on the main thread.
//
// Usage:
//   let renderer = FrameRenderer()
//   someUIView.layer.addSublayer(renderer.layer)
//   renderer.enqueue(sampleBuffer)          // repeat for each packet
//   renderer.play(from: firstPTS)           // start timebase at first PTS
//   renderer.pause() / renderer.resume()   // Sprint 11 play-pause

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore

final class FrameRenderer {

    // MARK: - Public surface

    /// The display layer — add to a UIView's layer hierarchy before enqueuing frames.
    let layer = AVSampleBufferDisplayLayer()

    /// Number of sample buffers successfully enqueued.
    private(set) var framesEnqueued: Int = 0

    /// PTS of the first enqueued sample.
    private(set) var firstFramePTS: CMTime = .invalid

    /// Called on main thread when the very first frame is enqueued.
    /// Provides decoded dimensions from the format description.
    var onFirstFrame: ((CGSize) -> Void)?

    // MARK: - Private

    private var timebase: CMTimebase?

    // MARK: - Init

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        setupTimebase()
    }

    // MARK: - Timebase (Sprint 11)
    //
    // AVSampleBufferDisplayLayer.controlTimebase drives timed presentation.
    // Setting the timebase rate to 0 pauses; 1.0 plays at realtime.
    //
    // CMTimebaseCreateWithSourceClock ties our timebase to the host clock so
    // wall-clock elapsed time advances the video PTS.

    private func setupTimebase() {
        var tb: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator:   kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb
        )
        guard status == noErr, let tb = tb else {
            fputs("[FrameRenderer] CMTimebaseCreateWithSourceClock failed: \(status)\n", stderr)
            return
        }
        CMTimebaseSetRate(tb, rate: 0)        // start paused
        CMTimebaseSetTime(tb, time: .zero)
        layer.controlTimebase = tb
        timebase = tb
        fputs("[FrameRenderer] Timebase created and attached to layer\n", stderr)
    }

    // MARK: - Enqueue

    /// Enqueue one compressed CMSampleBuffer.
    /// Call this for each DemuxPacket after wrapping it in a CMSampleBuffer.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        // Attempt to recover from failed state before each enqueue.
        if layer.status == .failed {
            fputs("[FrameRenderer] layer.status == .failed before enqueue; calling flush()\n", stderr)
            layer.flush()
        }

        layer.enqueue(sampleBuffer)
        let isFirst = (framesEnqueued == 0)
        framesEnqueued += 1

        if isFirst {
            firstFramePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
                let dims = CMVideoFormatDescriptionGetDimensions(fmt)
                let size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
                fputs("[FrameRenderer] First frame enqueued — PTS=\(firstFramePTS.seconds)s  dims=\(Int(size.width))×\(Int(size.height))\n", stderr)
                onFirstFrame?(size)
            }
        }
    }

    // MARK: - Play / Pause (Sprint 11)

    /// Start playback anchored so that the first frame appears immediately.
    ///
    /// Calling this sets the timebase time to `startPTS` at the current
    /// host-clock moment, then sets the rate to 1.0.  Frames whose PTS equals
    /// `startPTS` will be presented right away; later frames appear at the
    /// correct relative host-clock times.
    func play(from startPTS: CMTime) {
        guard let tb = timebase else {
            fputs("[FrameRenderer] play() — no timebase\n", stderr)
            return
        }
        // Anchor: "right now in wall time, the video time is startPTS"
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        CMTimebaseSetAnchorTime(tb, timebaseTime: startPTS, immediateSourceTime: hostNow)
        CMTimebaseSetRate(tb, rate: 1.0)
        fputs("[FrameRenderer] play(from: \(String(format: "%.4f", startPTS.seconds))s)\n", stderr)
    }

    /// Freeze presentation at the current video time.
    func pause() {
        guard let tb = timebase else { return }
        CMTimebaseSetRate(tb, rate: 0.0)
        fputs("[FrameRenderer] pause() — timebase rate=0\n", stderr)
    }

    /// Resume presentation from where it was paused.
    func resume() {
        guard let tb = timebase else { return }
        // Re-anchor at current timebase time to avoid a jump
        let currentVideoTime = CMTimebaseGetTime(tb)
        let hostNow          = CMClockGetTime(CMClockGetHostTimeClock())
        CMTimebaseSetAnchorTime(tb, timebaseTime: currentVideoTime, immediateSourceTime: hostNow)
        CMTimebaseSetRate(tb, rate: 1.0)
        fputs("[FrameRenderer] resume() — timebase rate=1.0\n", stderr)
    }

    // MARK: - Reset

    /// Flush all enqueued frames and reset the renderer to its initial state.
    /// Call before loading a new stream.
    func flush() {
        layer.flushAndRemoveImage()
        framesEnqueued = 0
        firstFramePTS  = .invalid
        if let tb = timebase {
            CMTimebaseSetRate(tb, rate: 0)
            CMTimebaseSetTime(tb, time: .zero)
        }
        fputs("[FrameRenderer] flush() — layer cleared, timebase reset\n", stderr)
    }

    // MARK: - Status

    /// Human-readable layer status for logging.
    var layerStatusDescription: String {
        switch layer.status {
        case .unknown:    return "unknown"
        case .rendering:  return "rendering"
        case .failed:     return "failed(\(layer.error?.localizedDescription ?? "?"))"
        @unknown default: return "unknownFuture"
        }
    }
}
