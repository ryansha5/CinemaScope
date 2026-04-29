// MARK: - PlayerLab / Audio / AudioFormatFactory
// Spring Cleaning SC1 — Centralized audio format-description construction.
// Extracted from PlayerLabPlaybackController (Sprints 13, 22, 24).
// Sprint 33 — DTS-Core passthrough path added.
// Sprint 36 — AudioTrackPlaybackMode parameter; effectiveFourCC dispatch.
// Sprint 54 — ascChannelCount() added; makeMPEG4AAC now derives channel count
//             from the ASC rather than the MKV track header.  Track-header ch
//             can disagree with ASC channelConfiguration (e.g. header says 6,
//             ASC says 2) — the mismatch caused ACMP4AACBaseDecoder err = -1
//             on every packet.  ASC is now authoritative.
//
// Handles:
//   • MP4 AAC   (esds payload → parseAudioSpecificConfig → magic cookie)
//   • MKV AAC   (CodecPrivate IS the raw AudioSpecificConfig — no parsing needed)
//   • AC3 / EAC3 (self-framing; no magic cookie required)
//   • DTS-Core  (Sprint 33: "dtsc" → kAudioFormatDTS; self-framing; hardware passthrough)
//   • TrueHD / extracted AC3 core (Sprint 36: playbackMode = .extractedCore → AC3 path)
//
// Dispatch logic (inside `make(for:playbackMode:codecPrivate:record:)`):
//   Sprint 36: effectiveFourCC = playbackMode.effectiveCodecFourCC ?? audioTrack.codecFourCC
//   isAAC  + esdsData present   → MP4 path: strip esds wrapper, use ASC as magic cookie
//   isAAC  + esdsData nil       → MKV path: codecPrivate IS the raw AudioSpecificConfig
//   effectiveFourCC "ac-3"      → AC3 (kAudioFormatAC3, 1536 frames/packet)
//   effectiveFourCC "ec-3"      → E-AC3 (kAudioFormatEnhancedAC3, 1536 frames/packet)
//   effectiveFourCC "dtsc"      → DTS-Core (kAudioFormatDTS, 512 frames/packet)
//                                  ⚠️ Requires DTS-capable hardware or HDMI passthrough.
//                                     Yields silence on devices without DTS support.
//
// NOT production-ready. Debug / lab use only.

import Foundation
import AudioToolbox
import CoreMedia

enum AudioFormatFactory {

    // MARK: - Unified entry point

    /// Returns a `CMAudioFormatDescription` for `audioTrack`, or `nil` on failure.
    ///
    /// The `record` closure is called with status messages (prefixed as `[4b]`).
    /// Pass `controller.record` directly; no actor-isolation issue arises because
    /// this function is synchronous and is always called from `@MainActor` prepare().
    ///
    /// - Parameters:
    ///   - audioTrack:   TrackInfo for the selected audio track.
    ///   - playbackMode: How the track is being decoded.  Default = `.native`.
    ///                   Pass `.extractedCore` when the outer codec differs from the
    ///                   actual decode format (e.g. TrueHD carrying AC3 core).
    ///   - codecPrivate: MKV CodecPrivate bytes (nil for MP4 tracks).
    ///   - record:       Logging callback forwarded from the controller.
    static func make(
        for audioTrack: TrackInfo,
        playbackMode:   AudioTrackPlaybackMode = .native,
        codecPrivate:   Data?,
        record:         (String) -> Void
    ) -> CMAudioFormatDescription? {

        guard let ch = audioTrack.channelCount,
              let sr = audioTrack.audioSampleRate else {
            record("  ⚠️ AudioFormatFactory: missing channelCount or sampleRate")
            return nil
        }

        // Sprint 36: derive the effective codec for dispatch.
        // For .native, this is the track's own codecFourCC.
        // For .extractedCore (e.g. TrueHD → AC3), this is the extracted codec.
        let effectiveFourCC = playbackMode.effectiveCodecFourCC ?? audioTrack.codecFourCC

        // Log accurately: include extraction context when relevant.
        switch playbackMode {
        case .native:
            record("[4b] Building CMAudioFormatDescription (\(effectiveFourCC ?? "?"))…")
        case .extractedCore:
            record("[4b] Building CMAudioFormatDescription (\(playbackMode.displayLabel))…")
        }

        // ── AAC ────────────────────────────────────────────────────────────────
        // isAAC checks codecFourCC ("mp4a" / "A_AAC/..."); unaffected by playbackMode.
        if audioTrack.isAAC {
            // MP4 path: esdsData wraps the AudioSpecificConfig inside a descriptor tree.
            if let esds = audioTrack.esdsData {
                guard let asc = parseAudioSpecificConfig(from: esds) else {
                    record("  ⚠️ Failed to parse AudioSpecificConfig from esds")
                    return nil
                }
                return makeMPEG4AAC(asc: asc, channelCount: ch, sampleRate: sr, record: record)
            }
            // MKV path: CodecPrivate IS the raw AudioSpecificConfig bytes.
            if let asc = codecPrivate, !asc.isEmpty {
                return makeMPEG4AAC(asc: asc, channelCount: ch, sampleRate: sr, record: record)
            }
            record("  ⚠️ AAC track has neither esdsData nor codecPrivate — cannot build format description")
            return nil
        }

        // ── AC3 / E-AC3 ───────────────────────────────────────────────────────
        // Sprint 36: dispatch on effectiveFourCC so extracted AC3 from TrueHD
        // reaches this path even though audioTrack.codecFourCC is "A_TRUEHD".
        if effectiveFourCC == "ac-3" {
            return makeAC3(channelCount: ch, sampleRate: sr, isEAC3: false, record: record)
        }
        if effectiveFourCC == "ec-3" {
            return makeAC3(channelCount: ch, sampleRate: sr, isEAC3: true, record: record)
        }

        // ── DTS-Core (Sprint 33) ──────────────────────────────────────────────
        if effectiveFourCC == "dtsc" {
            return makeDTSCore(channelCount: ch, sampleRate: sr, record: record)
        }

        record("  ⚠️ AudioFormatFactory: unsupported codec '\(effectiveFourCC ?? "?")'")
        return nil
    }

