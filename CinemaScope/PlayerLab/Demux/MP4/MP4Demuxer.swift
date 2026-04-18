// MARK: - PlayerLab / Demux / MP4 / MP4Demuxer
//
// Minimal ISOBMFF / MP4 demuxer scoped to H.264 video track extraction.
//
// Scope:
//   • Local files with standard (non-fragmented) box structure
//   • H.264 (avc1 / avc3) video track
//   • Correct sample timestamps (stts + ctts) and keyframe flags (stss)
//
// Out of scope (TODOs for later):
//   • Fragmented MP4 (moof + mdat)
//   • Encrypted content (sinf / enc*)
//   • External data references
//   • HEVC, AV1, VP9
//   • Audio track extraction
//
// Usage:
//   let reader = MediaReader(url: fileURL)
//   try await reader.open()
//   let demuxer = MP4Demuxer(reader: reader)
//   try await demuxer.parse()
//   let packets = try await demuxer.extractPackets(count: 10)

import Foundation
import CoreMedia

// MARK: - Errors

enum MP4DemuxError: Error, LocalizedError {
    case readerNotOpened
    case notAnMP4File
    case moovNotFound
    case videoTrackNotFound
    case noAvcCData
    case incompleteStbl(String)
    case sampleNotFound(Int)
    case chunkIndexOutOfBounds(Int)

    var errorDescription: String? {
        switch self {
        case .readerNotOpened:              return "MediaReader not opened before MP4Demuxer.parse()"
        case .notAnMP4File:                 return "No ftyp or moov box found — not an MP4 file"
        case .moovNotFound:                 return "moov box not found"
        case .videoTrackNotFound:           return "No video track in this file"
        case .noAvcCData:                   return "Video track has no avcC — HEVC or non-H.264 codec?"
        case .incompleteStbl(let m):        return "Sample table incomplete: \(m)"
        case .sampleNotFound(let i):        return "Sample \(i) not resolved in stsc/stco"
        case .chunkIndexOutOfBounds(let i): return "Chunk index \(i) out of bounds in stco"
        }
    }
}

// MARK: - MP4Demuxer

final class MP4Demuxer {

    // MARK: - Public results (populated after parse())

    private(set) var tracks:     [TrackInfo] = []
    private(set) var videoTrack: TrackInfo?  = nil
    /// Sprint 13: first audio track (soun handler, mp4a codec).
    private(set) var audioTrack: TrackInfo?  = nil

    // MARK: - IO

    private let reader: MediaReader

    // MARK: - Per-track accumulator (reset at each trak boundary)

    private var accTrackID:        UInt32  = 0
    private var accHandlerType:    String  = ""
    private var accTimescale:      UInt32  = 0
    private var accDurationTicks:  UInt64  = 0
    private var accSampleCount:    Int     = 0
    private var accCodecFourCC:    String? = nil
    private var accDisplayWidth:   UInt16? = nil
    private var accDisplayHeight:  UInt16? = nil
    private var accAvcCData:       Data?   = nil
    private var accHvcCData:       Data?   = nil    // Sprint 12: HEVC parameter sets

    // Sprint 13: audio-specific accumulator fields
    private var accEsdsData:        Data?   = nil   // esds box payload (ES_Descriptor)
    private var accChannelCount:    UInt16? = nil   // mp4a channelcount
    private var accAudioSampleRate: Double? = nil   // mp4a samplerate (Hz)

    // Sample table accumulator
    private var accSttsEntries:     [(count: Int, delta: Int)] = []
    private var accCttsEntries:     [(count: Int, offset: Int32)] = []
    private var accStssSet:         Set<Int> = []    // 1-based sample numbers
    private var accStscEntries:     [(firstChunk: Int, samplesPerChunk: Int)] = []
    private var accSampleSizes:     [Int]    = []
    private var accFixedSampleSize: Int      = 0
    private var accChunkOffsets:    [Int64]  = []
    private var accHasCtts:         Bool     = false
    private var accHasStss:         Bool     = false

    // MARK: - Video-track sample tables (snapshotted after finalizeTrack)
    // Used by extractPackets() — kept separate from accumulator so re-parse
    // doesn't accidentally clobber them mid-iteration.

    private var vtSttsEntries:     [(count: Int, delta: Int)] = []
    private var vtCttsEntries:     [(count: Int, offset: Int32)] = []
    private var vtStssSet:         Set<Int>  = []
    private var vtStscEntries:     [(firstChunk: Int, samplesPerChunk: Int)] = []
    private var vtSampleSizes:     [Int]     = []
    private var vtFixedSampleSize: Int       = 0
    private var vtChunkOffsets:    [Int64]   = []
    private var vtHasCtts:         Bool      = false
    private var vtHasStss:         Bool      = false
    private var vtTimescale:       UInt32    = 0

    // MARK: - Audio-track sample tables (snapshotted after finalizeTrack)  — Sprint 13

    private var atSttsEntries:     [(count: Int, delta: Int)] = []
    private var atStscEntries:     [(firstChunk: Int, samplesPerChunk: Int)] = []
    private var atSampleSizes:     [Int]     = []
    private var atFixedSampleSize: Int       = 0
    private var atChunkOffsets:    [Int64]   = []
    private var atTimescale:       UInt32    = 0
    private var atSampleCount:     Int       = 0

    // MARK: - Parser state flags

