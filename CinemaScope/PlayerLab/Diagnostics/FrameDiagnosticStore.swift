// MARK: - PlayerLab / Diagnostics / FrameDiagnosticStore
//
// Per-frame diagnostic ring buffer for distortion-window analysis.
//
// Captures every video frame's journey through the pipeline:
//   PacketFeeder.fetchPackets  → records .fetched / .filtered frames
//   FrameRenderer.performLayerEnqueue → upgrades .fetched → .layerEnqueued
//   FrameRenderer flush paths  → downgrades .fetched → .flushed (seek/stop)
//
// Query: given a known-bad timestamp from a test run, call
//   FrameDiagnosticStore.shared.dump(aroundPTS: seconds)
// and compare the output to a clean window at a different timestamp.
//
// NOT actor-isolated — callers must be on the main thread / @MainActor.
// All current callers satisfy this:
//   PacketFeeder   (@MainActor class)
//   FrameRenderer  (requestMediaDataWhenReady callback registered on .main)
//   PlayerLabPlaybackController (@MainActor class)
//
// NOT production-ready. Debug / lab use only.

import Foundation

// MARK: - FrameDiagRecordState

enum FrameDiagRecordState: String {
    /// Built successfully by makeVideoSampleBuffer; appended to pendingVideoQueue.
    case fetched       = "FETCHED"
    /// Delivered to AVSampleBufferDisplayLayer.enqueue() via performLayerEnqueue().
    case layerEnqueued = "LAYER_ENQ"
    /// Cleared by a flush before it could reach the layer (seek or stop).
    case flushed       = "FLUSHED"
    /// Rejected by PacketFeeder before it reached the renderer.
    case filtered      = "FILTERED"
}

// MARK: - FrameDiagnosticRecord

struct FrameDiagnosticRecord {

    // ── Demuxer-level identity ────────────────────────────────────────────────

    /// Position of this frame in the demuxer's frameIndex (video track).
    let sampleIndex: Int

    /// Presentation timestamp (seconds).  Display order.
    let pts: Double

    /// Synthetic decode timestamp (seconds); `Double.nan` for H.264 (dts=.invalid)
    /// or frames that never reached makeVideoSampleBuffer (filtered before VT).
    let synthDTS: Double

    /// Byte offset in the source file.  Ascending within each fileOffset-sorted
    /// batch = decode order.  Compare across frames to verify GOP sort integrity.
    let fileOffset: Int64

    // ── Payload sizes ─────────────────────────────────────────────────────────

    /// Raw packet.data.count before any normalization or DV stripping.
    let rawSize: Int

    /// sampleBytes.count after LP normalisation + DV NAL strip (what VT sees).
    /// 0 for filtered frames (never reached makeVideoSampleBuffer).
    let finalSize: Int

    // ── NAL metadata ──────────────────────────────────────────────────────────

    /// Whether the demuxer flagged this packet as a keyframe (IDR/CRA).
    let isKeyframe: Bool

    /// Human-readable label of the first NAL unit type in the normalised stream.
    /// E.g. "IDR_W_RADL ✅", "TRAIL_0", "CRA_NUT", "?" (unknown / filtered).
    let firstNALType: String

    // ── Batch provenance ──────────────────────────────────────────────────────

    /// Label of the feedWindow / fetchPackets call that created this frame.
    /// Values: "initial", "refill", "buf-refill", "seek", "kf-probe", etc.
    let batchLabel: String

    // ── Pipeline state ────────────────────────────────────────────────────────

    /// Current state of this frame in the pipeline.
    var state: FrameDiagRecordState

    /// Non-nil when state == .filtered; short reason label.
    /// Values: "DV-BL-size", "make-failed", etc.
    var filterReason: String?
}

// MARK: - FrameDiagnosticStore

final class FrameDiagnosticStore {

    // MARK: Shared singleton

    static let shared = FrameDiagnosticStore()
    private init() {}

    // MARK: Ring buffer

    /// Maximum number of frame records retained.
    /// 3 600 = ~2.5 min at 24 fps — large enough to cover any test window.
    private static let capacity = 3_600

    private var records: [FrameDiagnosticRecord] = []

    // MARK: - Mutation

    /// Append a new record.  Drops the oldest 10% when the ring is full.
    func append(_ record: FrameDiagnosticRecord) {
        if records.count >= Self.capacity {
            records.removeFirst(Self.capacity / 10)
        }
        records.append(record)
    }

    /// Mark the frame with PTS nearest to `pts` (within 3 ms) as layer-enqueued.
    /// Called from FrameRenderer.performLayerEnqueue().
    func markLayerEnqueued(pts: Double) {
        let targetMs = Int((pts * 1000).rounded())
        // Scan from the end — the most recently fetched frames are at the tail.
        for i in stride(from: records.count - 1, through: 0, by: -1) {
            let recMs = Int((records[i].pts * 1000).rounded())
            if abs(recMs - targetMs) <= 3 {
                if records[i].state == .fetched {
                    records[i].state = .layerEnqueued
                }
                return
            }
        }
    }