    // MARK: - MPEG-4 AAC (shared by MP4 and MKV paths)
    //
    // Both paths end up with a raw AudioSpecificConfig byte buffer.
    // The only difference is how that buffer is obtained (esds parse vs direct).

    private static func makeMPEG4AAC(
        asc:          Data,
        channelCount: UInt16,
        sampleRate:   Double,
        record:       (String) -> Void
    ) -> CMAudioFormatDescription? {

        // Sprint 54 fix: the ASBD channel count MUST match the AudioSpecificConfig.
        //
        // For MKV AAC, `channelCount` comes from the MKV TrackEntry Audio/Channels
        // element, which may disagree with the channelConfiguration field embedded
        // in the ASC.  The decoder is authoritative: it decodes exactly the channels
        // the ASC describes.  If the ASBD claims more channels than the ASC,
        // ACMP4AACBaseDecoder fails every packet with err = -1 because it cannot
        // produce the declared channel count from the bitstream.
        //
        // Example: ASC = 0x11 0x90 → AAC-LC 48 kHz channelConfig=2 (stereo),
        // but MKV header claimed ch=6.  Using ch=6 in the ASBD caused 100% decode
        // failures.  Using the ASC-derived channel count (2) fixes them.
        // Diagnostic: log raw ASC bytes so we can verify what the decoder is actually seeing.
        let ascHex = asc.map { String(format: "%02X", $0) }.joined(separator: " ")
        record("  [ASC-debug] count=\(asc.count) startIndex=\(asc.startIndex) bytes=[\(ascHex)]")

        let ascCh   = ascChannelCount(from: asc)
        record("  [ASC-debug] ascChannelCount=\(ascCh.map { "\($0)" } ?? "nil")  trackHeader ch=\(channelCount)")

        let effCh: UInt16
        if let a = ascCh, a > 0 {
            if a != channelCount {
                record("  ⚠️ [AAC] ASC channelConfig=\(a) overrides track header ch=\(channelCount) — using ASC value")
            }
            effCh = a
        } else {
            effCh = channelCount   // ASC parse failed; fall back to track header
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate:       sampleRate,
            mFormatID:         kAudioFormatMPEG4AAC,
            mFormatFlags:      0,
            mBytesPerPacket:   0,
            mFramesPerPacket:  1024,
            mBytesPerFrame:    0,
            mChannelsPerFrame: UInt32(effCh),
            mBitsPerChannel:   0,
            mReserved:         0
        )

        // Provide an explicit AudioChannelLayout so that AVAudioFormat(cmAudioFormatDescription:)
        // returns a fully-initialised object.  Without a layout the format description is
        // technically valid for CoreMedia but leaves AVAudioFormat with a nil/dangling internal
        // layout pointer — which causes AVAudioConverter(from:to:) to crash with EXC_BAD_ACCESS.
        let layoutTag: AudioChannelLayoutTag
        switch effCh {
        case 1:  layoutTag = kAudioChannelLayoutTag_Mono
        case 2:  layoutTag = kAudioChannelLayoutTag_Stereo
        case 3:  layoutTag = kAudioChannelLayoutTag_MPEG_3_0_A
        case 4:  layoutTag = kAudioChannelLayoutTag_MPEG_4_0_A
        case 5:  layoutTag = kAudioChannelLayoutTag_MPEG_5_0_A
        case 6:  layoutTag = kAudioChannelLayoutTag_MPEG_5_1_A  // L R C LFE Ls Rs
        case 7:  layoutTag = kAudioChannelLayoutTag_MPEG_6_1_A
        case 8:  layoutTag = kAudioChannelLayoutTag_MPEG_7_1_A
        default: layoutTag = kAudioChannelLayoutTag_DiscreteInOrder
                           | AudioChannelLayoutTag(effCh)
        }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag         = layoutTag
        layout.mChannelBitmap            = AudioChannelBitmap(rawValue: 0)
        layout.mNumberChannelDescriptions = 0
        let layoutSize = MemoryLayout<AudioChannelLayout>.size

        var desc: CMAudioFormatDescription?
        let status = asc.withUnsafeBytes { (ascPtr: UnsafeRawBufferPointer) -> OSStatus in
            withUnsafePointer(to: layout) { layoutPtr in
                CMAudioFormatDescriptionCreate(
                    allocator:            kCFAllocatorDefault,
                    asbd:                 &asbd,
                    layoutSize:           layoutSize,
                    layout:               layoutPtr,
                    magicCookieSize:      asc.count,
                    magicCookie:          ascPtr.baseAddress!,
                    extensions:           nil,
                    formatDescriptionOut: &desc
                )
            }
        }
        if status != noErr {
            record("  ⚠️ CMAudioFormatDescriptionCreate (AAC) failed: \(status)")
            return nil
        }
        return desc
    }