    private var insideTrak: Bool = false

    // MARK: - Init

    init(reader: MediaReader) {
        self.reader = reader
    }

    // MARK: - Parse

    /// Walk the entire MP4 box tree and populate `tracks` and `videoTrack`.
    /// Requires `reader.open()` to have been called first.
    func parse() async throws {
        guard reader.contentLength > 0 else { throw MP4DemuxError.readerNotOpened }
        tracks     = []
        videoTrack = nil
        audioTrack = nil
        try await parseBoxes(at: 0, length: reader.contentLength, depth: 0)
        videoTrack = tracks.first { if case .video = $0.trackType { return true }; return false }
        audioTrack = tracks.first { if case .audio = $0.trackType { return true }; return false }
    }

    // MARK: - Box Tree Walker

    private func parseBoxes(at startOffset: Int64, length: Int64, depth: Int) async throws {
        var offset    = startOffset
        let endOffset = startOffset + length

        while offset < endOffset {
            // Need at least 8 bytes for a box header
            guard endOffset - offset >= 8 else { break }

            let header  = try await reader.read(offset: offset, length: 8)
            let size32  = header.mp4UInt32BE(at: 0)
            let boxType = header.mp4FourCC(at: 4)

            // Initialize with the common case (normal 32-bit size, 8-byte header).
            // The switch below overrides for the two special size32 values.
            var headerSize:   Int   = 8
            var boxTotalSize: Int64 = Int64(size32)

            switch size32 {
            case 1:
                // Extended 64-bit size in the 8 bytes immediately after the header.
                // If there isn't room, skip the 8-byte stub and try to resync.
                guard endOffset - offset >= 16 else { offset += 8; continue }
                let ext      = try await reader.read(offset: offset + 8, length: 8)
                boxTotalSize = Int64(bitPattern: ext.mp4UInt64BE(at: 0))
                headerSize   = 16
            case 0:
                // size == 0 means the box extends to the end of its parent.
                boxTotalSize = endOffset - offset
            default:
                break   // already initialised above
            }

            guard boxTotalSize >= Int64(headerSize) else {
                // Malformed box — skip 8 bytes and try to resync
                offset += 8; continue
            }

            let box = MP4Box(type: boxType,
                             fileOffset: offset,
                             headerSize: headerSize,
                             totalSize:  boxTotalSize)

            if box.isContainer {
                let isTrak = (boxType == "trak")
                if isTrak {
                    resetAccumulator()
                    insideTrak = true
                }
                try await parseBoxes(at: box.payloadOffset, length: box.payloadSize, depth: depth + 1)
                if isTrak {
                    finalizeTrack()
                    insideTrak = false
                }
            } else if insideTrak {
                try await parseLeaf(box)
            }
            // else: top-level non-container leaf (ftyp, mdat, free …) — skip

            offset += boxTotalSize
        }
    }

    // MARK: - Leaf Box Dispatch

    private func parseLeaf(_ box: MP4Box) async throws {
        switch box.type {
        case "tkhd": try await parseTkhd(box)
        case "mdhd": try await parseMdhd(box)
        case "hdlr": try await parseHdlr(box)
        case "stsd": try await parseStsd(box)
        case "stts": try await parseStts(box)
        case "ctts": try await parseCtts(box)
        case "stss": try await parseStss(box)
        case "stsc": try await parseStsc(box)
        case "stsz": try await parseStsz(box)
        case "stco": try await parseStco(box)
        case "co64": try await parseCo64(box)
        default:     break
        }
    }

    // MARK: - tkhd (Track Header Box)
    //
    // Layout (v0, 84-byte payload):
    //   [0-3]   version(1)+flags(3)
    //   [4-7]   creation_time
    //   [8-11]  modification_time
    //   [12-15] track_id
    //   [16-19] reserved
    //   [20-23] duration
    //   [24-31] reserved[2]
    //   [32-33] layer
    //   [34-35] alternate_group
    //   [36-37] volume
    //   [38-39] reserved
    //   [40-75] matrix[9] (36 bytes)
    //   [76-79] width (fixed-point 16.16)
    //   [80-83] height (fixed-point 16.16)
    //
    // v1 shifts by 8 bytes (creation_time and modification_time are 8 bytes each):
    //   track_id at [20], duration at [28-35], width at [84], height at [88]

    private func parseTkhd(_ box: MP4Box) async throws {
        guard box.payloadSize >= 4 else { return }
        let vbyte  = try await reader.read(offset: box.payloadOffset, length: 1)
        let isV1   = vbyte.mp4UInt8(at: 0) == 1
        let needed = isV1 ? 96 : 84
        guard box.payloadSize >= Int64(needed) else { return }
        let data   = try await reader.read(offset: box.payloadOffset, length: needed)

        if isV1 {
            accTrackID       = data.mp4UInt32BE(at: 20)
            accDisplayWidth  = data.mp4UInt16BE(at: 84)   // integer part of fixed-point
            accDisplayHeight = data.mp4UInt16BE(at: 88)
        } else {
            accTrackID       = data.mp4UInt32BE(at: 12)
            accDisplayWidth  = data.mp4UInt16BE(at: 76)
            accDisplayHeight = data.mp4UInt16BE(at: 80)
        }
    }

    // MARK: - mdhd (Media Header Box)
    //
    // v0: timescale at [12], duration(u32) at [16]
    // v1: timescale at [20], duration(u64) at [24]

