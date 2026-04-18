// MARK: - PlayerLab / Demux / MKV / MKVDemuxer
//
// Sprint 20 — MKV container demuxer (video-first)
// Sprint 22 — MKV AAC audio track extraction + lacing support
// Sprint 23 — Multi-track audio model, default track selection, structured logging
// Sprint 24 — AC3 / EAC3 audio support
// Sprint 25 — Audio preference policy + pre-selection API for restart-based track switching
// Sprint 26 — Subtitle track detection (S_TEXT/UTF8) and cue extraction
// Sprint 27 — Chapter parsing (MKV Chapters / EditionEntry / ChapterAtom)
// Sprint 28 — PGS subtitle track detection, packet extraction, and cue decoding
// Sprint 29 — TrueHD/DTS/DTS-HD audio track detection and classification
// Sprint 30 — DTS fix for B-frame H.264 (dts:.invalid for video packets)
// Sprint 31 — MKVAudioTrackDescriptor: isDTSCore / isDTSHD; PremiumAudioPolicy-ready
// Sprint 32 — reselectAudio(): re-scan clusters when policy overrides initial selection
// Sprint 33 — DTS-Core: "dtsc" fourCC mapping; 512 frames/packet; passthrough path
//
// Architecture (unchanged from Sprint 20):
//   parse()  → EBML validation → Segment → Info + Tracks + Chapters → scanClusters
//   extractVideoPackets / extractAudioPackets → batched byte-range reads
//   seek helpers → binary search on sorted frame indexes
//
// Audio track selection priority (Sprint 25):
//   Explicit override (user-requested)  > AudioPreferencePolicy  > built-in heuristic
//
// Subtitle support (Sprint 26):
//   S_TEXT/UTF8 (SRT-style) blocks are decoded inline during cluster scan.
//   BlockDuration provides end time; fallback = startTime + 5 s.
//
// Chapter timestamps (Sprint 27):
//   ChapterTimeStart/End are always in nanoseconds (NOT scaled by TimecodeScale).
//
// NOT production-ready. Debug / lab use only.

import Foundation
import CoreMedia

// MARK: - MKVAudioTrackDescriptor  (Sprint 23 / Sprint 31 / Sprint 33)

struct MKVAudioTrackDescriptor {
    let trackNumber:  UInt64
    let codecID:      String
    let channelCount: Int
    let sampleRate:   Double
    let language:     String
    let isDefault:    Bool

    var isAAC:  Bool { codecID == "A_AAC" || codecID.hasPrefix("A_AAC/") }
    var isAC3:  Bool { codecID == "A_AC3"  }
    var isEAC3: Bool { codecID == "A_EAC3" }
    var isTrueHD: Bool { codecID == "A_TRUEHD" }

    // Sprint 33: DTS family decomposed into three tiers.
    //   isDTSCore — standard DTS-Core (A_DTS exact match).
    //               kAudioFormatDTS passthrough is attempted on capable hardware.
    //   isDTSHD   — DTS-HD variants (A_DTS/HRA, A_DTS/LOSSLESS, A_DTS/X, etc.).
    //               Not currently decodable; treated as unsupported.
    //   isDTS     — broad "any DTS family" check (union of the above).
    var isDTSCore: Bool { codecID == "A_DTS" }
    var isDTSHD:   Bool { codecID.hasPrefix("A_DTS/") }
    var isDTS:     Bool { isDTSCore || isDTSHD }

    /// Fully-supported codecs that PlayerLab can always decode reliably.
    /// DTS-Core is NOT listed here; it is handled separately as an attempted
    /// passthrough path by PremiumAudioPolicy (Sprint 33).
    var isSupported: Bool { isAAC || isAC3 || isEAC3 }

    /// Sprint 29 / Sprint 31: three-tier classification delegated to PremiumAudioPolicy.
    /// Kept here for backward-compatibility with existing logging sites.
    enum Classification {
        case supported          // AAC, AC3, EAC3
        case unsupportedKnown   // TrueHD, DTS, DTS-HD — recognized but not decodable
        case unknown
    }
    var classification: Classification {
        if isSupported              { return .supported }
        if isTrueHD || isDTS        { return .unsupportedKnown }
        return .unknown
    }
}

// MARK: - Private frame / block types

private struct MKVFrameInfo {
    let fileOffset:  Int64
    let size:        Int
    let pts:         CMTime
    let isKeyframe:  Bool
}

private struct MKVAudioFrameInfo {
    let fileOffset: Int64
    let size:       Int
    let pts:        CMTime
}

private struct RawBlockInfo {
    let trackNum:      UInt64
    let relTC:         Int16
    let isKeyframe:    Bool
    let dataOffset:    Int64
    let dataSize:      Int
    let lacingType:    UInt8
    let durationTicks: Int64?   // Sprint 26: from BlockDuration; nil for SimpleBlock
}

/// Sprint 28: raw PGS block collected during cluster scan, before CGImage decode.
private struct PGSRawPacket {
    let pts:    CMTime
    let endPTS: CMTime?   // from BlockDuration when present
    let data:   Data
}

// MARK: - Private track model

private struct MKVTrackInfo {
    let trackNumber:  UInt64
    let codecID:      String
    let codecPrivate: Data?
    let pixelWidth:   Int
    let pixelHeight:  Int
    let channelCount: Int
    let sampleRate:   Double
    let flagDefault:  Bool
    let flagForced:   Bool    // Sprint 26
    let language:     String
    let isVideo:      Bool
    let isAudio:      Bool
    let isSubtitle:   Bool    // Sprint 26: trackType == 17

    var isH264:    Bool { codecID == "V_MPEG4/ISO/AVC" }
    var isHEVC:    Bool { codecID == "V_MPEGH/ISO/HEVC" }
    var isAAC:     Bool { codecID == "A_AAC" || codecID.hasPrefix("A_AAC/") }
    var isAC3:     Bool { codecID == "A_AC3"  }
    var isEAC3:    Bool { codecID == "A_EAC3" }
    /// Sprint 33: standard DTS-Core — passthrough attempt via kAudioFormatDTS.
    var isDTSCore: Bool { codecID == "A_DTS" }
    var isAudioSupported: Bool { isAAC || isAC3 || isEAC3 }   // DTS-Core excluded (handled separately)
    var isSRTText: Bool { codecID == "S_TEXT/UTF8" }  // Sprint 26
    var isPGS:     Bool { codecID == "S_HDMV/PGS"  }  // Sprint 28
}

// MARK: - MKVDemuxError

enum MKVDemuxError: Error, LocalizedError {
    case notParsed
    case noVideoTrack
    case unsupportedCodec(String)
    case frameIndexOutOfRange(Int)

    var errorDescription: String? {
        switch self {
        case .notParsed:                   return "MKVDemuxer.parse() has not been called"
        case .noVideoTrack:                return "No supported video track found"
        case .unsupportedCodec(let c):     return "Unsupported codec: \(c)"
        case .frameIndexOutOfRange(let i): return "Frame index \(i) out of range"
        }
    }
}

// MARK: - MKVDemuxer

final class MKVDemuxer {

    // MARK: - Public results (populated after parse())

    private(set) var videoTrack:  TrackInfo?  = nil
    private(set) var audioTrack:  TrackInfo?  = nil
    private(set) var tracks:      [TrackInfo] = []

