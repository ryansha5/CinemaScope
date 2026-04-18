// MARK: - PlayerLab / Core / ContainerPreparation
// Spring Cleaning SC2 — Container routing + parsing extracted from
// PlayerLabPlaybackController.prepare(url:).
//
// Responsibilities:
//   • Detect container format from file extension
//   • Construct and call the appropriate demuxer
//   • Surface track/subtitle/chapter/chapter model in typed result structs
//   • Collect log messages for the controller to apply via record()
//
// The controller's prepare() retains responsibility for:
//   • MediaReader open
//   • State reset
//   • Format-description construction (AudioFormatFactory / H264Decoder / HEVCDecoder)
//   • Initial window loading (PacketFeeder)
//   • Published-state writes
//   • State transition to .ready
//
// Log messages are returned inside the result structs rather than via callback
// to avoid actor-isolation concerns when bridging @MainActor code.
//
// NOT production-ready. Debug / lab use only.

import Foundation

// MARK: - Errors

enum ContainerPreparationError: Error, LocalizedError {
    case parseFailed(String)
    case noVideoTrack(String)
    case unsupportedCodec(String)

    var errorDescription: String? {
        switch self {
        case .parseFailed(let m):      return m
        case .noVideoTrack(let ext):   return "No supported video track in \(ext)"
        case .unsupportedCodec(let c): return "Unsupported MKV video codec '\(c)' — fallback to AVPlayer"
        }
    }
}

// MARK: - Result types

/// All information extracted from a successfully parsed MKV/WebM container.
struct MKVPreparationResult {
    let demuxer:                  MKVDemuxer
    let videoTrack:               TrackInfo
    let availableAudioTracks:     [MKVAudioTrackDescriptor]
    let selectedAudioTrackNumber: UInt64?
    let availableSubtitleTracks:  [SubtitleTrackDescriptor]
    let selectedSubtitleTrack:    SubtitleTrackDescriptor?
    let subtitleCues:             [SubtitleCue]
    let selectedPGSTrack:         SubtitleTrackDescriptor?
    let pgsCues:                  [PGSCue]
    let chapters:                 [ChapterInfo]
    /// Log messages produced during preparation; apply via record() in the controller.
    let logMessages:              [String]
}

/// All information extracted from a successfully parsed MP4/MOV container.
struct MP4PreparationResult {
    let demuxer:     MP4Demuxer
    let videoTrack:  TrackInfo
    /// Log messages produced during preparation; apply via record() in the controller.
    let logMessages: [String]
}

// MARK: - Tagged union

/// Wraps either an MKV or MP4 result for uniform handling in prepare().
enum ContainerResult {
    case mkv(MKVPreparationResult)
    case mp4(MP4PreparationResult)

    /// The parsed video track, regardless of container.
    var videoTrack: TrackInfo {
        switch self {
        case .mkv(let r): return r.videoTrack
        case .mp4(let r): return r.videoTrack
        }
    }

    /// Short container label ("MKV" / "MP4").
    var containerLabel: String {
        switch self {
        case .mkv: return "MKV"
        case .mp4: return "MP4"
        }
    }

    /// Log messages collected during container preparation.
    var logMessages: [String] {
        switch self {
        case .mkv(let r): return r.logMessages
        case .mp4(let r): return r.logMessages
        }
    }
}

// MARK: - ContainerPreparation

enum ContainerPreparation {

    // MARK: - Main entry

    /// Route `url` to the correct demuxer, parse, and return a `ContainerResult`.
    ///
    /// Throws `ContainerPreparationError` on hard failures (parse error, no video track,
    /// unsupported codec). All diagnostic messages are in `result.logMessages`.
    static func prepare(
        url:                 URL,
        reader:              MediaReader,
        audioPolicy:         AudioPreferencePolicy,
        preferredAudioTrack: UInt64?
    ) async throws -> ContainerResult {

        let ext   = url.pathExtension.lowercased()
        let isMKV = ["mkv", "webm"].contains(ext)

        if isMKV {
            let result = try await prepareMKV(reader:              reader,
                                              audioPolicy:         audioPolicy,
                                              preferredAudioTrack: preferredAudioTrack)
            return .mkv(result)
        } else {
            let result = try await prepareMP4(reader: reader, ext: ext)
            return .mp4(result)
        }
    }

    // MARK: - MKV / WebM