    private func parseMdhd(_ box: MP4Box) async throws {
        guard box.payloadSize >= 4 else { return }
        let vbyte  = try await reader.read(offset: box.payloadOffset, length: 1)
        let isV1   = vbyte.mp4UInt8(at: 0) == 1
        let needed = isV1 ? 36 : 24
        guard box.payloadSize >= Int64(needed) else { return }
        let data   = try await reader.read(offset: box.payloadOffset, length: needed)

        if isV1 {
            accTimescale     = data.mp4UInt32BE(at: 20)
            accDurationTicks = data.mp4UInt64BE(at: 24)
        } else {
            accTimescale     = data.mp4UInt32BE(at: 12)
            accDurationTicks = UInt64(data.mp4UInt32BE(at: 16))
        }
    }

    // MARK: - hdlr (Handler Reference Box)
    //
    // [0-3]  version+flags
    // [4-7]  pre_defined (always 0)
    // [8-11] handler_type FourCC: "vide", "soun", "subt", …

    private func parseHdlr(_ box: MP4Box) async throws {
        guard box.payloadSize >= 12 else { return }
        let data = try await reader.read(offset: box.payloadOffset, length: 12)
        accHandlerType = data.mp4FourCC(at: 8)
    }

    // MARK: - stsd (Sample Description Box)
    //
    // We scan for the first sample entry and extract:
    //   • codec FourCC ("avc1", "hev1", …)
    //   • avcC child box payload (SPS + PPS) for H.264
    //
    // stsd payload layout:
    //   [0-3]   version+flags
    //   [4-7]   entry_count
    //   [8-11]  first entry size
    //   [12-15] first entry type  ← codec FourCC
    //   [16-93] VisualSampleEntry fixed header (for avc1)
    //   [94+]   child boxes of avc1 (avcC is first)

    private func parseStsd(_ box: MP4Box) async throws {
        // 8 192 bytes: enough for any realistic stsd payload (hvcC from libx265
        // can include colr/pasp/btrt boxes before hvcC, and ffmpeg may append a
        // 4th NAL array (prefix SEI) that pushes the hvcC payload deeper than the
        // old 1 024-byte cap allowed).
        let readLen = Int(min(box.payloadSize, 8192))
        guard readLen >= 16 else { return }
        let data = try await reader.read(offset: box.payloadOffset, length: readLen)

        // entry_count at [4] — we only look at the first entry
        let entryType = data.mp4FourCC(at: 12)
        accCodecFourCC = entryType

        if entryType == "avc1" || entryType == "avc3" {
            // Scan for avcC starting after the 94-byte fixed VisualSampleEntry structure.
            accAvcCData = findChildBox(type: "avcC", in: data, from: 94)
        } else if entryType == "hvc1" || entryType == "hev1" {
            // Sprint 12: HEVC — hvcC lives at the same offset as avcC in H.264.
            // Both codecs share the same VisualSampleEntry base layout (86-byte
            // fixed header visible from the stsd entry, child boxes at offset 94).
            accHvcCData = findChildBox(type: "hvcC", in: data, from: 94)
        } else if entryType == "mp4a" {
            // Sprint 13: AAC audio.
            // AudioSampleEntry layout (from stsd payload start):
            //   [0-7]   stsd header (version+flags + entry_count)
            //   [8-15]  entry size + type "mp4a"
            //   [16-21] reserved (6 bytes)
            //   [22-23] data_reference_index
            //   [24-31] reserved (8 bytes)   AudioSampleEntry base
            //   [32-33] channelcount
            //   [34-35] samplesize (usually 16)
            //   [36-37] pre_defined
            //   [38-39] reserved
            //   [40-43] samplerate (fixed-point 16.16; upper 16 bits = Hz)
            //   [44+]   child boxes (esds)
            if data.count >= 44 {
                accChannelCount    = data.mp4UInt16BE(at: 32)
                let rateFixed      = data.mp4UInt32BE(at: 40)
                accAudioSampleRate = Double(rateFixed >> 16)
                accEsdsData        = findChildBox(type: "esds", in: data, from: 44)
            }
        }
    }

    /// Scan `data` starting at `from` for a box with the given type.
    /// Returns the box payload (excluding the 8-byte header) or nil.
    private func findChildBox(type target: String, in data: Data, from start: Int) -> Data? {
        var i = start
        while i + 8 <= data.count {
            let size = Int(data.mp4UInt32BE(at: i))
            guard size >= 8 else { break }
            let btype = data.mp4FourCC(at: i + 4)
            if btype == target {
                let payloadStart = i + 8
                let payloadEnd   = min(i + size, data.count)
                guard payloadEnd > payloadStart else { return nil }
                return data.subdata(in: payloadStart..<payloadEnd)
            }
            i += size
        }
        return nil
    }

    // MARK: - stts (Time-to-Sample)
    //
    // [0-7]   version+flags + entry_count
    // For each entry: sample_count(4) + sample_delta(4)
    // DTS[0]=0, DTS[i] = sum of (count × delta) for all preceding entries.