    /// Raw AudioSpecificConfig bytes for MKV AAC (CodecPrivate = magic cookie directly).
    /// nil for AC3/EAC3 (self-framing — no cookie needed).
    private(set) var audioCodecPrivate: Data? = nil

    // Sprint 23 / 25
    private(set) var availableAudioTracks:     [MKVAudioTrackDescriptor] = []
    private(set) var selectedAudioTrackNumber: UInt64? = nil

    // Sprint 26
    private(set) var availableSubtitleTracks:  [SubtitleTrackDescriptor] = []
    private(set) var subtitleCues:             [SubtitleCue]             = []
    private(set) var selectedSubtitleTrack:    SubtitleTrackDescriptor?  = nil

    // Sprint 27
    private(set) var chapters: [ChapterInfo] = []

    // Sprint 28: PGS bitmap subtitle state
    private(set) var pgsCues:         [PGSCue]                = []
    private(set) var selectedPGSTrack: SubtitleTrackDescriptor? = nil

    // MARK: - Sprint 25: preference pre-selection API
    //
    // Set these before calling parse().  They override the built-in heuristic
    // during audio track selection, which influences which track is indexed in
    // scanClusters.

    private var preferredAudioTrackNumber: UInt64?          = nil
    private var preferencePolicy:          AudioPreferencePolicy = .default

    func setPreferredAudioTrack(trackNumber: UInt64?) {
        preferredAudioTrackNumber = trackNumber
    }
    func setAudioPolicy(_ policy: AudioPreferencePolicy) {
        preferencePolicy = policy
    }

    // MARK: - Private state

    private let parser: MKVParser
    private let reader: MediaReader

    private var frameIndex:      [MKVFrameInfo]      = []
    private var audioFrameIndex: [MKVAudioFrameInfo] = []
    private var pgsRawPackets: [PGSRawPacket] = []

    private var timecodeScaleNS:     UInt64      = 1_000_000
    private let outputTimescale:     CMTimeScale = 1_000
    private var audioSampleRate:     Double      = 44_100
    private var audioFramesPerPacket: Int        = 1024

    // MARK: - Sprint 32: reselectAudio infra
    //
    // Stored after parse() so that reselectAudio() can re-scan clusters without
    // re-parsing the container header.  All four values are set in parse() before
    // scanClusters() is called.

    private var segmentOffset_:    Int64         = 0
    private var videoTrackNum_:    UInt64        = 0
    private var subtitleTrackNum_: UInt64?       = nil
    private var pgsTrackNum_:      UInt64?       = nil
    private var parsedMKVTracks_:  [MKVTrackInfo] = []

    // MARK: - Init

    init(reader: MediaReader) {
        self.reader = reader
        self.parser = MKVParser(reader: reader)
    }

    // MARK: - Parse

