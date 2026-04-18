// MARK: - PlayerLab / Audio / AudioFormatFactory
// Spring Cleaning SC1 — Centralized audio format-description construction.
// Extracted from PlayerLabPlaybackController (Sprints 13, 22, 24).
//
// Handles:
//   • MP4 AAC   (esds payload → parseAudioSpecificConfig → magic cookie)
//   • MKV AAC   (CodecPrivate IS the raw AudioSpecificConfig — no parsing needed)
//   • AC3 / EAC3 (self-framing; no magic cookie required)
//
// Dispatch logic (inside `make(for:codecPrivate:record:)`):
//   isAAC  + esdsData present   → MP4 path: strip esds wrapper, use ASC as magic cookie
//   isAAC  + esdsData nil       → MKV path: codecPrivate IS the raw AudioSpecificConfig
//   "ac-3"                      → AC3 (kAudioFormatAC3, 1536 frames/packet)
//   "ec-3"                      → E-AC3 (kAudioFormatEnhancedAC3, 1536 frames/packet)
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
    ///   - codecPrivate: MKV CodecPrivate bytes (nil for MP4 tracks).
    ///   - record:       Logging callback forwarded from the controller.
    static func make(
        for audioTrack: TrackInfo,
        codecPrivate:   Data?,
        record:         (String) -> Void
    ) -> CMAudioFormatDescription? {

        guard let ch = audioTrack.channelCount,
              let sr = audioTrack.audioSampleRate else {
            record("  ⚠️ AudioFormatFactory: missing channelCount or sampleRate")
            return nil
        }

        let codecLabel = audioTrack.codecFourCC ?? "?"
        record("[4b] Building CMAudioFormatDescription (\(codecLabel))…")

        // ── AAC ────────────────────────────────────────────────────────────────
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
        if audioTrack.codecFourCC == "ac-3" {
            return makeAC3(channelCount: ch, sampleRate: sr, isEAC3: false, record: record)
        }
        if audioTrack.codecFourCC == "ec-3" {
            return makeAC3(channelCount: ch, sampleRate: sr, isEAC3: true, record: record)
        }

        record("  ⚠️ AudioFormatFactory: unsupported codec '\(codecLabel)'")
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