    private func parseStts(_ box: MP4Box) async throws {
        guard box.payloadSize >= 8 else { return }
        let hdr        = try await reader.read(offset: box.payloadOffset, length: 8)
        let entryCount = Int(hdr.mp4UInt32BE(at: 4))
        guard entryCount > 0 else { return }
        let tableBytes = entryCount * 8
        guard box.payloadSize >= 8 + Int64(tableBytes) else { return }
        let table = try await reader.read(offset: box.payloadOffset + 8, length: tableBytes)
        accSttsEntries.reserveCapacity(entryCount)
        for i in 0..<entryCount {
            accSttsEntries.append((
                count: Int(table.mp4UInt32BE(at: i * 8)),
                delta: Int(table.mp4UInt32BE(at: i * 8 + 4))
            ))
        }
    }

    // MARK: - ctts (Composition Time Offset)
    //
    // PTS = DTS + ctts offset.
    // v1 ctts uses signed offsets; v0 is nominally unsigned but sign-extended in practice.

    private func parseCtts(_ box: MP4Box) async throws {
        guard box.payloadSize >= 8 else { return }
        let hdr        = try await reader.read(offset: box.payloadOffset, length: 8)
        let version    = hdr.mp4UInt8(at: 0)
        let entryCount = Int(hdr.mp4UInt32BE(at: 4))
        guard entryCount > 0 else { return }
        let tableBytes = entryCount * 8
        guard box.payloadSize >= 8 + Int64(tableBytes) else { return }
        let table = try await reader.read(offset: box.payloadOffset + 8, length: tableBytes)
        accCttsEntries.reserveCapacity(entryCount)
        for i in 0..<entryCount {
            let cnt = Int(table.mp4UInt32BE(at: i * 8))
            let off: Int32
            if version == 1 {
                off = table.mp4Int32BE(at: i * 8 + 4)
            } else {
                off = Int32(bitPattern: table.mp4UInt32BE(at: i * 8 + 4))
            }
            accCttsEntries.append((count: cnt, offset: off))
        }
        accHasCtts = true
    }

    // MARK: - stss (Sync Sample / Keyframe Table)
    //
    // 1-based sample numbers that are sync points (IDR frames for H.264).
    // If stss is absent, all samples are sync points.

    private func parseStss(_ box: MP4Box) async throws {
        guard box.payloadSize >= 8 else { return }
        let hdr        = try await reader.read(offset: box.payloadOffset, length: 8)
        let entryCount = Int(hdr.mp4UInt32BE(at: 4))
        guard entryCount > 0 else { return }
        let tableBytes = entryCount * 4
        guard box.payloadSize >= 8 + Int64(tableBytes) else { return }
        let table = try await reader.read(offset: box.payloadOffset + 8, length: tableBytes)
        for i in 0..<entryCount {
            accStssSet.insert(Int(table.mp4UInt32BE(at: i * 4)))
        }
        accHasStss = true
    }

    // MARK: - stsc (Sample-to-Chunk)
    //
    // Run-length encodes which chunks have how many samples.
    // Each entry: first_chunk(4, 1-based) + samples_per_chunk(4) + sample_desc_index(4)

    private func parseStsc(_ box: MP4Box) async throws {
        guard box.payloadSize >= 8 else { return }
        let hdr        = try await reader.read(offset: box.payloadOffset, length: 8)
        let entryCount = Int(hdr.mp4UInt32BE(at: 4))
        guard entryCount > 0 else { return }
        let tableBytes = entryCount * 12
        guard box.payloadSize >= 8 + Int64(tableBytes) else { return }
        let table = try await reader.read(offset: box.payloadOffset + 8, length: tableBytes)
        accStscEntries.reserveCapacity(entryCount)
        for i in 0..<entryCount {
            accStscEntries.append((
                firstChunk:      Int(table.mp4UInt32BE(at: i * 12)),
                samplesPerChunk: Int(table.mp4UInt32BE(at: i * 12 + 4))
                // sample_description_index at i*12+8 — not needed
            ))
        }
    }

    // MARK: - stsz (Sample Size)
    //
    // Either a fixed size for all samples, or one entry per sample.

    private func parseStsz(_ box: MP4Box) async throws {
        guard box.payloadSize >= 12 else { return }
        let hdr        = try await reader.read(offset: box.payloadOffset, length: 12)
        let fixedSize  = Int(hdr.mp4UInt32BE(at: 4))
        let sampleCnt  = Int(hdr.mp4UInt32BE(at: 8))
        accSampleCount = sampleCnt
        if fixedSize > 0 {
            accFixedSampleSize = fixedSize
        } else {
            let tableBytes = sampleCnt * 4
            guard box.payloadSize >= 12 + Int64(tableBytes) else { return }
            let table = try await reader.read(offset: box.payloadOffset + 12, length: tableBytes)
            accSampleSizes.reserveCapacity(sampleCnt)
            for i in 0..<sampleCnt {
                accSampleSizes.append(Int(table.mp4UInt32BE(at: i * 4)))
            }
        }
    }

    // MARK: - stco (32-bit Chunk Offsets)

    private func parseStco(_ box: MP4Box) async throws {
        guard box.payloadSize >= 8 else { return }
        let hdr        = try await reader.read(offset: box.payloadOffset, length: 8)
        let entryCount = Int(hdr.mp4UInt32BE(at: 4))
        guard entryCount > 0 else { return }
        let tableBytes = entryCount * 4
        guard box.payloadSize >= 8 + Int64(tableBytes) else { return }
        let table = try await reader.read(offset: box.payloadOffset + 8, length: tableBytes)
        accChunkOffsets.reserveCapacity(entryCount)
        for i in 0..<entryCount {
            accChunkOffsets.append(Int64(table.mp4UInt32BE(at: i * 4)))
        }
    }