    func parse() async throws {
        log("parse() start — \(reader.url.lastPathComponent)")

        let afterHeader   = try await parser.validateEBMLHeader()
        let segmentOffset = try await findSegment(after: afterHeader)
        log("  ✅ Segment @ \(segmentOffset)")

        let (infoOffset, tracksOffset, chaptersOffset) =
            try await findSegmentTopElements(inSegment: segmentOffset)
        if infoOffset > 0   { try await parseInfo(at: infoOffset) }
        guard tracksOffset > 0 else { throw MKVDemuxError.noVideoTrack }
        let mkvTracks = try await parseTracks(at: tracksOffset)
        log("  ✅ TimecodeScale=\(timecodeScaleNS) ns  tracks=\(mkvTracks.count)")

        // ── Chapters  (Sprint 27) ─────────────────────────────────────────────
        if chaptersOffset > 0 {
            chapters = try await parseChapters(at: chaptersOffset)
            if !chapters.isEmpty {
                log("  ✅ \(chapters.count) chapter(s)  first='\(chapters.first?.title ?? "?")'")
            }
        }

        // ── Video track selection ─────────────────────────────────────────────
        guard let videoMKVTrack = mkvTracks.first(where: { $0.isVideo && ($0.isH264 || $0.isHEVC) })
        else { throw MKVDemuxError.noVideoTrack }
        log("  ✅ Video: track \(videoMKVTrack.trackNumber) \(videoMKVTrack.codecID) "
          + "\(videoMKVTrack.pixelWidth)×\(videoMKVTrack.pixelHeight)")

        // ── Audio track discovery + selection (Sprint 22/23/24/25) ────────────
        availableAudioTracks = mkvTracks.filter { $0.isAudio }.map { t in
            MKVAudioTrackDescriptor(trackNumber: t.trackNumber, codecID: t.codecID,
                                    channelCount: t.channelCount, sampleRate: t.sampleRate,
                                    language: t.language, isDefault: t.flagDefault)
        }
        let supportedAudioTracks = mkvTracks.filter { $0.isAudio && $0.isAudioSupported }

        let selectedAudioMKVTrack: MKVTrackInfo? = {
            // Sprint 25: explicit user override takes absolute priority
            if let preferred = preferredAudioTrackNumber,
               let t = supportedAudioTracks.first(where: { $0.trackNumber == preferred }) {
                log("    audio: explicit override → track \(preferred)")
                return t
            }
            // Sprint 25: policy-based selection (replaces hardcoded heuristic)
            let descriptors = supportedAudioTracks.map { t in
                MKVAudioTrackDescriptor(trackNumber: t.trackNumber, codecID: t.codecID,
                                        channelCount: t.channelCount, sampleRate: t.sampleRate,
                                        language: t.language, isDefault: t.flagDefault)
            }
            if let best = AudioTrackSelector.select(from: descriptors, policy: preferencePolicy) {
                return supportedAudioTracks.first { $0.trackNumber == best.trackNumber }
            }
            return nil
        }()

        if let a = selectedAudioMKVTrack {
            selectedAudioTrackNumber = a.trackNumber
            audioSampleRate          = a.sampleRate > 0 ? a.sampleRate : 44_100
            audioCodecPrivate        = a.isAAC ? a.codecPrivate : nil
            audioFramesPerPacket     = (a.isAC3 || a.isEAC3) ? 1536
                                     : a.isDTSCore              ? 512    // Sprint 33
                                     :                             1024
            let reason = AudioTrackSelector.selectionReason(
                for: MKVAudioTrackDescriptor(trackNumber: a.trackNumber, codecID: a.codecID,
                                             channelCount: a.channelCount, sampleRate: a.sampleRate,
                                             language: a.language, isDefault: a.flagDefault),
                policy: preferencePolicy)
            log("  ✅ Audio: track \(a.trackNumber) \(a.codecID) "
              + "ch=\(a.channelCount) sr=\(Int(a.sampleRate)) lang=\(a.language) — \(reason)")
        }

        // Sprint 29: log available tracks with TrueHD/DTS classification
        for t in availableAudioTracks {
            switch t.classification {
            case .supported:
                log("    [Audio] track \(t.trackNumber): \(t.codecID) ch=\(t.channelCount) sr=\(Int(t.sampleRate)) lang=\(t.language)\(t.isDefault ? " [default]" : "") ✅ supported")
            case .unsupportedKnown:
                log("    [Audio] track \(t.trackNumber): \(t.codecID) — ⚠️ recognized but not supported (TrueHD/DTS)")
            case .unknown:
                log("    [Audio] track \(t.trackNumber): \(t.codecID) — ❓ unknown codec")
            }
        }
        // Sprint 29 / 31: log a summary when no supported track was found.
        // PremiumAudioPolicy (called from ContainerPreparation) will produce the
        // authoritative decision log; this is a quick demuxer-level diagnostic.
        let allUnsupported = availableAudioTracks.allSatisfy { !$0.isSupported }
        if allUnsupported && !availableAudioTracks.isEmpty {
            let hasDTSCore = availableAudioTracks.contains { $0.isDTSCore }
            if hasDTSCore {
                log("  ⚠️ No supported audio track — DTS-Core candidate detected (Sprint 33 passthrough path)")
            } else {
                log("  ⚠️ All audio tracks unsupported (TrueHD/DTS-HD/unknown) — PremiumAudioPolicy will decide")
            }
        }

        // ── Subtitle track discovery (Sprint 26) ─────────────────────────────
        let allSubtitleMKVTracks = mkvTracks.filter { $0.isSubtitle }
        availableSubtitleTracks = allSubtitleMKVTracks.enumerated().map { (i, t) in
            SubtitleTrackDescriptor(id: UUID(),
                                    trackNumber: t.trackNumber,
                                    codecID: t.codecID,
                                    language: t.language,
                                    title: "",
                                    isDefault: t.flagDefault,
                                    isForced:  t.flagForced)
        }
        // Auto-select: forced SRT > default SRT > first SRT; otherwise off
        let selectedSubMKVTrack: MKVTrackInfo? = {
            if let t = allSubtitleMKVTracks.first(where: { $0.isSRTText && $0.flagForced }) { return t }
            if let t = allSubtitleMKVTracks.first(where: { $0.isSRTText && $0.flagDefault }) { return t }
            // Do NOT auto-select non-forced non-default subtitles
            return nil
        }()
        if let sub = selectedSubMKVTrack {
            selectedSubtitleTrack = availableSubtitleTracks.first { $0.trackNumber == sub.trackNumber }
            log("  ✅ Subtitles: track \(sub.trackNumber) \(sub.codecID) lang=\(sub.language)")
        } else if !allSubtitleMKVTracks.isEmpty {
            log("  ℹ️ \(allSubtitleMKVTracks.count) subtitle track(s) found — none auto-selected")
        }

        // ── PGS subtitle track discovery (Sprint 28) ──────────────────────────────────────
        // Auto-select: forced PGS > default PGS > first PGS.
        // PGS and SRT are independent; both can be scanned simultaneously.
        let selectedPGSMKVTrack: MKVTrackInfo? = {
            if let t = allSubtitleMKVTracks.first(where: { $0.isPGS && $0.flagForced  }) { return t }
            if let t = allSubtitleMKVTracks.first(where: { $0.isPGS && $0.flagDefault }) { return t }
            if let t = allSubtitleMKVTracks.first(where: { $0.isPGS                   }) { return t }
            return nil
        }()
        if let pgs = selectedPGSMKVTrack {
            selectedPGSTrack = availableSubtitleTracks.first { $0.trackNumber == pgs.trackNumber }
            log("  ✅ PGS: track \(pgs.trackNumber) lang=\(pgs.language)")
        }

        // ── Store reselectAudio infra (Sprint 32) ─────────────────────────────
        segmentOffset_    = segmentOffset
        videoTrackNum_    = videoMKVTrack.trackNumber
        subtitleTrackNum_ = selectedSubMKVTrack?.trackNumber
        pgsTrackNum_      = selectedPGSMKVTrack?.trackNumber
        parsedMKVTracks_  = mkvTracks

        // ── Scan clusters ─────────────────────────────────────────────────────
        try await scanClusters(inSegment:        segmentOffset,
                                videoTrackNumber: videoMKVTrack.trackNumber,
                                audioTrackNumber: selectedAudioMKVTrack?.trackNumber,
                                subtitleTrackNum: selectedSubMKVTrack?.trackNumber,
                                pgsTrackNum:      selectedPGSMKVTrack?.trackNumber)

        // Sprint 28: decode collected raw PGS packets into bitmap cues
        if !pgsRawPackets.isEmpty {
            pgsCues = await processPGSPackets(pgsRawPackets)
            log("  ✅ PGS: \(pgsCues.count) cue(s) decoded from \(pgsRawPackets.count) packets")
        }

        log("  ✅ Indexed \(frameIndex.count) video / \(audioFrameIndex.count) audio / "
          + "\(subtitleCues.count) SRT / \(pgsCues.count) PGS subtitle frames")

        // ── Build video TrackInfo ─────────────────────────────────────────────
        let codecFourCC = videoMKVTrack.isH264 ? "avc1" : "hev1"
        let durationSec   = frameIndex.last.map { $0.pts.seconds } ?? 0
        let durationTicks = UInt64(durationSec * Double(outputTimescale))

        videoTrack = TrackInfo(
            trackID: UInt32(videoMKVTrack.trackNumber), trackType: .video,
            timescale: UInt32(outputTimescale), durationTicks: durationTicks,
            sampleCount: frameIndex.count, codecFourCC: codecFourCC,
            displayWidth: UInt16(videoMKVTrack.pixelWidth),
            displayHeight: UInt16(videoMKVTrack.pixelHeight),
            avcCData:  videoMKVTrack.isH264 ? videoMKVTrack.codecPrivate : nil,
            hvcCData:  videoMKVTrack.isHEVC ? videoMKVTrack.codecPrivate : nil,
            esdsData:  nil, channelCount: nil, audioSampleRate: nil
        )
        tracks = [videoTrack!]

        // ── Build audio TrackInfo (Sprint 22) ─────────────────────────────────
        if let a = selectedAudioMKVTrack, !audioFrameIndex.isEmpty {
            let audioFourCC: String
            if      a.isAAC     { audioFourCC = "mp4a" }
            else if a.isAC3     { audioFourCC = "ac-3" }
            else if a.isEAC3    { audioFourCC = "ec-3" }
            else if a.isDTSCore { audioFourCC = "dtsc" }   // Sprint 33: DTS-Core passthrough
            else                { audioFourCC = a.codecID }

            audioTrack = TrackInfo(
                trackID: UInt32(a.trackNumber), trackType: .audio,
                timescale: UInt32(outputTimescale), durationTicks: durationTicks,
                sampleCount: audioFrameIndex.count, codecFourCC: audioFourCC,
                displayWidth: nil, displayHeight: nil,
                avcCData: nil, hvcCData: nil, esdsData: nil,
                channelCount:    a.channelCount > 0 ? UInt16(a.channelCount) : nil,
                audioSampleRate: a.sampleRate   > 0 ? a.sampleRate           : nil
            )
            tracks.append(audioTrack!)
        }

        log("✅ parse() complete — dur≈\(String(format: "%.1f", durationSec))s")
    }

