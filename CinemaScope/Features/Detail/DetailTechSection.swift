import SwiftUI

// MARK: - DetailTechSection
//
// Technical specs block: video codec/resolution/HDR, container/size/bitrate,
// audio tracks, and subtitle tracks.
// Extracted from DetailView (PASS 3). No logic changes.

struct DetailTechSection: View {
    let source:    EmbyMediaSource
    let scopeMode: Bool
    let colorMode: ColorMode

    var body: some View {
        let video  = source.videoStream
        let audios = source.audioStreams
        let subs   = source.subtitleStreams

        let videoValues: [String] = video.map { v in [
            v.resolutionLabel,
            v.codec?.uppercased(),
            v.hdrLabel,
            v.bitDepth.map { "\($0)-bit" },
            v.frameRate.map { String(format: "%.3g fps", $0) },
            formatBitrate(v.bitrate),
        ].compactMap { $0 } } ?? []

        let formatValues: [String] = [
            source.container?.uppercased(),
            source.size.map { formatFileSize($0) },
            formatBitrate(source.bitrate).map { "\($0) total" },
        ].compactMap { $0 }

        let audioValues: [String] = audios.prefix(3).compactMap { $0.audioLabel ?? $0.displayTitle }
        let audioLabel = audios.count == 1 ? "Audio" : "Audio (\(audios.count))"
        let subValues  = subs.isEmpty ? [] : [subs.compactMap { $0.language ?? $0.title }.prefix(6).joined(separator: ", ")]

        return VStack(alignment: .leading, spacing: 14) {
            Text("Technical")
                .font(.system(size: scopeMode ? 16 : 20, weight: .semibold))
                .foregroundStyle(CinemaTheme.tertiary(colorMode))

            VStack(alignment: .leading, spacing: scopeMode ? 6 : 10) {
                if !videoValues.isEmpty {
                    specRow(label: "Video", values: videoValues)
                }
                if !formatValues.isEmpty {
                    specRow(label: "Format", values: formatValues)
                }
                if !audioValues.isEmpty {
                    specRow(label: audioLabel, values: audioValues)
                }
                if !subValues.isEmpty {
                    specRow(label: "Subtitles", values: subValues)
                }
            }
        }
    }

    // MARK: - Spec row

    private func specRow(label: String, values: [String]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .font(.system(size: scopeMode ? 12 : 14, weight: .semibold))
                .foregroundStyle(CinemaTheme.tertiary(colorMode))
                .frame(width: scopeMode ? 64 : 80, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(.system(size: scopeMode ? 12 : 14, weight: .medium))
                        .foregroundStyle(CinemaTheme.secondary(colorMode))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            CinemaTheme.surfaceNav(colorMode),
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                }
            }
        }
    }

    // MARK: - Formatting helpers

    private func formatBitrate(_ bps: Int?) -> String? {
        guard let bps else { return nil }
        if bps >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bps) / 1_000_000)
        } else if bps >= 1_000 {
            return String(format: "%.0f kbps", Double(bps) / 1_000)
        }
        return "\(bps) bps"
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}