    // MARK: - co64 (64-bit Chunk Offsets)

    private func parseCo64(_ box: MP4Box) async throws {
        guard box.payloadSize >= 8 else { return }
        let hdr        = try await reader.read(offset: box.payloadOffset, length: 8)
        let entryCount = Int(hdr.mp4UInt32BE(at: 4))
        guard entryCount > 0 else { return }
        let tableBytes = entryCount * 8
        guard box.payloadSize >= 8 + Int64(tableBytes) else { return }
        let table = try await reader.read(offset: box.payloadOffset + 8, length: tableBytes)
        accChunkOffsets.reserveCapacity(entryCount)
        for i in 0..<entryCount {
            accChunkOffsets.append(Int64(bitPattern: table.mp4UInt64BE(at: i * 8)))
        }
    }

    // MARK: - Track Finalization

    private func resetAccumulator() {
        accTrackID = 0;  accHandlerType = "";  accTimescale = 0
        accDurationTicks = 0;  accSampleCount = 0
        accCodecFourCC = nil;  accDisplayWidth = nil;  accDisplayHeight = nil
        accAvcCData = nil
        accHvcCData = nil
        accEsdsData = nil;  accChannelCount = nil;  accAudioSampleRate = nil
        accSttsEntries = [];  accCttsEntries = [];  accStssSet = []
        accStscEntries = [];  accSampleSizes = [];  accFixedSampleSize = 0
        accChunkOffsets = [];  accHasCtts = false;  accHasStss = false
    }

    private func finalizeTrack() {
        let trackType: TrackInfo.TrackType
        switch accHandlerType {
        case "vide": trackType = .video
        case "soun": trackType = .audio
        default:     trackType = .other(accHandlerType)
        }

        // Resolve sample count: prefer stsz count, fall back to stts sum
        let sttsTotal = accSttsEntries.reduce(0) { $0 + $1.count }
        let resolvedCount: Int
        if accSampleCount > 0 {
            resolvedCount = accSampleCount
        } else if !accSampleSizes.isEmpty {
            resolvedCount = accSampleSizes.count
        } else {
            resolvedCount = sttsTotal
        }

        let info = TrackInfo(
            trackID:        accTrackID,
            trackType:      trackType,
            timescale:      accTimescale,
            durationTicks:  accDurationTicks,
            sampleCount:    resolvedCount,
            codecFourCC:    accCodecFourCC,
            displayWidth:   accDisplayWidth,
            displayHeight:  accDisplayHeight,
            avcCData:       accAvcCData,
            hvcCData:       accHvcCData,      // Sprint 12
            esdsData:       accEsdsData,      // Sprint 13
            channelCount:   accChannelCount,
            audioSampleRate: accAudioSampleRate
        )
        tracks.append(info)

        // Snapshot sample tables for the video track
        if case .video = trackType {
            vtSttsEntries     = accSttsEntries
            vtCttsEntries     = accCttsEntries
            vtStssSet         = accStssSet
            vtStscEntries     = accStscEntries
            vtSampleSizes     = accSampleSizes
            vtFixedSampleSize = accFixedSampleSize
            vtChunkOffsets    = accChunkOffsets
            vtHasCtts         = accHasCtts
            vtHasStss         = accHasStss
            vtTimescale       = accTimescale
        }

        // Sprint 13: snapshot sample tables for the audio track
        if case .audio = trackType {
            atSttsEntries     = accSttsEntries
            atStscEntries     = accStscEntries
            atSampleSizes     = accSampleSizes
            atFixedSampleSize = accFixedSampleSize
            atChunkOffsets    = accChunkOffsets
            atTimescale       = accTimescale
            atSampleCount     = resolvedCount
        }
    }

    // MARK: - Packet Extraction (Sprint 8 + Sprint 15 perf)
    //
    // Samples are extracted in contiguous batches to minimise reader.read() calls.
    // For interleaved MP4 (1 video sample / chunk) consecutive video samples are
    // separated by audio chunks, so they are not contiguous — each is a separate
    // read.  For non-interleaved / streaming MP4 they often ARE contiguous and
    // collapse into a single read per run.  Audio chunks typically contain many
    // samples that are always contiguous within the chunk — big win there.