    // MARK: - Sprint 32: reselectAudio
    //
    // Re-scan clusters with a different audio track after parse() has completed.
    // Used by ContainerPreparation when PremiumAudioPolicy dictates a different
    // track than the one the demuxer auto-selected (e.g. Sprint 33 DTS-Core path).
    //
    // Rebuilds: audioFrameIndex, audioTrack, selectedAudioTrackNumber,
    //           audioCodecPrivate, frameIndex (rebuilt in full by scanClusters),
    //           subtitleCues, pgsRawPackets, pgsCues.
    //
    // Safe to call for nil (switches to video-only without re-scanning).

    func reselectAudio(trackNumber: UInt64?) async throws {
        guard segmentOffset_ > 0 else {
            log("  ⚠️ [reselectAudio] called before parse() — no-op")
            return
        }

        // ── Video-only path ───────────────────────────────────────────────────
        guard let trackNum = trackNumber else {
            audioFrameIndex.removeAll()
            audioTrack           = nil
            selectedAudioTrackNumber = nil
            audioCodecPrivate    = nil
            tracks = tracks.filter { $0.trackType != .audio }
            log("  [reselectAudio] → video-only (no audio track requested)")
            return
        }

        guard let mkvTrack = parsedMKVTracks_.first(where: { $0.trackNumber == trackNum && $0.isAudio })
        else {
            log("  ⚠️ [reselectAudio] track \(trackNum) not found in parsed tracks — no-op")
            return
        }

        log("  [reselectAudio] switching audio → track \(trackNum) (\(mkvTrack.codecID))")

        // ── Update per-track audio config ────────────────────────────────────
        audioSampleRate      = mkvTrack.sampleRate > 0 ? mkvTrack.sampleRate : 44_100
        audioCodecPrivate    = mkvTrack.isAAC ? mkvTrack.codecPrivate : nil
        audioFramesPerPacket = (mkvTrack.isAC3 || mkvTrack.isEAC3) ? 1536
                             : mkvTrack.isDTSCore                    ? 512
                             :                                          1024

        // ── Re-scan all clusters with new audio track ─────────────────────────
        // scanClusters resets frameIndex, audioFrameIndex, subtitleCues, pgsRawPackets.
        try await scanClusters(inSegment:        segmentOffset_,
                                videoTrackNumber: videoTrackNum_,
                                audioTrackNumber: trackNum,
                                subtitleTrackNum: subtitleTrackNum_,
                                pgsTrackNum:      pgsTrackNum_)

        // Re-process PGS bitmap packets collected during the rescan
        if !pgsRawPackets.isEmpty {
            pgsCues = await processPGSPackets(pgsRawPackets)
        } else {
            pgsCues.removeAll()
        }

        selectedAudioTrackNumber = trackNum

        // ── Rebuild audioTrack TrackInfo ──────────────────────────────────────
        let audioFourCC: String
        if      mkvTrack.isAAC     { audioFourCC = "mp4a" }
        else if mkvTrack.isAC3     { audioFourCC = "ac-3" }
        else if mkvTrack.isEAC3    { audioFourCC = "ec-3" }
        else if mkvTrack.isDTSCore { audioFourCC = "dtsc" }
        else                        { audioFourCC = mkvTrack.codecID }

        let durationSec   = frameIndex.last.map { $0.pts.seconds } ?? 0
        let durationTicks = UInt64(durationSec * Double(outputTimescale))

        if !audioFrameIndex.isEmpty {
            let newAudioTrack = TrackInfo(
                trackID:    UInt32(mkvTrack.trackNumber), trackType: .audio,
                timescale:  UInt32(outputTimescale), durationTicks: durationTicks,
                sampleCount: audioFrameIndex.count, codecFourCC: audioFourCC,
                displayWidth: nil, displayHeight: nil,
                avcCData: nil, hvcCData: nil, esdsData: nil,
                channelCount:    mkvTrack.channelCount > 0 ? UInt16(mkvTrack.channelCount) : nil,
                audioSampleRate: mkvTrack.sampleRate   > 0 ? mkvTrack.sampleRate : nil
            )
            audioTrack = newAudioTrack
            tracks = tracks.filter { $0.trackType != .audio }
            tracks.append(newAudioTrack)
        } else {
            audioTrack = nil
            tracks = tracks.filter { $0.trackType != .audio }
        }

        log("  ✅ [reselectAudio] track \(trackNum) (\(audioFourCC))  "
          + "\(audioFrameIndex.count) audio / \(frameIndex.count) video / "
          + "\(subtitleCues.count) SRT / \(pgsCues.count) PGS frames")
    }

    // MARK: - Segment Search

    private func findSegment(after offset: Int64) async throws -> Int64 {
        var cursor = offset
        let limit  = reader.contentLength
        while cursor < limit {
            guard let (elem, hdrBytes) = try await parser.nextElement(at: cursor, limit: limit)
            else { break }
            if elem.knownID == .segment { return elem.payloadOffset }
            let total = Int64(hdrBytes) + (elem.payloadSize >= 0 ? elem.payloadSize : 0)
            cursor += max(1, total)
        }
        throw MKVParseError.segmentNotFound
    }

    // MARK: - Segment Top-Level Element Location  (Sprint 27: adds chapters)

    private func findSegmentTopElements(inSegment segOffset: Int64)
            async throws -> (infoOffset: Int64, tracksOffset: Int64, chaptersOffset: Int64) {
        var cursor     = segOffset
        let limit      = min(reader.contentLength, segOffset + 1_048_576)
        var infoOff:   Int64 = -1
        var tracksOff: Int64 = -1
        var chapsOff:  Int64 = -1

        while cursor < limit {
            guard let (elem, hdrBytes) = try await parser.nextElement(at: cursor, limit: limit)
            else { break }
            switch elem.knownID {
            case .info:     infoOff   = elem.payloadOffset
            case .tracks:   tracksOff = elem.payloadOffset
            case .chapters: chapsOff  = elem.payloadOffset  // Sprint 27
            default: break
            }
            if infoOff > 0 && tracksOff > 0 && chapsOff > 0 { break }
            let total = Int64(hdrBytes) + (elem.payloadSize >= 0 ? elem.payloadSize : 0)
            cursor += max(1, total)
        }
        return (infoOff, tracksOff, chapsOff)
    }

    // MARK: - Info Parsing

    private func parseInfo(at offset: Int64) async throws {
        let limit  = offset + 256
        var cursor = offset
        while cursor < limit {
            guard let (elem, hdrBytes) = try await parser.nextElement(at: cursor, limit: limit)
            else { break }
            if elem.knownID == .timecodeScale {
                timecodeScaleNS = try await parser.readUInt(elem)
            }
            let total = Int64(hdrBytes) + (elem.payloadSize >= 0 ? elem.payloadSize : 0)
            cursor += max(1, total)
        }
    }

    // MARK: - Tracks Parsing

    private func parseTracks(at offset: Int64) async throws -> [MKVTrackInfo] {
        var result: [MKVTrackInfo] = []
        let limit = min(reader.contentLength, offset + 65_536)
        var cursor = offset
        while cursor < limit {
            guard let (elem, hdrBytes) = try await parser.nextElement(at: cursor, limit: limit)
            else { break }
            if elem.knownID == .trackEntry, let track = try await parseTrackEntry(elem) {
                result.append(track)
            }
            let paySize = elem.payloadSize >= 0 ? elem.payloadSize : 0
            cursor += Int64(hdrBytes) + paySize
        }
        return result
    }

