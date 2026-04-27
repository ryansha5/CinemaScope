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

    // Sprint 33 / Sprint 35: DTS family decomposed into four tiers.
    //   isDTSCore — standard DTS-Core (A_DTS exact match).
    //               kAudioFormatDTS passthrough is attempted on capable hardware.
    //   isDTSHDMA — DTS-HD MA, DTS:X (lossless / object-based).
    //               Never decodable on Apple platforms; always falls back.
    //   isDTSHD   — other DTS-HD variants (HRA, etc.).
    //               Not decodable; treated as unsupported.
    //   isDTS     — broad "any DTS family" check (union of all three above).
    //
    // isDTSHDMA must be checked before isDTSHD (both match the "A_DTS/" prefix).
    var isDTSCore: Bool { codecID == "A_DTS" }
    var isDTSHDMA: Bool {
        codecID == "A_DTS/MA"       ||
        codecID == "A_DTS/LOSSLESS" ||  // alternate encoder spelling
        codecID == "A_DTS/X"           // DTS:X is built atop DTS-HD MA
    }
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

    private let parser:         MKVParser
    private let reader:         MediaReader        // raw reader — used for large batched packet extraction
    private let bufferedReader: EBMLBufferedReader // 512 KB window reader — used for all header/scan reads

    // MARK: - Sprint 43: Two-phase indexing (startup + background)
    //
    // Phase A — Startup scan:
    //   scanClusters() indexes only `startupScanSeconds` of content (~8 s) so
    //   parse() returns quickly and playback can begin.  At 497 clusters / 25 s
    //   (the original 120 s target) the overhead was prohibitive for remote MKV.
    //   At 8 s the startup index completes in ~1–2 s for typical H.265 content.
    //
    // Phase B — Background / on-demand indexing:
    //   continueIndexing(untilSeconds:) resumes from `backgroundScanCursor` and
    //   appends to frameIndex / audioFrameIndex / subtitleCues without clearing
    //   them.  The feed loop calls this synchronously when the playhead approaches
    //   the end of the indexed window.
    //
    // `minStartupScanSeconds` guarantees we never hand off fewer than 3 s to the
    // feeder even when a file has very large sparse clusters.
    private static let minStartupScanSeconds: Double =   3.0
    private static let startupScanSeconds:    Double =   8.0

    // MARK: - Sprint 43: Background-indexing state

    /// File offset from which continueIndexing() will resume scanning.
    private var backgroundScanCursor: Int64 = 0

    /// Upper bound for cluster scanning (= reader.contentLength at parse time).
    private var backgroundScanLimit:  Int64 = 0

    /// True once scanClusters has reached EOF (or continueIndexing exhausted the file).
    private(set) var isFullyIndexed: Bool = false

    /// Duration of the content currently indexed (= last frame PTS after each scan phase).
    /// Used by the feeder for fps estimation; grows as background indexing proceeds.
    private(set) var indexedDurationSeconds: Double = 0

    /// Total file duration from the Segment/Info Duration EBML field.
    /// Used for the seek-bar (PlayerLabPlaybackController.duration) and TrackInfo.
    /// Zero if the Info element does not include a Duration field.
    private(set) var fileDurationSeconds: Double = 0

    // MARK: - Indexed-frame accessors (read by controller to update feeder totals)

    /// Number of video frames in the index (grows with background indexing).
    var indexedVideoFrameCount: Int { frameIndex.count }
    /// Number of audio frames in the index (grows with background indexing).
    var indexedAudioFrameCount: Int { audioFrameIndex.count }

    /// Index of the first keyframe in the video frame index.
    /// Returns 0 when the index is empty (safe default — caller should check
    /// `indexedVideoFrameCount > 0` before using the result).
    var firstVideoKeyframeIndex: Int {
        frameIndex.firstIndex(where: { $0.isKeyframe }) ?? 0
    }

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

    // MARK: - Sprint 34 / Sprint 36: TrueHD → AC3 core extraction mode
    //
    // When enabled, extractAudioPackets() pipes each TrueHD packet through
    // TrueHDCoreExtractor and returns only the extracted AC3 frame.
    // Packets with no embedded AC3 frame are silently dropped.
    //
    // Sprint 36: audioTrack.codecFourCC is NO LONGER mutated to "ac-3".
    // The original identifier (e.g. "A_TRUEHD") is preserved.
    // AudioFormatFactory dispatches via audioPlaybackMode.effectiveCodecFourCC instead.

    private var truehDAC3Mode: Bool = false

    /// Truthful record of how the current audio track is being decoded.
    /// `.native` for all standard paths; `.extractedCore` when TrueHD AC3
    /// extraction is active (Sprint 36).
    private(set) var audioPlaybackMode: AudioTrackPlaybackMode = .native

    // MARK: - Init

    init(reader: MediaReader) {
        self.reader         = reader
        // Sprint 43: wrap the raw reader in a 512 KB buffered reader so that
        // all EBML element-header reads (1-byte ID, 1-byte size VINT, etc.)
        // are served from memory rather than triggering individual HTTP requests.
        let buf             = EBMLBufferedReader(reader: reader)
        self.bufferedReader = buf
        self.parser         = MKVParser(reader: buf)
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
        let allVideoTracks = mkvTracks.filter { $0.isVideo && ($0.isH264 || $0.isHEVC) }
        if allVideoTracks.count > 1 {
            // Multiple video tracks — log all of them.
            // Common cause: Dolby Vision Profile 7 dual-layer MKV, where track 1 is
            // the intentionally-low-bitrate Base Layer (BL) and track 2 is the
            // high-quality Enhancement Layer (EL).  We select the first track; the
            // EL cannot be decoded independently (it depends on the BL for reference
            // frames and is processed by the Dolby Vision pipeline, not standard HEVC).
            log("  ⚠️ \(allVideoTracks.count) video tracks found — selecting track 1 (BL):")
            for vt in allVideoTracks {
                log("    track \(vt.trackNumber): \(vt.codecID)  \(vt.pixelWidth)×\(vt.pixelHeight)  "
                  + "hvcC=\(vt.codecPrivate.map { "\($0.count)B" } ?? "nil")")
            }
        }
        guard let videoMKVTrack = allVideoTracks.first
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
        // Sprint 43: durationTicks uses fileDurationSeconds (true file duration from Info EBML)
        // so the seek bar reflects the correct total length even when only 8 s are indexed.
        // sampleCount is the startup-indexed count; the feeder updates its copy as background
        // indexing proceeds.
        let codecFourCC = videoMKVTrack.isH264 ? "avc1" : "hev1"
        let indexedSec    = frameIndex.last.map { $0.pts.seconds } ?? 0
        let trueDurSec    = fileDurationSeconds > 0 ? fileDurationSeconds : indexedSec
        let durationTicks = UInt64(trueDurSec * Double(outputTimescale))

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

        log("✅ parse() complete — "
          + "indexed=\(String(format: "%.1f", indexedSec))s  "
          + "fileDur=\(fileDurationSeconds > 0 ? String(format: "%.1f", fileDurationSeconds) + "s" : "unknown")  "
          + "v=\(frameIndex.count)  a=\(audioFrameIndex.count)")
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

        // Sprint 36: reset extraction mode; enableTrueHDAC3Extraction() will
        // re-apply it if needed after the rescan.
        truehDAC3Mode     = false
        audioPlaybackMode = .native

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

    // MARK: - Sprint 43: Background / on-demand indexing

    /// Continues cluster scanning from where the startup scan stopped.
    ///
    /// Called by the feed loop when the playhead approaches the end of the
    /// indexed window.  Appends new frames to `frameIndex` / `audioFrameIndex` /
    /// `subtitleCues` without clearing them.  PGS bitmap decoding is skipped
    /// for performance; SRT subtitles are collected.
    ///
    /// - Parameter targetSeconds: Scan until at least this many seconds of content
    ///   are indexed (measured from the start of the file).
    /// - Returns: `(videoAdded, audioAdded)` — number of newly indexed frames.
    @discardableResult
    func continueIndexing(untilSeconds targetSeconds: Double) async throws -> (videoAdded: Int, audioAdded: Int) {
        guard !isFullyIndexed else { return (0, 0) }
        guard backgroundScanCursor > 0, backgroundScanCursor < backgroundScanLimit else {
            isFullyIndexed = true
            return (0, 0)
        }

        let videoCountBefore = frameIndex.count
        let audioCountBefore = audioFrameIndex.count
        let scanStart        = Date()
        var clusterCount     = 0

        var cursor = backgroundScanCursor
        let limit  = backgroundScanLimit

        while cursor < limit {
            guard let (elem, hdrBytes) = try await parser.nextElement(at: cursor, limit: limit)
            else { break }

            if elem.knownID == .cluster {
                let clusterEnd = elem.payloadSize >= 0
                    ? elem.payloadOffset + elem.payloadSize : limit
                // Pass pgsTrackNum: nil to skip expensive bitmap decoding in background.
                try await parseCluster(at:               elem.payloadOffset,
                                       end:              clusterEnd,
                                       videoTrackNum:    videoTrackNum_,
                                       audioTrackNum:    selectedAudioTrackNumber,
                                       subtitleTrackNum: subtitleTrackNum_,
                                       pgsTrackNum:      nil)
                clusterCount += 1

                let indexedSec = frameIndex.last?.pts.seconds ?? 0
                if indexedSec >= targetSeconds { break }
            }

            let total = Int64(hdrBytes) + (elem.payloadSize >= 0 ? elem.payloadSize : 0)
            if total <= 0 { break }
            cursor += total
        }

        // Update cursor and EOF flag.
        backgroundScanCursor = cursor
        if cursor >= limit { isFullyIndexed = true }

        // Sort only the newly added slice (new frames have higher cluster timestamps,
        // so the sort is O(k log k) for the new k frames, not O(N log N) for all).
        if frameIndex.count > videoCountBefore {
            frameIndex[videoCountBefore...].sort { $0.pts < $1.pts }
        }
        if audioFrameIndex.count > audioCountBefore {
            audioFrameIndex[audioCountBefore...].sort { $0.pts < $1.pts }
        }
        if subtitleCues.count > 0 {
            subtitleCues.sort { $0.startTime.seconds < $1.startTime.seconds }
        }

        indexedDurationSeconds = frameIndex.last?.pts.seconds ?? 0
        let videoAdded = frameIndex.count - videoCountBefore
        let audioAdded = audioFrameIndex.count - audioCountBefore
        let elapsed    = Date().timeIntervalSince(scanStart)

        log("  [Background] indexed to \(String(format: "%.0f", indexedDurationSeconds))s "
          + "+\(videoAdded)v/+\(audioAdded)a  \(clusterCount) clusters  "
          + "\(String(format: "%.2f", elapsed))s"
          + (isFullyIndexed ? "  ✅ fully indexed" : ""))

        return (videoAdded, audioAdded)
    }

    // MARK: - Sprint 34: TrueHD → AC3 Core probe + extraction enablement

    /// Lightweight probe: reads the first `maxChecks` audio block payloads from
    /// the TrueHD track and checks each one for an embedded AC3 sync word.
    ///
    /// Returns `true` if at least one packet contains an AC3 frame.
    /// The demuxer state is not modified; call `enableTrueHDAC3Extraction` to
    /// activate extraction mode.
    ///
    /// - Parameters:
    ///   - trackNumber: The A_TRUEHD track number to probe (must be in audioFrameIndex).
    ///   - maxChecks:   Maximum number of audio packets to inspect (default 10).
    func probeTrueHDForAC3(trackNumber: UInt64, maxChecks: Int = 10) async -> Bool {
        guard !audioFrameIndex.isEmpty else { return false }
        // Run through first maxChecks frames from the audio index.
        let checkCount = min(maxChecks, audioFrameIndex.count)
        for i in 0..<checkCount {
            let frame = audioFrameIndex[i]
            guard frame.size > 0 else { continue }
            guard let data = try? await reader.read(offset: frame.fileOffset, length: frame.size)
            else { continue }
            if TrueHDCoreExtractor.hasAC3Core(in: data) {
                log("  [Sprint34] AC3 core found in TrueHD packet \(i) "
                  + "(track \(trackNumber), size=\(frame.size))")
                return true
            }
        }
        log("  [Sprint34] No AC3 core found in first \(checkCount) TrueHD packets (track \(trackNumber))")
        return false
    }

    /// Enables AC3-core extraction mode for the currently-indexed TrueHD track.
    ///
    /// After this call, `extractAudioPackets()` will pipe each TrueHD packet
    /// through `TrueHDCoreExtractor` and yield only the embedded AC3 frame.
    ///
    /// Sprint 36: `audioTrack.codecFourCC` is preserved as-is ("A_TRUEHD").
    /// `AudioFormatFactory` dispatches via `audioPlaybackMode.effectiveCodecFourCC`
    /// ("ac-3") instead of the track's own fourCC — no metadata mutation needed.
    ///
    /// - Parameters:
    ///   - channelCount: Channel count from the MKV track descriptor (informational).
    ///   - sampleRate:   Sample rate from the MKV track descriptor.
    func enableTrueHDAC3Extraction(channelCount: Int, sampleRate: Double) {
        truehDAC3Mode        = true
        audioFramesPerPacket = 1536
        audioSampleRate      = sampleRate > 0 ? sampleRate : 48_000

        // Sprint 36: record source → decoded mapping; do NOT mutate audioTrack.
        // audioTrack was built by reselectAudio() with the correct channel count
        // and sample rate from the TrueHD descriptor; no rebuild is needed.
        let sourceCodecID = audioTrack?.codecFourCC ?? "A_TRUEHD"
        audioPlaybackMode = .extractedCore(sourceCodecID: sourceCodecID, decodedAs: "ac-3")

        log("  [Sprint36] TrueHD AC3-extraction enabled — "
          + "ch=\(channelCount) sr=\(Int(audioSampleRate)) Hz  "
          + "playback: \(audioPlaybackMode.displayLabel)")
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
        // Sprint 43: increased limit to 1024 to handle files with long Title/App strings.
        let limit  = offset + 1_024
        var cursor = offset

        // Collect both values before computing fileDurationSeconds (order not guaranteed).
        var rawDurationTicks: Double = 0

        while cursor < limit {
            guard let (elem, hdrBytes) = try await parser.nextElement(at: cursor, limit: limit)
            else { break }
            switch elem.knownID {
            case .timecodeScale:
                timecodeScaleNS = try await parser.readUInt(elem)
            case .duration:
                // Info/Duration is an IEEE 754 float expressing segment duration
                // in TimecodeScale ticks.  Sprint 43: parse for true file duration.
                rawDurationTicks = try await parser.readFloat(elem)
            default: break
            }
            let total = Int64(hdrBytes) + (elem.payloadSize >= 0 ? elem.payloadSize : 0)
            cursor += max(1, total)
        }

        // Convert ticks → seconds using the (now-parsed) timecodeScale.
        if rawDurationTicks > 0 {
            fileDurationSeconds = rawDurationTicks * Double(timecodeScaleNS) / 1_000_000_000.0
            log("  [Info] Duration=\(String(format: "%.1f", fileDurationSeconds))s  "
              + "TimecodeScale=\(timecodeScaleNS)ns")
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
        // Scan the Chapters element for EditionEntry children.
        // Use the same named-tuple type that parseEditionAtoms returns so
        // append(contentsOf:) resolves without a struct↔tuple conversion.
        var raw = [(title: String, startNS: UInt64, endNS: UInt64?)]()

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

        let scanStart = Date()
        var clusterCount = 0

        let limit  = reader.contentLength
        backgroundScanLimit = limit   // Sprint 43: captured for continueIndexing()
        var cursor = segOffset

        log("  [Startup] Index target: \(Self.startupScanSeconds)s "
          + "(minimum: \(Self.minStartupScanSeconds)s)")

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
                clusterCount += 1

                // ── Sprint 43: startup early exit ─────────────────────────────
                // Exit after startupScanSeconds so parse() returns quickly.
                // continueIndexing() resumes from backgroundScanCursor on-demand.
                let indexedSec = frameIndex.last?.pts.seconds ?? 0
                if indexedSec >= Self.startupScanSeconds {
                    backgroundScanCursor = cursor  // resume point for background indexing
                    let elapsed = Date().timeIntervalSince(scanStart)
                    log("  [Startup] Startup index complete — "
                      + "\(String(format: "%.1f", indexedSec))s indexed  "
                      + "\(clusterCount) clusters  "
                      + "\(String(format: "%.2f", elapsed))s elapsed  "
                      + "fills=\(bufferedReader.fillCount)")
                    break
                }
            }
            let total = Int64(hdrBytes) + (elem.payloadSize >= 0 ? elem.payloadSize : 0)
            if total <= 0 { break }
            cursor += total
        }

        // If we reached EOF without early exit: mark fully indexed.
        if backgroundScanCursor == 0 || cursor >= limit {
            isFullyIndexed = true
            backgroundScanCursor = limit
            let elapsed = Date().timeIntervalSince(scanStart)
            let indexedSec = frameIndex.last?.pts.seconds ?? 0
            log("  [Startup] Reached EOF — fully indexed  "
              + "\(String(format: "%.1f", indexedSec))s  "
              + "\(clusterCount) clusters  "
              + "\(String(format: "%.2f", elapsed))s")
        }

        frameIndex.sort      { $0.pts < $1.pts }
        audioFrameIndex.sort { $0.pts < $1.pts }
        subtitleCues.sort    { $0.startTime.seconds < $1.startTime.seconds }   // Sprint 26
        indexedDurationSeconds = frameIndex.last?.pts.seconds ?? 0
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

                    // Sprint 46 block-level diagnostics — first kBlockDiagMax video blocks.
                    // Logs the EBML-level payload size (what the container reports) alongside
                    // the derived dataSize (payload minus block header).  If dataSize is tiny
                    // while elemPayload looks correct the bug is in header-byte accounting;
                    // if both are tiny the EBML parser itself is mis-reading element boundaries.
                    if blockDiagCount < Self.kBlockDiagMax {
                        blockDiagCount += 1
                        let blockType = elem.knownID == .simpleBlock ? "SimpleBlock" : "BlockGroup"
                        log("[BlockDiag #\(blockDiagCount)] \(blockType)  "
                          + "track=\(raw.trackNum)  elemPayload=\(elem.payloadSize)B  "
                          + "dataSize=\(raw.dataSize)B  lacing=\(raw.lacingType)  "
                          + "keyframe=\(raw.isKeyframe)  relTC=\(raw.relTC)")
                    }

                    if raw.lacingType == 0, raw.dataSize > 0 {
                        frameIndex.append(makeMKVFrameInfo(fileOffset: raw.dataOffset,
                                                            size:       raw.dataSize,
                                                            clusterTC:  clusterTimecode,
                                                            relTC:      raw.relTC,
                                                            isKeyframe: raw.isKeyframe))
                    } else if raw.lacingType != 0 {
                        // Video lacing is extremely rare in real files and not yet handled.
                        // Log and drop so the caller at least sees it in diagnostics.
                        lacedVideoBlocksDropped += 1
                        if lacedVideoBlocksDropped <= 5 {
                            log("[BlockDiag] ⚠️ VIDEO block with lacingType=\(raw.lacingType) "
                              + "— DROPPED (video lacing not yet supported)  "
                              + "dataSize=\(raw.dataSize)B  relTC=\(raw.relTC)")
                        }
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
        // Sprint 43: use bufferedReader for this small header read so it is served
        // from the 512 KB window rather than issuing a separate HTTP Range request.
        guard let tcBuf = try? await bufferedReader.readBytes(at: tcOffset, length: 3),
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
                            lacingType: (flags >> 2) & 0x03,   // bits 3:2 per Matroska spec
                            durationTicks: nil)   // SimpleBlock has no BlockDuration
    }

    /// One-time flag: log EL sizes for the first few BlockGroups with BlockAdditions only.
    private var blockAdditionsLogCount = 0
    private static let kBlockAdditionsLogMax = 5

    /// Block-level diagnostic counters (Sprint 46).
    /// kBlockDiagMax: number of video blocks to log in full before silencing per-block output.
    private var blockDiagCount         = 0
    private static let kBlockDiagMax   = 50
    private var lacedVideoBlocksDropped = 0

    private func decodeBlockGroup(_ elem: EBMLElement) async throws -> RawBlockInfo? {
        guard elem.payloadSize > 0 else { return nil }
        var blockElem:      EBMLElement? = nil
        var hasRefBlock:    Bool         = false
        var blockDurTicks:  Int64?       = nil   // Sprint 26
        var elPayloadSize:  Int64?       = nil   // Dolby Vision EL size (in BlockAdditions)

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
            if child.knownID == .blockAdditions, child.payloadSize > 0 {
                // Dolby Vision Profile 7: EL is stored in BlockAdditions/BlockMore/BlockAdditional
                // with BlockAddID = 1.  Scan for the BlockAdditional payload to get the EL size.
                var aCursor = child.payloadOffset
                let aLimit  = child.payloadOffset + child.payloadSize
                while aCursor < aLimit {
                    guard let (addChild, addBytes) = try? await parser.nextElement(at: aCursor, limit: aLimit)
                    else { break }
                    if addChild.knownID == .blockMore, addChild.payloadSize > 0 {
                        var mCursor = addChild.payloadOffset
                        let mLimit  = addChild.payloadOffset + addChild.payloadSize
                        while mCursor < mLimit {
                            guard let (mChild, mBytes) = try? await parser.nextElement(at: mCursor, limit: mLimit)
                            else { break }
                            if mChild.knownID == .blockAdditional {
                                elPayloadSize = mChild.payloadSize
                            }
                            mCursor += max(1, Int64(mBytes) + (mChild.payloadSize >= 0 ? mChild.payloadSize : 0))
                        }
                    }
                    aCursor += max(1, Int64(addBytes) + (addChild.payloadSize >= 0 ? addChild.payloadSize : 0))
                }
            }
            cursor += max(1, Int64(chBytes) + (child.payloadSize >= 0 ? child.payloadSize : 0))
        }

        // Log the first few DV EL sizes so we can confirm the structure.
        if let elSize = elPayloadSize, blockAdditionsLogCount < Self.kBlockAdditionsLogMax {
            blockAdditionsLogCount += 1
            let blSize = blockElem.map { Int($0.payloadSize) } ?? 0
            log("[DV-EL] BlockGroup #\(blockAdditionsLogCount): "
              + "BL=\(blSize)B  EL(BlockAdditional)=\(elSize)B  "
              + "combined=\(blSize + Int(elSize))B  "
              + "(VideoToolbox decodes BL only — EL requires Dolby Vision pipeline)")
        }

        guard let blk = blockElem, blk.payloadSize > 4 else { return nil }
        guard let (trackNum, vintWidth) = try? await parser.readVINT(at: blk.payloadOffset)
        else { return nil }
        let tcOffset = blk.payloadOffset + Int64(vintWidth)
        // Sprint 43: bufferedReader for this 3-byte header read (same as decodeSimpleBlock).
        guard let tcBuf = try? await bufferedReader.readBytes(at: tcOffset, length: 3),
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
                            lacingType: (flags >> 2) & 0x03,   // bits 3:2 per Matroska spec
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
        // Sprint 43: lacing header is small and sequential — served from 512 KB window.
        guard let hdr = try? await bufferedReader.readBytes(at: dataOffset, length: readLen),
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
        // Sprint 43: 1-byte header — always within the current window.
        guard let hdr = try? await bufferedReader.readBytes(at: dataOffset, length: 1),
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
              // Sprint 43: subtitle text payloads are small and sequential —
              // served from the 512 KB window during cluster scan.
              let textData = try? await bufferedReader.readBytes(at: raw.dataOffset, length: raw.dataSize),
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
        // Sprint 43: PGS payloads are typically <100 KB and sequential — use
        // the 512 KB window.  Very large PGS packets fall back to a direct read
        // transparently via EBMLBufferedReader's fallback path.
        guard let data = try? await bufferedReader.readBytes(at: raw.dataOffset, length: raw.dataSize)
        else { return }
        pgsRawPackets.append(PGSRawPacket(pts: pts, endPTS: endPTS, data: data))
    }

    // MARK: - PGS Post-processing  (Sprint 28 / Sprint 38 / Sprint 39)
    //
    // Converts raw PGS byte payloads into fully-decoded PGSCue objects.
    //
    // Sprint 38: passes isForced and windowRect through to each PGSCue.
    //
    // Sprint 39: pending-cue timing pattern.
    //   Content display sets (ds.hasBitmap) are held as "pending" until their
    //   end time is known.  End time is resolved from the first of:
    //     1. An explicit BlockDuration on the content packet itself (endPTS).
    //     2. The PTS of the following clear display set (ds.isClearSet).
    //     3. The PTS of the next content display set (no clear in between).
    //     4. +5 s fallback at end of input.
    //
    // This is more accurate than the Sprint 28 approach of using packets[i+1].pts
    // uniformly, which silently relied on clear sets coincidentally being the next
    // packet — correct for normal MKV PGS, but fragile for unusual encodings.

    private func processPGSPackets(_ packets: [PGSRawPacket]) async -> [PGSCue] {
        guard !packets.isEmpty else { return [] }
        var cues = [PGSCue]()
        cues.reserveCapacity(packets.count / 2)

        // Lightweight store for the pending content display set.
        struct Pending {
            let pts:       CMTime
            let img:       CGImage
            let rect:      CGRect
            let videoSize: CGSize
            let isForced:  Bool
            let windowRect: CGRect?
        }
        var pending: Pending? = nil

        for pkt in packets {
            let ds = PGSParser.parseDisplaySet(data: pkt.data)

            if ds.isClearSet {
                // Clear display set — emit any pending cue using this packet's PTS
                // as the end time.  Use endPTS if BlockDuration was supplied; otherwise
                // the clear PTS is the exact moment the image is erased.
                if let p = pending {
                    let endTime = pkt.endPTS ?? pkt.pts
                    cues.append(PGSCue(id:         UUID(),
                                       startTime:  p.pts,
                                       endTime:    endTime,
                                       image:      p.img,
                                       videoSize:  p.videoSize,
                                       objectRect: p.rect,
                                       isForced:   p.isForced,
                                       windowRect: p.windowRect))
                    fputs("[MKVDemuxer][PGS] Cue "
                        + "\(String(format: "%.3f", p.pts.seconds))→"
                        + "\(String(format: "%.3f", endTime.seconds))s "
                        + "(clear-set end)  forced=\(p.isForced)  "
                        + "\(cgImageDims(p.img))  "
                        + "rect=\(Int(p.rect.origin.x)),\(Int(p.rect.origin.y))"
                        + "+\(Int(p.rect.width))×\(Int(p.rect.height))\n", stderr)
                    pending = nil
                }

            } else if ds.hasBitmap, let (img, rect) = PGSParser.makeImage(from: ds) {
                // Content display set — emit any pending cue first (no clear in between).
                if let p = pending {
                    cues.append(PGSCue(id:         UUID(),
                                       startTime:  p.pts,
                                       endTime:    pkt.pts,
                                       image:      p.img,
                                       videoSize:  p.videoSize,
                                       objectRect: p.rect,
                                       isForced:   p.isForced,
                                       windowRect: p.windowRect))
                    fputs("[MKVDemuxer][PGS] Cue "
                        + "\(String(format: "%.3f", p.pts.seconds))→"
                        + "\(String(format: "%.3f", pkt.pts.seconds))s "
                        + "(next-content end)  forced=\(p.isForced)  "
                        + "\(cgImageDims(p.img))  "
                        + "rect=\(Int(p.rect.origin.x)),\(Int(p.rect.origin.y))"
                        + "+\(Int(p.rect.width))×\(Int(p.rect.height))\n", stderr)
                    pending = nil
                }

                // Build the Sprint 38 fields.
                let isForced   = !ds.forcedObjectIDs.isEmpty
                let windowID   = ds.compositionObjects.first?.windowID
                let windowRect = windowID.flatMap { ds.windowRects[$0] }

                if let explicitEnd = pkt.endPTS {
                    // BlockDuration present — emit immediately; no need to hold pending.
                    cues.append(PGSCue(id:         UUID(),
                                       startTime:  pkt.pts,
                                       endTime:    explicitEnd,
                                       image:      img,
                                       videoSize:  CGSize(width: ds.videoWidth, height: ds.videoHeight),
                                       objectRect: rect,
                                       isForced:   isForced,
                                       windowRect: windowRect))
                    fputs("[MKVDemuxer][PGS] Cue "
                        + "\(String(format: "%.3f", pkt.pts.seconds))→"
                        + "\(String(format: "%.3f", explicitEnd.seconds))s "
                        + "(explicit dur)  forced=\(isForced)  "
                        + "\(cgImageDims(img))  "
                        + "rect=\(Int(rect.origin.x)),\(Int(rect.origin.y))"
                        + "+\(Int(rect.width))×\(Int(rect.height))\n", stderr)
                } else {
                    // No explicit duration — hold as pending until clear or next content.
                    pending = Pending(pts:       pkt.pts,
                                     img:       img,
                                     rect:      rect,
                                     videoSize: CGSize(width: ds.videoWidth, height: ds.videoHeight),
                                     isForced:  isForced,
                                     windowRect: windowRect)
                }
            }
            // Non-clear, non-bitmap sets (e.g. palette-only partial updates) are skipped.
        }

        // End of input: emit any remaining pending cue with a +5 s fallback.
        if let p = pending {
            let endTime = CMTimeAdd(p.pts, CMTime(seconds: 5, preferredTimescale: outputTimescale))
            cues.append(PGSCue(id:         UUID(),
                               startTime:  p.pts,
                               endTime:    endTime,
                               image:      p.img,
                               videoSize:  p.videoSize,
                               objectRect: p.rect,
                               isForced:   p.isForced,
                               windowRect: p.windowRect))
            fputs("[MKVDemuxer][PGS] Cue "
                + "\(String(format: "%.3f", p.pts.seconds))→"
                + "\(String(format: "%.3f", endTime.seconds))s "
                + "(fallback +5s)  forced=\(p.isForced)  "
                + "\(cgImageDims(p.img))  "
                + "rect=\(Int(p.rect.origin.x)),\(Int(p.rect.origin.y))"
                + "+\(Int(p.rect.width))×\(Int(p.rect.height))\n", stderr)
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

    /// One-time flag: log index sizes for the very first extraction call only.
    private var didLogIndexSizes = false

    func extractVideoPackets(from startIndex: Int, count: Int) async throws -> [DemuxPacket] {
        guard videoTrack != nil   else { throw MKVDemuxError.notParsed }
        guard !frameIndex.isEmpty else { throw MKVDemuxError.noVideoTrack }

        // Log raw MKV-declared frame sizes from the index for the first call.
        // These are the sizes AS REPORTED by the MKV container (SimpleBlock/Block payload),
        // before any extraction.  If they match the SampleDiag rawSize values, the
        // demuxer is reading correct boundaries.  Very small sizes suggest DV Profile 7 BL.
        if !didLogIndexSizes {
            didLogIndexSizes = true

            // Per-frame log: first 10 entries
            let sampleCount = min(10, frameIndex.count)
            log("[FrameIndex] First \(sampleCount) frame sizes from MKV index:")
            for i in 0..<sampleCount {
                let fi = frameIndex[i]
                log("  [\(i)] size=\(fi.size)B  pts=\(String(format: "%.3f", fi.pts.seconds))s  "
                  + "keyframe=\(fi.isKeyframe)  offset=\(fi.fileOffset)")
            }

            // Sprint 46: aggregate statistics over first 250 index entries.
            // These are the sizes the container reports — before any normalization.
            // Tiny sizes here confirm the demuxer is extracting wrong boundaries.
            let statCount = min(250, frameIndex.count)
            if statCount > 1 {
                let slice      = frameIndex.prefix(statCount)
                let interSlice = slice.filter { !$0.isKeyframe }
                let keySlice   = slice.filter {  $0.isKeyframe }

                func stats(_ frames: [MKVFrameInfo]) -> (avg: Int, min: Int, max: Int) {
                    let s = frames.map { $0.size }
                    let total = s.reduce(0, +)
                    return (avg: total / max(1, s.count),
                            min: s.min() ?? 0,
                            max: s.max() ?? 0)
                }

                if !keySlice.isEmpty {
                    let (a, mn, mx) = stats(Array(keySlice))
                    log("[FrameIndex] Keyframe stats (\(keySlice.count) keyframes in first \(statCount)):"
                      + "  avg=\(a)B  min=\(mn)B  max=\(mx)B")
                }

                if !interSlice.isEmpty {
                    let (a, mn, mx) = stats(Array(interSlice))
                    log("[FrameIndex] Inter-frame stats (\(interSlice.count) inter-frames in first \(statCount)):"
                      + "  avg=\(a)B  min=\(mn)B  max=\(mx)B")
                    if a < 500 {
                        log("[FrameIndex] ⚠️  avg inter-frame=\(a)B — suspiciously small.  "
                          + "Expected >10 KB for 1080p HEVC, >50 KB for 4K.  "
                          + "Root cause is likely wrong EBML element boundaries or "
                          + "incorrect headerBytes accounting in decodeSimpleBlock/decodeBlockGroup.")
                    }
                }

                if lacedVideoBlocksDropped > 0 {
                    log("[FrameIndex] ⚠️  \(lacedVideoBlocksDropped) laced VIDEO blocks were dropped "
                      + "(video lacing not yet supported)")
                }
            }
        }

        return try await extractPackets(from: frameIndex.map { ($0.fileOffset, $0.size, $0.pts, $0.isKeyframe) },
                                         startIndex: startIndex, count: count,
                                         streamType: .video,
                                         duration: .invalid)
    }

    // MARK: - Public: extractAudioPackets  (Sprint 22 / Sprint 34)

    func extractAudioPackets(from startIndex: Int, count: Int) async throws -> [DemuxPacket] {
        guard !audioFrameIndex.isEmpty else { return [] }
        let durTimescale = CMTimeScale(max(1, Int(audioSampleRate)))
        let durPerPacket = CMTime(value: Int64(audioFramesPerPacket), timescale: durTimescale)
        let raw = try await extractPackets(
            from:       audioFrameIndex.map { ($0.fileOffset, $0.size, $0.pts, true) },
            startIndex: startIndex,
            count:      count,
            streamType: .audio,
            duration:   durPerPacket
        )

        // Sprint 34: TrueHD AC3-core extraction mode.
        // Each TrueHD packet is scanned for an embedded AC3 sync frame.
        // Packets with no AC3 core are silently dropped (they carry only TrueHD
        // extension data).  The extracted AC3 frame replaces the original data,
        // and the packet's duration is updated to reflect 1536 PCM frames.
        guard truehDAC3Mode else { return raw }

        var extracted = [DemuxPacket]()
        extracted.reserveCapacity(raw.count)
        for pkt in raw {
            guard let ac3Data = TrueHDCoreExtractor.extractFirstAC3Frame(from: pkt.data)
            else { continue }   // no AC3 core in this packet — drop it
            extracted.append(DemuxPacket(
                streamType: pkt.streamType,
                index:      pkt.index,
                pts:        pkt.pts,
                dts:        pkt.dts,
                data:       ac3Data,
                isKeyframe: pkt.isKeyframe,
                byteOffset: pkt.byteOffset,
                duration:   durPerPacket
            ))
        }
        return extracted
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