    /// Read the first `count` video packets from the parsed MP4.
    /// Each packet contains the raw AVCC-format H.264/HEVC sample bytes.
    func extractPackets(count: Int) async throws -> [DemuxPacket] {
        guard let vt = videoTrack else {
            throw MP4DemuxError.videoTrackNotFound
        }
        guard !vtChunkOffsets.isEmpty else {
            throw MP4DemuxError.incompleteStbl("stco/co64 missing")
        }
        guard !vtStscEntries.isEmpty else {
            throw MP4DemuxError.incompleteStbl("stsc missing")
        }
        guard !vtSttsEntries.isEmpty else {
            throw MP4DemuxError.incompleteStbl("stts missing")
        }

        let total = min(count, vt.sampleCount)
        let ts    = Int32(vtTimescale > 0 ? vtTimescale : 1)

        // 1. Pre-compute all (offset, size) without IO — pure table math.
        struct SampleLoc { let idx: Int; let fileOff: Int64; let size: Int }
        var locs = [SampleLoc]()
        locs.reserveCapacity(total)
        for i in 0..<total {
            let (off, sz) = try sampleLocation(index: i)
            locs.append(SampleLoc(idx: i, fileOff: off, size: sz))
        }

        // 2. Group into contiguous runs → one read() per run.
        var packets = [DemuxPacket]()
        packets.reserveCapacity(total)
        var runStart = 0
        while runStart < locs.count {
            var runEnd = runStart + 1
            while runEnd < locs.count {
                let prev = locs[runEnd - 1], curr = locs[runEnd]
                if curr.fileOff == prev.fileOff + Int64(prev.size) { runEnd += 1 }
                else { break }
            }
            // Read the whole contiguous run at once.
            let runFileOff  = locs[runStart].fileOff
            let runByteLen  = locs[runEnd - 1].fileOff + Int64(locs[runEnd - 1].size) - runFileOff
            let chunkData   = try await reader.read(offset: runFileOff, length: Int(runByteLen))

            for j in runStart..<runEnd {
                let loc       = locs[j]
                let sliceOff  = Int(loc.fileOff - runFileOff)
                let data      = chunkData.subdata(in: sliceOff ..< sliceOff + loc.size)
                let dtsTicks  = self.dtsTicks(forSample: loc.idx)
                let ptsTicks  = dtsTicks + Int64(cttsOffset(forSample: loc.idx))
                let isKey     = vtHasStss ? vtStssSet.contains(loc.idx + 1) : true
                packets.append(DemuxPacket(
                    streamType: .video,
                    index:      loc.idx,
                    pts:        CMTime(value: ptsTicks, timescale: ts),
                    dts:        CMTime(value: dtsTicks, timescale: ts),
                    data:       data,
                    isKeyframe: isKey,
                    byteOffset: loc.fileOff,
                    duration:   .invalid
                ))
            }
            runStart = runEnd
        }
        return packets
    }

    // MARK: - Sample Location
    //
    // To find the file byte offset of sample N (0-based):
    //   1. Walk stsc entries to find which chunk the sample lives in.
    //   2. Get that chunk's file offset from stco.
    //   3. Sum the sizes of samples preceding it within the same chunk (from stsz).

    private func sampleLocation(index: Int) throws -> (offset: Int64, size: Int) {
        var globalSample = 0

        for i in 0..<vtStscEntries.count {
            let entry         = vtStscEntries[i]
            let firstChunk1   = entry.firstChunk           // 1-based
            let spc           = entry.samplesPerChunk
            let nextFirstChunk = (i + 1 < vtStscEntries.count)
                ? vtStscEntries[i + 1].firstChunk          // 1-based next run
                : vtChunkOffsets.count + 1                 // one past the last chunk

            let numChunks   = nextFirstChunk - firstChunk1
            let samplesInRun = numChunks * spc

            if globalSample + samplesInRun > index {
                // This run contains our sample
                let offsetInRun      = index - globalSample
                let chunkOffsetInRun = offsetInRun / spc     // 0-based within this run
                let sampleInChunk    = offsetInRun % spc     // 0-based within that chunk

                let chunkIdx0 = (firstChunk1 - 1) + chunkOffsetInRun  // 0-based absolute
                guard chunkIdx0 < vtChunkOffsets.count else {
                    throw MP4DemuxError.chunkIndexOutOfBounds(chunkIdx0)
                }

                // Start at chunk base, add sizes of preceding samples in the chunk
                var fileOff           = vtChunkOffsets[chunkIdx0]
                let firstSampleInChunk = globalSample + chunkOffsetInRun * spc
                for s in firstSampleInChunk..<(firstSampleInChunk + sampleInChunk) {
                    fileOff += Int64(sampleSizeAt(s))
                }

                return (fileOff, sampleSizeAt(index))
            }
            globalSample += samplesInRun
        }
        throw MP4DemuxError.sampleNotFound(index)
    }

    private func sampleSizeAt(_ index: Int) -> Int {
        if vtFixedSampleSize > 0 { return vtFixedSampleSize }
        return index < vtSampleSizes.count ? vtSampleSizes[index] : 0
    }

    // MARK: - Timestamp Helpers

    /// Decode timestamp (ticks) for sample at `index`, derived from stts.
    private func dtsTicks(forSample index: Int) -> Int64 {
        var ticks     = Int64(0)
        var remaining = index
        for entry in vtSttsEntries {
            if remaining < entry.count {
                ticks += Int64(remaining) * Int64(entry.delta)
                return ticks
            }
            ticks     += Int64(entry.count) * Int64(entry.delta)
            remaining -= entry.count
        }
        return ticks
    }

    /// Composition time offset for sample at `index`, derived from ctts.
    /// PTS = DTS + this value.
    private func cttsOffset(forSample index: Int) -> Int32 {
        guard vtHasCtts else { return 0 }
        var remaining = index
        for entry in vtCttsEntries {
            if remaining < entry.count { return entry.offset }
            remaining -= entry.count
        }
        return 0
    }

    // MARK: - Audio Packet Extraction (Sprint 13 + Sprint 15 perf)
    //
    // Uses contiguous-batch reading just like extractPackets().
    // For a typical MP4, all audio samples in a chunk are physically adjacent,
    // so the whole audio track often collapses into a handful of reads.