    private func parseTrackEntry(_ elem: EBMLElement) async throws -> MKVTrackInfo? {
        guard elem.payloadSize > 0 else { return nil }
        var trackNumber:  UInt64 = 0
        var trackType:    UInt64 = 0
        var codecID:      String = ""
        var codecPrivate: Data?  = nil
        var pixelWidth:   Int    = 0
        var pixelHeight:  Int    = 0
        var channelCount: Int    = 0
        var sampleRate:   Double = 0.0
        var flagDefault:  Bool   = true
        var flagForced:   Bool   = false  // Sprint 26
        var language:     String = "und"

        var cursor = elem.payloadOffset
        let limit  = elem.payloadOffset + elem.payloadSize
        while cursor < limit {
            guard let (child, chBytes) = try await parser.nextElement(at: cursor, limit: limit)
            else { break }

            switch child.knownID {
            case .trackNumber:  trackNumber  = try await parser.readUInt(child)
            case .trackType:    trackType    = try await parser.readUInt(child)
            case .codecID:      codecID      = try await parser.readString(child)
            case .flagDefault:  flagDefault  = (try await parser.readUInt(child)) != 0
            case .flagForced:   flagForced   = (try await parser.readUInt(child)) != 0   // Sprint 26
            case .language:     language     = try await parser.readString(child)
            case .codecPrivate:
                if child.payloadSize > 0 {
                    codecPrivate = try await parser.readPayload(child,
                                       maxBytes: Int(min(child.payloadSize, 4096)))
                }
            case .video:
                let vLimit = child.payloadOffset + (child.payloadSize > 0 ? child.payloadSize : 32)
                var vc = child.payloadOffset
                while vc < vLimit {
                    guard let (ve, veBytes) = try await parser.nextElement(at: vc, limit: vLimit)
                    else { break }
                    if ve.knownID == .pixelWidth  { pixelWidth  = Int(try await parser.readUInt(ve)) }
                    if ve.knownID == .pixelHeight { pixelHeight = Int(try await parser.readUInt(ve)) }
                    vc += max(1, Int64(veBytes) + (ve.payloadSize >= 0 ? ve.payloadSize : 0))
                }
            case .audio:
                let aLimit = child.payloadOffset + (child.payloadSize > 0 ? child.payloadSize : 64)
                var ac = child.payloadOffset
                while ac < aLimit {
                    guard let (ae, aeBytes) = try await parser.nextElement(at: ac, limit: aLimit)
                    else { break }
                    if ae.knownID == .samplingFrequency { sampleRate   = try await parser.readFloat(ae) }
                    if ae.knownID == .channels          { channelCount = Int(try await parser.readUInt(ae)) }
                    ac += max(1, Int64(aeBytes) + (ae.payloadSize >= 0 ? ae.payloadSize : 0))
                }
            default: break
            }
            cursor += max(1, Int64(chBytes) + (child.payloadSize >= 0 ? child.payloadSize : 0))
        }

        guard trackNumber > 0 else { return nil }
        return MKVTrackInfo(
            trackNumber: trackNumber, codecID: codecID, codecPrivate: codecPrivate,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            channelCount: channelCount, sampleRate: sampleRate,
            flagDefault: flagDefault, flagForced: flagForced, language: language,
            isVideo:    trackType == 1,
            isAudio:    trackType == 2,
            isSubtitle: trackType == 17   // Sprint 26
        )
    }

    // MARK: - Chapter Parsing  (Sprint 27)
    //
    // MKV chapter timestamps are in nanoseconds from the start of content,
    // NOT scaled by TimecodeScale.  Spec: ChapterTimeStart/End are uint64 ns.

    private func parseChapters(at offset: Int64) async throws -> [ChapterInfo] {
        // Scan the Chapters element for EditionEntry children
        struct RawChapter { var title: String; var startNS: UInt64; var endNS: UInt64? }
        var raw = [RawChapter]()

        let limit  = min(reader.contentLength, offset + 131_072)
        var cursor = offset
        while cursor < limit {
            guard let (elem, hdrBytes) = try await parser.nextElement(at: cursor, limit: limit)
            else { break }
            if elem.knownID == .editionEntry, elem.payloadSize > 0 {
                let atoms = try await parseEditionAtoms(elem)
                raw.append(contentsOf: atoms)
            }
            let total = Int64(hdrBytes) + (elem.payloadSize >= 0 ? elem.payloadSize : 0)
            cursor += max(1, total)
        }

        guard !raw.isEmpty else { return [] }
        // Sort by start time, assign IDs, compute implicit end times
        let sorted = raw.sorted { $0.startNS < $1.startNS }
        return sorted.enumerated().map { (i, ch) in
            let startSec = Double(ch.startNS) / 1_000_000_000.0
            let endSec: Double? = ch.endNS.map { Double($0) / 1_000_000_000.0 }
                               ?? (i + 1 < sorted.count
                                   ? Double(sorted[i + 1].startNS) / 1_000_000_000.0
                                   : nil)
            return ChapterInfo(
                id:        i,
                title:     ch.title.isEmpty ? "Chapter \(i + 1)" : ch.title,
                startTime: CMTime(seconds: startSec, preferredTimescale: 90_000),
                endTime:   endSec.map { CMTime(seconds: $0, preferredTimescale: 90_000) }
            )
        }
    }

    private func parseEditionAtoms(_ elem: EBMLElement)
            async throws -> [(title: String, startNS: UInt64, endNS: UInt64?)] {
        var result = [(title: String, startNS: UInt64, endNS: UInt64?)]()
        var cursor = elem.payloadOffset
        let limit  = elem.payloadOffset + elem.payloadSize
        while cursor < limit {
            guard let (child, chBytes) = try await parser.nextElement(at: cursor, limit: limit)
            else { break }
            if child.knownID == .chapterAtom, child.payloadSize > 0,
               let atom = try await parseChapterAtom(child) {
                result.append(atom)
            }
            cursor += max(1, Int64(chBytes) + (child.payloadSize >= 0 ? child.payloadSize : 0))
        }
        return result
    }

    private func parseChapterAtom(_ elem: EBMLElement)
            async throws -> (title: String, startNS: UInt64, endNS: UInt64?)? {
        var startNS: UInt64? = nil
        var endNS:   UInt64? = nil
        var title            = ""
        var cursor = elem.payloadOffset
        let limit  = elem.payloadOffset + elem.payloadSize
        while cursor < limit {
            guard let (child, chBytes) = try await parser.nextElement(at: cursor, limit: limit)
            else { break }
            switch child.knownID {
            case .chapterTimeStart: startNS = try await parser.readUInt(child)
            case .chapterTimeEnd:   endNS   = try await parser.readUInt(child)
            case .chapterDisplay:
                // Scan for ChapString inside ChapterDisplay
                let dLimit = child.payloadOffset + (child.payloadSize > 0 ? child.payloadSize : 64)
                var dc = child.payloadOffset
                while dc < dLimit {
                    guard let (de, deBytes) = try await parser.nextElement(at: dc, limit: dLimit)
                    else { break }
                    if de.knownID == .chapString { title = try await parser.readString(de) }
                    dc += max(1, Int64(deBytes) + (de.payloadSize >= 0 ? de.payloadSize : 0))
                }
            default: break
            }
            cursor += max(1, Int64(chBytes) + (child.payloadSize >= 0 ? child.payloadSize : 0))
        }
        guard let ns = startNS else { return nil }
        return (title, ns, endNS)
    }