    // MARK: - AC3 / E-AC3
    //
    // AC3 and EAC3 are self-framing — each DemuxPacket is a complete sync frame.
    // No magic cookie needed; the decoder initialises from the stream header.
    // Standard frame size for both is 1536 PCM samples.

    private static func makeAC3(
        channelCount: UInt16,
        sampleRate:   Double,
        isEAC3:       Bool,
        record:       (String) -> Void
    ) -> CMAudioFormatDescription? {
        let formatID: AudioFormatID = isEAC3 ? kAudioFormatEnhancedAC3 : kAudioFormatAC3
        let label = isEAC3 ? "E-AC3" : "AC3"
        var asbd = AudioStreamBasicDescription(
            mSampleRate:       sampleRate > 0 ? sampleRate : 48_000,
            mFormatID:         formatID,
            mFormatFlags:      0,
            mBytesPerPacket:   0,
            mFramesPerPacket:  1536,
            mBytesPerFrame:    0,
            mChannelsPerFrame: UInt32(channelCount > 0 ? channelCount : 6),
            mBitsPerChannel:   0,
            mReserved:         0
        )
        var desc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator:            kCFAllocatorDefault,
            asbd:                 &asbd,
            layoutSize:           0,
            layout:               nil,
            magicCookieSize:      0,
            magicCookie:          nil,
            extensions:           nil,
            formatDescriptionOut: &desc
        )
        if status != noErr {
            record("  ⚠️ CMAudioFormatDescriptionCreate (\(label)) failed: \(status)")
            return nil
        }
        return desc
    }

    // MARK: - DTS-Core (Sprint 33)
    //
    // kAudioFormatDTS ('dtsc') — standard DTS-Core passthrough.
    //
    // DTS-Core frames in MKV are self-contained sync frames; no magic cookie is
    // required.  Standard frame size is 512 PCM samples.  The system will attempt
    // hardware passthrough via AVAudioSession; on devices without a DTS-capable
    // output route the audio renderer will enqueue samples silently (no crash).
    //
    // Timing note: mFramesPerPacket is 512 as a safe default for DTS-Core CD-rate
    // content.  PTS is driven by the MKV block timestamp, not this field, so a
    // small mismatch does not affect A/V sync.

    private static func makeDTSCore(
        channelCount: UInt16,
        sampleRate:   Double,
        record:       (String) -> Void
    ) -> CMAudioFormatDescription? {
        record("[4b] Building CMAudioFormatDescription (DTS-Core)…")
        record("  ⚠️ DTS-Core: hardware passthrough only — may yield silence on this device")

        // kAudioFormatDTS ('dtsc' = 0x64747363) — not exported by the tvOS SDK headers;
        // use the raw FourCC directly. Value is stable across all Apple platforms.
        let kAudioFormatDTScore: AudioFormatID = 0x64747363
        var asbd = AudioStreamBasicDescription(
            mSampleRate:       sampleRate > 0 ? sampleRate : 48_000,
            mFormatID:         kAudioFormatDTScore,
            mFormatFlags:      0,
            mBytesPerPacket:   0,
            mFramesPerPacket:  512,
            mBytesPerFrame:    0,
            mChannelsPerFrame: UInt32(channelCount > 0 ? channelCount : 6),
            mBitsPerChannel:   0,
            mReserved:         0
        )
        var desc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator:            kCFAllocatorDefault,
            asbd:                 &asbd,
            layoutSize:           0,
            layout:               nil,
            magicCookieSize:      0,
            magicCookie:          nil,
            extensions:           nil,
            formatDescriptionOut: &desc
        )
        if status != noErr {
            record("  ⚠️ CMAudioFormatDescriptionCreate (DTS-Core) failed: \(status)")
            return nil
        }
        record("  ✅ DTS-Core format description  ch=\(channelCount) sr=\(Int(sampleRate)) Hz  "
             + "(attempting passthrough)")
        return desc
    }

    // MARK: - AudioSpecificConfig — channel count extractor
    //
    // Extracts the channelConfiguration field from an AudioSpecificConfig (ISO 14496-3).
    //
    // ASC bit layout (for audioObjectType ≤ 30 and samplingFrequencyIndex ≠ 0xF):
    //   bits  0– 4  audioObjectType        (5 bits)
    //   bits  5– 8  samplingFrequencyIndex (4 bits)
    //   bits  9–12  channelConfiguration   (4 bits)
    //
    // Returns nil if the ASC is too short, uses an extended audioObjectType (31),
    // or uses a literal sample-rate escape (sfi == 0xF) — in those cases the caller
    // falls back to the track-header channel count.
    //
    // channelConfiguration values:
    //   0 = program_config_element (complex; not handled here)
    //   1 = C           (mono)
    //   2 = L R         (stereo)
    //   3 = C L R       (3.0)
    //   4 = C L R S     (4.0)
    //   5 = C L R Ls Rs (5.0)
    //   6 = C L R Ls Rs LFE   (5.1)
    //   7 = C L R Ls Rs Lss Rss LFE (7.1)

    private static func ascChannelCount(from asc: Data) -> UInt16? {
        guard asc.count >= 2 else { return nil }
        // Use startIndex-relative access: asc may be a subdata() slice whose
        // startIndex is non-zero.  asc[0] would be out of bounds in that case.
        let b0 = Int(asc[asc.startIndex])
        let b1 = Int(asc[asc.startIndex + 1])

        // audioObjectType: b0[7..3]
        let aot = (b0 >> 3) & 0x1F
        guard aot != 31 else { return nil }   // extended AOT — skip

        // samplingFrequencyIndex: b0[2..0] ++ b1[7]
        let sfi = ((b0 & 0x07) << 1) | ((b1 >> 7) & 0x01)
        guard sfi != 0x0F else { return nil }  // 24-bit literal rate escape — skip

        // channelConfiguration: b1[6..3]
        let cc = (b1 >> 3) & 0x0F
        guard cc > 0 else { return nil }       // 0 = program_config_element — skip
        return UInt16(cc)
    }

    // MARK: - AudioSpecificConfig parser (MP4 esds payload)
    //
    // Walks the MPEG-4 ES_Descriptor tree inside an esds box payload to reach the
    // DecoderSpecificInfo (tag 0x05) whose payload is the AudioSpecificConfig.
    //
    // esds box layout (after 4-byte version+flags):
    //   0x03  ES_Descriptor          (+ length)
    //     [3 bytes ES_ID / flags]
    //     0x04  DecoderConfigDescriptor (+ length)
    //       [13 bytes decoder config header]
    //       0x05  DecoderSpecificInfo   (+ length)
    //         <AudioSpecificConfig bytes>

    private static func parseAudioSpecificConfig(from esds: Data) -> Data? {
        guard esds.count > 4 else { return nil }
        var idx = 4   // skip version (1 byte) + flags (3 bytes)

        func parseDescriptorLength() -> Int? {
            var length = 0
            for _ in 0..<4 {
                guard idx < esds.count else { return nil }
                let b = Int(esds[idx]); idx += 1
                length = (length << 7) | (b & 0x7F)
                if b & 0x80 == 0 { break }
            }
            return length
        }

        // 0x03 ES_Descriptor
        guard idx < esds.count, esds[idx] == 0x03 else { return nil }
        idx += 1
        guard parseDescriptorLength() != nil else { return nil }
        guard idx + 3 <= esds.count else { return nil }
        idx += 3    // skip ES_ID (2) + stream priority (1)

        // 0x04 DecoderConfigDescriptor
        guard idx < esds.count, esds[idx] == 0x04 else { return nil }
        idx += 1
        guard parseDescriptorLength() != nil else { return nil }
        guard idx + 13 <= esds.count else { return nil }
        idx += 13   // skip objectTypeIndication(1) + streamType/bufferSize(4) + bitrates(8)

        // 0x05 DecoderSpecificInfo (AudioSpecificConfig)
        guard idx < esds.count, esds[idx] == 0x05 else { return nil }
        idx += 1
        guard let ascLen = parseDescriptorLength() else { return nil }
        guard idx + ascLen <= esds.count else { return nil }

        return esds.subdata(in: idx..<(idx + ascLen))
    }
}