    /// Mark all .fetched records as .flushed.
    /// Called when pendingVideoQueue is cleared (seek, stop).
    func markAllFlushed() {
        for i in records.indices where records[i].state == .fetched {
            records[i].state = .flushed
        }
    }

    /// Remove all records.  Called at the start of prepare().
    func reset() {
        records.removeAll()
    }

    // MARK: - Query

    /// All records whose PTS is within `window` seconds of `pts`, sorted by PTS.
    func records(aroundPTS pts: Double, window: Double = 3.0) -> [FrameDiagnosticRecord] {
        records
            .filter { abs($0.pts - pts) <= window }
            .sorted  { $0.pts < $1.pts }
    }

    /// Returns the most-recently appended record whose PTS matches `pts`
    /// within `tolerance` seconds AND whose batchLabel equals `label`.
    ///
    /// Used by the GOP deep-debug tail log to look up synthDTS + firstNALType
    /// that were populated by makeVideoSampleBuffer in the same batch.
    /// Scans backwards from the tail (most recently added) for efficiency.
    func record(nearPTS pts: Double,
                batchLabel label: String,
                tolerance: Double = 0.003) -> FrameDiagnosticRecord? {
        let searchCount = min(records.count, 600)   // cap: 25 s at 24 fps
        for i in stride(from: records.count - 1,
                        through: records.count - searchCount,
                        by: -1) {
            let r = records[i]
            if r.batchLabel == label && abs(r.pts - pts) <= tolerance {
                return r
            }
        }
        return nil
    }

    // MARK: - Formatted dump

    /// Returns a human-readable multi-line table of the ±`window`s window
    /// centred on `pts`.  Suitable for pasting into a diff tool.
    func dump(aroundPTS pts: Double, window: Double = 3.0) -> String {
        let window = records(aroundPTS: pts, window: window)
        let total  = window.count
        let lEnq   = window.filter { $0.state == .layerEnqueued }.count
        let fetc   = window.filter { $0.state == .fetched       }.count
        let flsh   = window.filter { $0.state == .flushed       }.count
        let filt   = window.filter { $0.state == .filtered      }.count

        var lines: [String] = []
        lines.append(
            "[DiagDump] t=\(String(format: "%.3f", pts))s  "
            + "±\(String(format: "%.1f", window.isEmpty ? 3.0 : abs((window.last?.pts ?? pts) - pts)))s  "
            + "\(total) frames  "
            + "(LAYER_ENQ:\(lEnq)  FETCHED:\(fetc)  FLUSHED:\(flsh)  FILTERED:\(filt))"
        )
        lines.append(
            "  row  "
            + "idx".pad(6) + "  "
            + "pts(s)".pad(9) + "  "
            + "dts(s)".pad(9) + "  "
            + "fileOffset".pad(14) + "  "
            + "rawB".pad(7) + "  "
            + "finB".pad(7) + "  "
            + "KF  "
            + "firstNAL".pad(20) + "  "
            + "batch".pad(10) + "  "
            + "state"
        )
        lines.append(
            "  ---  "
            + String(repeating: "-", count: 6) + "  "
            + String(repeating: "-", count: 9) + "  "
            + String(repeating: "-", count: 9) + "  "
            + String(repeating: "-", count: 14) + "  "
            + String(repeating: "-", count: 7) + "  "
            + String(repeating: "-", count: 7) + "  "
            + "--  "
            + String(repeating: "-", count: 20) + "  "
            + String(repeating: "-", count: 10) + "  "
            + String(repeating: "-", count: 12)
        )

        for (i, r) in window.enumerated() {
            let dtsStr = r.synthDTS.isNaN
                ? "    n/a  "
                : String(format: "%.3f", r.synthDTS).pad(9)
            let kfMark = r.isKeyframe ? "✅" : "  "
            let stateStr = r.state.rawValue
                + (r.filterReason.map { "[\($0)]" } ?? "")

            let line =
                "  " + String(i).pad(3) + "  "
                + String(r.sampleIndex).pad(6) + "  "
                + String(format: "%.3f", r.pts).pad(9) + "  "
                + dtsStr + "  "
                + (r.fileOffset >= 0 ? String(r.fileOffset) : "?").pad(14) + "  "
                + String(r.rawSize).pad(7) + "  "
                + String(r.finalSize).pad(7) + "  "
                + kfMark + "  "
                + r.firstNALType.trunc(20).pad(20) + "  "
                + r.batchLabel.trunc(10).pad(10) + "  "
                + stateStr
            lines.append(line)
        }

        if total == 0 {
            lines.append("  (no records in this window — has playback started?)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - String helpers (private, file-scoped)

private extension String {
    /// Right-pad with spaces to `length`.
    func pad(_ length: Int) -> String {
        if count >= length { return self }
        return self + String(repeating: " ", count: length - count)
    }

    /// Truncate to `maxLength` characters, appending "…" if truncated.
    func trunc(_ maxLength: Int) -> String {
        if count <= maxLength { return self }
        return String(prefix(maxLength - 1)) + "…"
    }
}