    // MARK: - Cluster Scan

    private func scanClusters(inSegment segOffset: Int64,
                               videoTrackNumber: UInt64,
                               audioTrackNumber: UInt64?,
                               subtitleTrackNum: UInt64?,
                               pgsTrackNum: UInt64?) async throws {    // Sprint 26/28
        frameIndex.removeAll()
        frameIndex.reserveCapacity(8_000)
        audioFrameIndex.removeAll()
        audioFrameIndex.reserveCapacity(16_000)
        subtitleCues.removeAll()   // Sprint 26
        pgsRawPackets.removeAll()   // Sprint 28

        var cursor = segOffset
        let limit  = reader.contentLength
        while cursor < limit {
            guard let (elem, hdrBytes) = try await parser.nextElement(at: cursor, limit: limit)
            else { break }
            if elem.knownID == .cluster {
                let clusterEnd = elem.payloadSize >= 0
                    ? elem.payloadOffset + elem.payloadSize : limit
                try await parseCluster(at:            elem.payloadOffset,
                                       end:           clusterEnd,
                                       videoTrackNum: videoTrackNumber,
                                       audioTrackNum: audioTrackNumber,
                                       subtitleTrackNum: subtitleTrackNum,
                                       pgsTrackNum: pgsTrackNum)
            }
            let total = Int64(hdrBytes) + (elem.payloadSize >= 0 ? elem.payloadSize : 0)
            if total <= 0 { break }
            cursor += total
        }
        frameIndex.sort      { $0.pts < $1.pts }
        audioFrameIndex.sort { $0.pts < $1.pts }
        subtitleCues.sort    { $0.startTime.seconds < $1.startTime.seconds }   // Sprint 26
    }

    private func parseCluster(at start: Int64, end: Int64,
                               videoTrackNum: UInt64,
                               audioTrackNum: UInt64?,
                               subtitleTrackNum: UInt64?,
                               pgsTrackNum: UInt64?) async throws {
        var clusterTimecode: Int64 = 0
        var cursor = start

        // First pass: cluster timestamp (always within first ~64 bytes)
        var tmpCursor = start
        while tmpCursor < min(end, start + 64) {
            guard let (elem, hdrBytes) = try await parser.nextElement(at: tmpCursor,
                                                                       limit: min(end, start + 64))
            else { break }
            if elem.knownID == .clusterTimestamp {
                clusterTimecode = Int64(try await parser.readUInt(elem)); break
            }
            tmpCursor += max(1, Int64(hdrBytes) + (elem.payloadSize >= 0 ? elem.payloadSize : 1))
        }

        // Second pass: blocks
        while cursor < end {
            guard let (elem, hdrBytes) = try await parser.nextElement(at: cursor, limit: end)
            else { break }

            let rawOpt: RawBlockInfo?
            switch elem.knownID {
            case .simpleBlock: rawOpt = try await decodeSimpleBlock(elem)
            case .blockGroup:  rawOpt = try await decodeBlockGroup(elem)
            default:           rawOpt = nil
            }

            if let raw = rawOpt {
                if raw.trackNum == videoTrackNum {
                    if raw.lacingType == 0, raw.dataSize > 0 {
                        frameIndex.append(makeMKVFrameInfo(fileOffset: raw.dataOffset,
                                                            size:       raw.dataSize,
                                                            clusterTC:  clusterTimecode,
                                                            relTC:      raw.relTC,
                                                            isKeyframe: raw.isKeyframe))
                    }
                } else if let atn = audioTrackNum, raw.trackNum == atn {
                    let audioFrames = await makeAudioFrames(from: raw, clusterTC: clusterTimecode)
                    audioFrameIndex.append(contentsOf: audioFrames)
                } else if let stn = subtitleTrackNum, raw.trackNum == stn {
                    // Sprint 26: read subtitle text payload inline
                    await appendSubtitleCue(from: raw, clusterTC: clusterTimecode)
                } else if let ptn = pgsTrackNum, raw.trackNum == ptn {
                    // Sprint 28: collect raw PGS bytes for post-processing
                    await appendPGSPacket(from: raw, clusterTC: clusterTimecode)
                }
            }

            let total = Int64(hdrBytes) + (elem.payloadSize >= 0 ? elem.payloadSize : 0)
            if total <= 0 { break }
            cursor += total
        }
    }

    // MARK: - Block Header Decode  (track-agnostic RawBlockInfo)

    private func decodeSimpleBlock(_ elem: EBMLElement) async throws -> RawBlockInfo? {
        guard elem.payloadSize > 4 else { return nil }
        guard let (trackNum, vintWidth) = try? await parser.readVINT(at: elem.payloadOffset)
        else { return nil }
        let tcOffset = elem.payloadOffset + Int64(vintWidth)
        guard let tcBuf = try? await reader.read(offset: tcOffset, length: 3),
              tcBuf.count >= 3 else { return nil }
        let b0     = UInt16(tcBuf[tcBuf.startIndex])
        let b1     = UInt16(tcBuf[tcBuf.index(tcBuf.startIndex, offsetBy: 1)])
        let relTC  = Int16(bitPattern: (b0 << 8) | b1)
        let flags  = tcBuf[tcBuf.index(tcBuf.startIndex, offsetBy: 2)]
        let headerBytes = Int64(vintWidth + 3)
        let dataOffset  = elem.payloadOffset + headerBytes
        let dataSize    = Int(elem.payloadSize - headerBytes)
        guard dataSize > 0 else { return nil }
        return RawBlockInfo(trackNum: trackNum, relTC: relTC,
                            isKeyframe: (flags & 0x80) != 0,
                            dataOffset: dataOffset, dataSize: dataSize,
                            lacingType: (flags >> 1) & 0x03,
                            durationTicks: nil)   // SimpleBlock has no BlockDuration
    }

    private func decodeBlockGroup(_ elem: EBMLElement) async throws -> RawBlockInfo? {
        guard elem.payloadSize > 0 else { return nil }
        var blockElem:      EBMLElement? = nil
        var hasRefBlock:    Bool         = false
        var blockDurTicks:  Int64?       = nil   // Sprint 26

        var cursor = elem.payloadOffset
        let limit  = elem.payloadOffset + elem.payloadSize
        while cursor < limit {
            guard let (child, chBytes) = try await parser.nextElement(at: cursor, limit: limit)
            else { break }
            if child.knownID == .block         { blockElem     = child }
            if child.knownID == .referenceBlock { hasRefBlock  = true }
            if child.knownID == .blockDuration  {             // Sprint 26
                blockDurTicks = Int64(try await parser.readUInt(child))
            }
            cursor += max(1, Int64(chBytes) + (child.payloadSize >= 0 ? child.payloadSize : 0))
        }

        guard let blk = blockElem, blk.payloadSize > 4 else { return nil }
        guard let (trackNum, vintWidth) = try? await parser.readVINT(at: blk.payloadOffset)
        else { return nil }
        let tcOffset = blk.payloadOffset + Int64(vintWidth)
        guard let tcBuf = try? await reader.read(offset: tcOffset, length: 3),
              tcBuf.count >= 3 else { return nil }
        let b0    = UInt16(tcBuf[tcBuf.startIndex])
        let b1    = UInt16(tcBuf[tcBuf.index(tcBuf.startIndex, offsetBy: 1)])
        let relTC = Int16(bitPattern: (b0 << 8) | b1)
        let flags = tcBuf[tcBuf.index(tcBuf.startIndex, offsetBy: 2)]
        let headerBytes = Int64(vintWidth + 3)
        let dataOffset  = blk.payloadOffset + headerBytes
        let dataSize    = Int(blk.payloadSize - headerBytes)
        guard dataSize > 0 else { return nil }
        return RawBlockInfo(trackNum: trackNum, relTC: relTC,
                            isKeyframe: !hasRefBlock,
                            dataOffset: dataOffset, dataSize: dataSize,
                            lacingType: (flags >> 1) & 0x03,
                            durationTicks: blockDurTicks)   // Sprint 26
    }