    /// Extract up to `count` audio packets starting from sample index `startIndex`.
    func extractAudioPackets(count: Int, from startIndex: Int = 0) async throws -> [DemuxPacket] {
        guard audioTrack != nil else { throw MP4DemuxError.videoTrackNotFound }
        guard !atChunkOffsets.isEmpty else { throw MP4DemuxError.incompleteStbl("audio stco/co64 missing") }
        guard !atStscEntries.isEmpty  else { throw MP4DemuxError.incompleteStbl("audio stsc missing") }
        guard !atSttsEntries.isEmpty  else { throw MP4DemuxError.incompleteStbl("audio stts missing") }

        let total = min(startIndex + count, atSampleCount)
        let ts    = Int32(atTimescale > 0 ? atTimescale : 1)

        // 1. Pre-compute all (offset, size) without IO.
        struct SampleLoc { let idx: Int; let fileOff: Int64; let size: Int }
        var locs = [SampleLoc]()
        locs.reserveCapacity(max(0, total - startIndex))
        for i in startIndex..<total {
            let (off, sz) = try audioSampleLocation(index: i)
            locs.append(SampleLoc(idx: i, fileOff: off, size: sz))
        }

        // 2. Group into contiguous runs → one read() per run.
        var packets = [DemuxPacket]()
        packets.reserveCapacity(locs.count)
        var runStart = 0
        while runStart < locs.count {
            var runEnd = runStart + 1
            while runEnd < locs.count {
                let prev = locs[runEnd - 1], curr = locs[runEnd]
                if curr.fileOff == prev.fileOff + Int64(prev.size) { runEnd += 1 }
                else { break }
            }
            let runFileOff  = locs[runStart].fileOff
            let runByteLen  = locs[runEnd - 1].fileOff + Int64(locs[runEnd - 1].size) - runFileOff
            let chunkData   = try await reader.read(offset: runFileOff, length: Int(runByteLen))

            for j in runStart..<runEnd {
                let loc          = locs[j]
                let sliceOff     = Int(loc.fileOff - runFileOff)
                let data         = chunkData.subdata(in: sliceOff ..< sliceOff + loc.size)
                let dtsTicks     = self.audioDtsTicks(forSample: loc.idx)
                let frameDuration = audioFrameDuration(forSample: loc.idx)
                packets.append(DemuxPacket(
                    streamType: .audio,
                    index:      loc.idx,
                    pts:        CMTime(value: dtsTicks,     timescale: ts),
                    dts:        CMTime(value: dtsTicks,     timescale: ts),
                    data:       data,
                    isKeyframe: true,
                    byteOffset: loc.fileOff,
                    duration:   CMTime(value: frameDuration, timescale: ts)
                ))
            }
            runStart = runEnd
        }
        return packets
    }

    // MARK: - Seek Support (Sprint 14)

    /// Extract video packets starting from `startIndex` using contiguous-batch reads.
    func extractVideoPackets(from startIndex: Int, count: Int) async throws -> [DemuxPacket] {
        guard let vt = videoTrack else { throw MP4DemuxError.videoTrackNotFound }
        guard !vtChunkOffsets.isEmpty else { throw MP4DemuxError.incompleteStbl("stco/co64 missing") }
        guard !vtStscEntries.isEmpty  else { throw MP4DemuxError.incompleteStbl("stsc missing") }
        guard !vtSttsEntries.isEmpty  else { throw MP4DemuxError.incompleteStbl("stts missing") }

        let total = min(startIndex + count, vt.sampleCount)
        let ts    = Int32(vtTimescale > 0 ? vtTimescale : 1)

        struct SampleLoc { let idx: Int; let fileOff: Int64; let size: Int }
        var locs = [SampleLoc]()
        locs.reserveCapacity(max(0, total - startIndex))
        for i in startIndex..<total {
            let (off, sz) = try sampleLocation(index: i)
            locs.append(SampleLoc(idx: i, fileOff: off, size: sz))
        }

        var packets = [DemuxPacket]()
        packets.reserveCapacity(locs.count)
        var runStart = 0
        while runStart < locs.count {
            var runEnd = runStart + 1
            while runEnd < locs.count {
                let prev = locs[runEnd - 1], curr = locs[runEnd]
                if curr.fileOff == prev.fileOff + Int64(prev.size) { runEnd += 1 }
                else { break }
            }
            let runFileOff = locs[runStart].fileOff
            let runByteLen = locs[runEnd - 1].fileOff + Int64(locs[runEnd - 1].size) - runFileOff
            let chunkData  = try await reader.read(offset: runFileOff, length: Int(runByteLen))

            for j in runStart..<runEnd {
                let loc      = locs[j]
                let sliceOff = Int(loc.fileOff - runFileOff)
                let data     = chunkData.subdata(in: sliceOff ..< sliceOff + loc.size)
                let dtsTicks = self.dtsTicks(forSample: loc.idx)
                let ptsTicks = dtsTicks + Int64(cttsOffset(forSample: loc.idx))
                let isKey    = vtHasStss ? vtStssSet.contains(loc.idx + 1) : true
                packets.append(DemuxPacket(
                    streamType: .video,
                    index:      loc.idx,
                    pts:        CMTime(value: ptsTicks, timescale: ts),
                    dts:        CMTime(value: dtsTicks, timescale: ts),
                    data:       data,
                    isKeyframe: isKey,
                    byteOffset: loc.fileOff,
                    duration:   .invalid
                ))
            }
            runStart = runEnd
        }
        return packets
    }

