import SwiftUI

/// Debug overlay — Sprint 2 version adds bucket and mode readout.
/// Will be replaced by a proper OSD in Sprint 3.
struct DimensionsOverlay: View {

    let dimensions: VideoDimensions?
    let state: PlaybackState
    let bucket: AspectBucket
    let mode: PresentationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            stateRow
            if let dims = dimensions {
                row(label: "Dims", value: dims.debugDescription)
                row(label: "Type", value: bucket.label)
                row(label: "Mode", value: mode.label)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(40)
    }

    private var stateRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 10, height: 10)
            Text(stateLabel)
                .font(.system(.caption, design: .monospaced))
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    private var stateLabel: String {
        switch state {
        case .idle:           return "IDLE"
        case .loading:        return "LOADING…"
        case .playing:        return "PLAYING"
        case .paused:         return "PAUSED"
        case .failed(let e):  return "ERROR: \(e)"
        }
    }

    private var stateColor: Color {
        switch state {
        case .playing:  return .green
        case .loading:  return .yellow
        case .failed:   return .red
        default:        return .gray
        }
    }
}