    // MARK: - Audio Frame Construction  (lacing support)

    private func makeAudioFrames(from raw: RawBlockInfo, clusterTC: Int64) async -> [MKVAudioFrameInfo] {
        let basePTS = makePTS(clusterTC: clusterTC, relTC: raw.relTC)
        switch raw.lacingType {
        case 0:  return makeUnlacedAudioFrames(raw: raw, basePTS: basePTS)
        case 1:  return await parseXIPHLacedAudio(dataOffset: raw.dataOffset,
                                                   totalSize:  raw.dataSize, basePTS: basePTS)
        case 2:  return await parseFixedLacedAudio(dataOffset: raw.dataOffset,
                                                    totalSize:  raw.dataSize, basePTS: basePTS)
        default: return []
        }
    }

    private func makeUnlacedAudioFrames(raw: RawBlockInfo, basePTS: CMTime) -> [MKVAudioFrameInfo] {
        guard raw.dataSize > 0 else { return [] }
        return [MKVAudioFrameInfo(fileOffset: raw.dataOffset, size: raw.dataSize, pts: basePTS)]
    }

    private func parseXIPHLacedAudio(dataOffset: Int64, totalSize: Int,
                                      basePTS: CMTime) async -> [MKVAudioFrameInfo] {
        guard totalSize > 2 else { return [] }
        let readLen = min(512, totalSize)
        guard let hdr = try? await reader.read(offset: dataOffset, length: readLen),
              !hdr.isEmpty else { return [] }
        let frameCount = Int(hdr[hdr.startIndex]) + 1
        guard frameCount >= 2 else {
            return [MKVAudioFrameInfo(fileOffset: dataOffset + 1,
                                      size: max(0, totalSize - 1), pts: basePTS)]
        }
        var hdrIdx = 1
        var frameSizes = [Int]()
        for _ in 0..<(frameCount - 1) {
            var sz = 0
            while hdrIdx < hdr.count {
                let b = Int(hdr[hdr.index(hdr.startIndex, offsetBy: hdrIdx)]); hdrIdx += 1
                sz += b; if b < 255 { break }
            }
            frameSizes.append(sz)
        }
        let headerBytes   = hdrIdx
        let lastFrameSize = totalSize - headerBytes - frameSizes.reduce(0, +)
        guard lastFrameSize > 0 else { return [] }
        frameSizes.append(lastFrameSize)
        return buildLacedFrameInfos(sizes: frameSizes,
                                    baseOffset: dataOffset + Int64(headerBytes),
                                    basePTS: basePTS)
    }

    private func parseFixedLacedAudio(dataOffset: Int64, totalSize: Int,
                                       basePTS: CMTime) async -> [MKVAudioFrameInfo] {
        guard totalSize > 2 else { return [] }
        guard let hdr = try? await reader.read(offset: dataOffset, length: 1),
              !hdr.isEmpty else {
            return [MKVAudioFrameInfo(fileOffset: dataOffset, size: totalSize, pts: basePTS)]
        }
        let frameCount = Int(hdr[hdr.startIndex]) + 1
        let frameSize  = (totalSize - 1) / frameCount
        guard frameSize > 0 else { return [] }
        return buildLacedFrameInfos(sizes: Array(repeating: frameSize, count: frameCount),
                                    baseOffset: dataOffset + 1, basePTS: basePTS)
    }

    private func buildLacedFrameInfos(sizes: [Int], baseOffset: Int64,
                                       basePTS: CMTime) -> [MKVAudioFrameInfo] {
        let timescale = CMTimeScale(max(1, audioSampleRate))
        var offset    = baseOffset
        var result    = [MKVAudioFrameInfo]()
        result.reserveCapacity(sizes.count)
        for (i, sz) in sizes.enumerated() {
            guard sz > 0 else { continue }
            let delta    = CMTime(value: Int64(i) * Int64(audioFramesPerPacket), timescale: timescale)
            let framePTS = CMTimeAdd(basePTS, delta)
            result.append(MKVAudioFrameInfo(fileOffset: offset, size: sz, pts: framePTS))
            offset += Int64(sz)
        }
        return result
    }

    // MARK: - Subtitle Cue Extraction  (Sprint 26)
    //
    // S_TEXT/UTF8: block payload is raw UTF-8 subtitle text (no sequence number or timing header).
    // End time comes from BlockDuration (ticks × timecodeScaleNS/1e6 → ms CMTime).
    // Fallback end time = startTime + 5 seconds.

    private func appendSubtitleCue(from raw: RawBlockInfo, clusterTC: Int64) async {
        let pts = makePTS(clusterTC: clusterTC, relTC: raw.relTC)
        let endPTS: CMTime
        if let dticks = raw.durationTicks, dticks > 0 {
            let durationMS = Int64(Double(dticks) * Double(timecodeScaleNS) / 1_000_000.0)
            endPTS = CMTimeAdd(pts, CMTime(value: durationMS, timescale: outputTimescale))
        } else {
            endPTS = CMTimeAdd(pts, CMTime(seconds: 5.0, preferredTimescale: outputTimescale))
        }
        guard raw.dataSize > 0,
              let textData = try? await reader.read(offset: raw.dataOffset, length: raw.dataSize),
              let text = String(data: textData, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return }
        subtitleCues.append(SubtitleCue(startTime: pts, endTime: endPTS, rawText: text))
    }

    // MARK: - PGS Packet Collection  (Sprint 28)
    //
    // Unlike SRT (plain text, decoded inline), PGS packets require CGImage decode
    // which is deferred to processPGSPackets() after the full cluster scan.

    private func appendPGSPacket(from raw: RawBlockInfo, clusterTC: Int64) async {
        guard raw.dataSize > 0 else { return }
        let pts = makePTS(clusterTC: clusterTC, relTC: raw.relTC)
        let endPTS: CMTime?
        if let dticks = raw.durationTicks, dticks > 0 {
            let durationMS = Int64(Double(dticks) * Double(timecodeScaleNS) / 1_000_000.0)
            endPTS = CMTimeAdd(pts, CMTime(value: durationMS, timescale: outputTimescale))
        } else {
            endPTS = nil
        }
        guard let data = try? await reader.read(offset: raw.dataOffset, length: raw.dataSize)
        else { return }
        pgsRawPackets.append(PGSRawPacket(pts: pts, endPTS: endPTS, data: data))
    }