    private static func prepareMKV(
        reader:              MediaReader,
        audioPolicy:         AudioPreferencePolicy,
        preferredAudioTrack: UInt64?
    ) async throws -> MKVPreparationResult {

        var logs: [String] = []

        logs.append("[Routing] MKV detected → MKVDemuxer")
        logs.append("[2] Parsing MKV (EBML)…")

        let mkv = MKVDemuxer(reader: reader)
        mkv.setPreferredAudioTrack(trackNumber: preferredAudioTrack)
        mkv.setAudioPolicy(audioPolicy)

        do {
            try await mkv.parse()
            logs.append("  ✅ MKV parsed — \(mkv.tracks.count) track(s)  "
                      + "\(mkv.videoTrack?.sampleCount ?? 0) video frames")
        } catch {
            throw ContainerPreparationError.parseFailed(
                "[Routing] MKV parse failed: \(error.localizedDescription)")
        }

        guard let vt = mkv.videoTrack else {
            throw ContainerPreparationError.noVideoTrack("MKV")
        }

        let codec = vt.codecFourCC ?? "?"
        guard vt.isH264 || vt.isHEVC else {
            throw ContainerPreparationError.unsupportedCodec(codec)
        }

        // ── Audio track log ───────────────────────────────────────────────────
        if !mkv.availableAudioTracks.isEmpty {
            logs.append("[Audio] \(mkv.availableAudioTracks.count) track(s) found:")
            for t in mkv.availableAudioTracks {
                let supportMark = t.isSupported ? "✅" : "⚠️ unsupported"
                let defMark     = t.isDefault ? " [default]" : ""
                logs.append("  track \(t.trackNumber): \(t.codecID)  "
                          + "ch=\(t.channelCount)  sr=\(Int(t.sampleRate)) Hz  "
                          + "lang=\(t.language)\(defMark)  \(supportMark)")
            }
            if let selNum = mkv.selectedAudioTrackNumber {
                let selCodec = mkv.availableAudioTracks
                    .first { $0.trackNumber == selNum }?.codecID ?? "?"
                logs.append("  → Selected: track \(selNum)  (\(selCodec))")
            } else {
                logs.append("  → No supported audio track — video only")
            }
        } else {
            logs.append("  ℹ️ No audio tracks in MKV")
        }

        // ── Subtitle track log ────────────────────────────────────────────────
        if let subTrack = mkv.selectedSubtitleTrack, !mkv.subtitleCues.isEmpty {
            logs.append("[Subtitle] \(mkv.subtitleCues.count) cue(s) loaded "
                      + "for '\(subTrack.displayLabel)'")
        } else if !mkv.availableSubtitleTracks.isEmpty {
            logs.append("[Subtitle] \(mkv.availableSubtitleTracks.count) track(s) found "
                      + "but none SRT-compatible — subtitles off")
        }

        // ── PGS log ───────────────────────────────────────────────────────────
        if let pgsTrack = mkv.selectedPGSTrack, !mkv.pgsCues.isEmpty {
            logs.append("[PGS] \(mkv.pgsCues.count) cue(s) loaded for '\(pgsTrack.displayLabel)'")
        } else if mkv.availableSubtitleTracks.contains(where: { $0.isPGS }) {
            logs.append("[PGS] PGS track(s) found but no cues decoded — unsupported or empty")
        }

        // ── Chapter log ───────────────────────────────────────────────────────
        if !mkv.chapters.isEmpty {
            logs.append("[Chapters] \(mkv.chapters.count) chapter(s) loaded")
        }

        return MKVPreparationResult(
            demuxer:                  mkv,
            videoTrack:               vt,
            availableAudioTracks:     mkv.availableAudioTracks,
            selectedAudioTrackNumber: mkv.selectedAudioTrackNumber,
            availableSubtitleTracks:  mkv.availableSubtitleTracks,
            selectedSubtitleTrack:    mkv.selectedSubtitleTrack,
            subtitleCues:             mkv.subtitleCues,
            selectedPGSTrack:         mkv.selectedPGSTrack,
            pgsCues:                  mkv.pgsCues,
            chapters:                 mkv.chapters,
            logMessages:              logs
        )
    }

    // MARK: - MP4 / MOV

    private static func prepareMP4(
        reader: MediaReader,
        ext:    String
    ) async throws -> MP4PreparationResult {

        var logs: [String] = []

        logs.append("[Routing] \(ext.uppercased()) detected → MP4Demuxer")
        logs.append("[2] Parsing MP4 box tree…")

        let dmx = MP4Demuxer(reader: reader)
        do {
            try await dmx.parse()
            logs.append("  ✅ Parsed — \(dmx.tracks.count) tracks found")
        } catch {
            throw ContainerPreparationError.parseFailed(
                "Parse failed: \(error.localizedDescription)")
        }

        guard let vt = dmx.videoTrack else {
            throw ContainerPreparationError.noVideoTrack("MP4")
        }

        return MP4PreparationResult(demuxer: dmx, videoTrack: vt, logMessages: logs)
    }
}