    /// Return the 0-based index of the video keyframe whose PTS is closest to
    /// (but not after) `target`.  Returns 0 when the target is before all keyframes
    /// or when there is no stss (all frames are keyframes).
    func findVideoKeyframeSampleIndex(nearestBeforePTS target: CMTime) -> Int {
        guard vtTimescale > 0 else { return 0 }

        // Convert target to ticks in the video timescale
        let targetTicks = Int64(target.seconds * Double(vtTimescale))

        // Walk stts to find the last sample whose PTS ≤ targetTicks
        var sampleIdx = 0
        var accTicks  = Int64(0)
        outer: for entry in vtSttsEntries {
            for _ in 0..<entry.count {
                let ptsTicks = accTicks + Int64(cttsOffset(forSample: sampleIdx))
                if ptsTicks > targetTicks { break outer }
                sampleIdx += 1
                accTicks  += Int64(entry.delta)
            }
        }
        // sampleIdx is now just past the target — step back one
        if sampleIdx > 0 { sampleIdx -= 1 }

        // If no stss, every frame is a keyframe
        guard vtHasStss else { return sampleIdx }

        // Scan sorted keyframe list for the last one at or before sampleIdx
        var keyframeIdx = 0
        for kf1 in vtStssSet.sorted() {
            let kfIdx = kf1 - 1   // 0-based
            if kfIdx <= sampleIdx { keyframeIdx = kfIdx } else { break }
        }
        return keyframeIdx
    }

    /// Presentation timestamp of video sample at `index`.
    /// Used by the streaming controller to re-anchor the synchronizer after a seek.
    func videoPTS(forSample index: Int) -> CMTime {
        guard vtTimescale > 0 else { return .zero }
        let ts     = Int32(vtTimescale)
        let dtsTk  = dtsTicks(forSample: index)
        let ptsTk  = dtsTk + Int64(cttsOffset(forSample: index))
        return CMTime(value: ptsTk, timescale: ts)
    }

    /// Return the 0-based audio sample index whose DTS is closest to (but not after)
    /// `target`.  Safe to call with .zero (returns 0).
    func findAudioSampleIndex(nearestBeforePTS target: CMTime) -> Int {
        guard atTimescale > 0 else { return 0 }
        let targetTicks = Int64(target.seconds * Double(atTimescale))
        var sampleIdx = 0
        var accTicks  = Int64(0)
        for entry in atSttsEntries {
            for _ in 0..<entry.count {
                if accTicks > targetTicks { return max(0, sampleIdx - 1) }
                sampleIdx += 1
                accTicks  += Int64(entry.delta)
            }
        }
        return max(0, sampleIdx - 1)
    }

    // MARK: - Audio Location Helpers

    private func audioSampleLocation(index: Int) throws -> (offset: Int64, size: Int) {
        var globalSample = 0
        for i in 0..<atStscEntries.count {
            let entry          = atStscEntries[i]
            let firstChunk1    = entry.firstChunk
            let spc            = entry.samplesPerChunk
            let nextFirstChunk = (i + 1 < atStscEntries.count)
                ? atStscEntries[i + 1].firstChunk
                : atChunkOffsets.count + 1

            let numChunks    = nextFirstChunk - firstChunk1
            let samplesInRun = numChunks * spc

            if globalSample + samplesInRun > index {
                let offsetInRun      = index - globalSample
                let chunkOffsetInRun = offsetInRun / spc
                let sampleInChunk    = offsetInRun % spc

                let chunkIdx0 = (firstChunk1 - 1) + chunkOffsetInRun
                guard chunkIdx0 < atChunkOffsets.count else {
                    throw MP4DemuxError.chunkIndexOutOfBounds(chunkIdx0)
                }
                var fileOff = atChunkOffsets[chunkIdx0]
                let firstSampleInChunk = globalSample + chunkOffsetInRun * spc
                for s in firstSampleInChunk..<(firstSampleInChunk + sampleInChunk) {
                    fileOff += Int64(audioSampleSizeAt(s))
                }
                return (fileOff, audioSampleSizeAt(index))
            }
            globalSample += samplesInRun
        }
        throw MP4DemuxError.sampleNotFound(index)
    }

    private func audioSampleSizeAt(_ index: Int) -> Int {
        if atFixedSampleSize > 0 { return atFixedSampleSize }
        return index < atSampleSizes.count ? atSampleSizes[index] : 0
    }

    private func audioDtsTicks(forSample index: Int) -> Int64 {
        var ticks     = Int64(0)
        var remaining = index
        for entry in atSttsEntries {
            if remaining < entry.count {
                ticks += Int64(remaining) * Int64(entry.delta)
                return ticks
            }
            ticks     += Int64(entry.count) * Int64(entry.delta)
            remaining -= entry.count
        }
        return ticks
    }

    /// Duration (in ticks) of the audio frame at `index`, from the stts table.
    private func audioFrameDuration(forSample index: Int) -> Int64 {
        var remaining = index
        for entry in atSttsEntries {
            if remaining < entry.count { return Int64(entry.delta) }
            remaining -= entry.count
        }
        return atSttsEntries.last.map { Int64($0.delta) } ?? 1024
    }
}
