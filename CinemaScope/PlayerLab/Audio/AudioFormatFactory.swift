// MARK: - PlayerLab / Audio / AudioFormatFactory
// Spring Cleaning SC1 — Centralized audio format-description construction.
// Extracted from PlayerLabPlaybackController (Sprints 13, 22, 24).
// Sprint 33 — DTS-Core passthrough path added.
// Sprint 36 — AudioTrackPlaybackMode parameter; effectiveFourCC dispatch.
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
        var asbd = AudioStreamBasicDescription(
            mSampleRate:       sampleRate,
            mFormatID:         kAudioFormatMPEG4AAC,
            mFormatFlags:      0,
            mBytesPerPacket:   0,
            mFramesPerPacket:  1024,
            mBytesPerFrame:    0,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel:   0,
            mReserved:         0
        )
        var desc: CMAudioFormatDescription?
        let status = asc.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
            CMAudioFormatDescriptionCreate(
                allocator:            kCFAllocatorDefault,
                asbd:                 &asbd,
                layoutSize:           0,
                layout:               nil,
                magicCookieSize:      asc.count,
                magicCookie:          ptr.baseAddress!,
                extensions:           nil,
                formatDescriptionOut: &desc
            )
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