    // MARK: - PGS Post-processing  (Sprint 28)
    //
    // Converts raw PGS byte payloads into fully-decoded PGSCue objects.
    // End time: use BlockDuration when present; otherwise derive from next packet's PTS;
    // fallback to +5 s.

    private func processPGSPackets(_ packets: [PGSRawPacket]) async -> [PGSCue] {
        guard !packets.isEmpty else { return [] }
        var cues = [PGSCue]()
        cues.reserveCapacity(packets.count / 2)

        for i in 0..<packets.count {
            let pkt = packets[i]
            let ds  = PGSParser.parseDisplaySet(data: pkt.data)
            guard ds.hasBitmap,
                  let (img, rect) = PGSParser.makeImage(from: ds)
            else { continue }

            let endTime: CMTime
            if let explicit = pkt.endPTS {
                endTime = explicit
            } else if i + 1 < packets.count {
                endTime = packets[i + 1].pts
            } else {
                endTime = CMTimeAdd(pkt.pts, CMTime(seconds: 5, preferredTimescale: outputTimescale))
            }
            cues.append(PGSCue(id:         UUID(),
                                startTime:  pkt.pts,
                                endTime:    endTime,
                                image:      img,
                                videoSize:  CGSize(width:  ds.videoWidth, height: ds.videoHeight),
                                objectRect: rect))
            fputs("[MKVDemuxer][PGS] Cue at \(String(format: "%.3f", pkt.pts.seconds))s "
                + "size=\(cgImageDims(img))  rect=\(Int(rect.origin.x)),\(Int(rect.origin.y))"
                + "+\(Int(rect.width))×\(Int(rect.height))\n", stderr)
        }
        return cues
    }

    private func cgImageDims(_ img: CGImage) -> String {
        "\(img.width)×\(img.height)"
    }

    // MARK: - Timestamp helpers

    private func makePTS(clusterTC: Int64, relTC: Int16) -> CMTime {
        let ticks = clusterTC + Int64(relTC)
        let ms    = Int64(Double(ticks) * Double(timecodeScaleNS) / 1_000_000.0)
        return CMTime(value: ms, timescale: outputTimescale)
    }

    private func makeMKVFrameInfo(fileOffset: Int64, size: Int,
                                   clusterTC: Int64, relTC: Int16,
                                   isKeyframe: Bool) -> MKVFrameInfo {
        MKVFrameInfo(fileOffset: fileOffset, size: size,
                     pts: makePTS(clusterTC: clusterTC, relTC: relTC),
                     isKeyframe: isKeyframe)
    }

    // MARK: - Public: extractVideoPackets

    func extractVideoPackets(from startIndex: Int, count: Int) async throws -> [DemuxPacket] {
        guard videoTrack != nil   else { throw MKVDemuxError.notParsed }
        guard !frameIndex.isEmpty else { throw MKVDemuxError.noVideoTrack }
        return try await extractPackets(from: frameIndex.map { ($0.fileOffset, $0.size, $0.pts, $0.isKeyframe) },
                                         startIndex: startIndex, count: count,
                                         streamType: .video,
                                         duration: .invalid)
    }

    // MARK: - Public: extractAudioPackets  (Sprint 22)

    func extractAudioPackets(from startIndex: Int, count: Int) async throws -> [DemuxPacket] {
        guard !audioFrameIndex.isEmpty else { return [] }
        let durTimescale = CMTimeScale(max(1, Int(audioSampleRate)))
        let durPerPacket = CMTime(value: Int64(audioFramesPerPacket), timescale: durTimescale)
        return try await extractPackets(from: audioFrameIndex.map { ($0.fileOffset, $0.size, $0.pts, true) },
                                         startIndex: startIndex, count: count,
                                         streamType: .audio,
                                         duration: durPerPacket)
    }

    /// Shared batched-read extraction used by both video and audio.
    private func extractPackets(from index: [(fileOffset: Int64, size: Int, pts: CMTime, isKeyframe: Bool)],
                                 startIndex: Int, count: Int,
                                 streamType: DemuxPacket.StreamType,
                                 duration: CMTime) async throws -> [DemuxPacket] {
        let endIndex = min(startIndex + count, index.count)
        guard startIndex < endIndex else { return [] }

        struct Loc { let idx: Int; let fileOff: Int64; let size: Int }
        let locs: [Loc] = (startIndex..<endIndex).compactMap { i in
            guard index[i].size > 0 else { return nil }
            return Loc(idx: i, fileOff: index[i].fileOffset, size: index[i].size)
        }

        var packets = [DemuxPacket](); packets.reserveCapacity(locs.count)
        var runStart = 0
        while runStart < locs.count {
            var runEnd = runStart + 1
            while runEnd < locs.count {
                let p = locs[runEnd - 1], c = locs[runEnd]
                if c.fileOff == p.fileOff + Int64(p.size) { runEnd += 1 } else { break }
            }
            let runOff = locs[runStart].fileOff
            let runLen = locs[runEnd - 1].fileOff + Int64(locs[runEnd - 1].size) - runOff
            guard runLen > 0 else { runStart = runEnd; continue }
            let chunk = try await reader.read(offset: runOff, length: Int(runLen))
            for j in runStart..<runEnd {
                let loc      = locs[j]
                let frame    = index[loc.idx]
                let sliceOff = Int(loc.fileOff - runOff)
                guard sliceOff + loc.size <= chunk.count else { continue }
                let data = chunk.subdata(in: sliceOff..<(sliceOff + loc.size))
                // Sprint 30: pass dts:.invalid for video so AVSampleBufferDisplayLayer
                // handles B-frame reordering from the presentation timestamps, rather
                // than assuming decode_time == presentation_time.
                // Audio dts == pts is correct (no reordering needed).
                let dts: CMTime = streamType == .video ? .invalid : frame.pts
                packets.append(DemuxPacket(
                    streamType: streamType, index: loc.idx,
                    pts: frame.pts, dts: dts, data: data,
                    isKeyframe: frame.isKeyframe, byteOffset: loc.fileOff,
                    duration: duration
                ))
            }
            runStart = runEnd
        }
        return packets
    }

    // MARK: - Public: seek helpers

    func videoPTS(forSample index: Int) -> CMTime {
        guard index >= 0, index < frameIndex.count else { return .zero }
        return frameIndex[index].pts
    }

    func findVideoKeyframeSampleIndex(nearestBeforePTS target: CMTime) -> Int {
        guard !frameIndex.isEmpty else { return 0 }
        var lo = 0, hi = frameIndex.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if frameIndex[mid].pts <= target { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        var kfIdx = best
        while kfIdx > 0 && !frameIndex[kfIdx].isKeyframe { kfIdx -= 1 }
        return kfIdx
    }

    func findAudioSampleIndex(nearestBeforePTS target: CMTime) -> Int {
        guard !audioFrameIndex.isEmpty else { return 0 }
        var lo = 0, hi = audioFrameIndex.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if audioFrameIndex[mid].pts <= target { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }

    // MARK: - Logging

    private func log(_ msg: String) { fputs("[MKVDemuxer] \(msg)\n", stderr) }
}
