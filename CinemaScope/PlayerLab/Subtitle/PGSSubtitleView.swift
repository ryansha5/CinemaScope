// MARK: - PlayerLab / Subtitle / PGSSubtitleView
// Sprint 28 — Bitmap subtitle overlay for PGS cues.
// Scales objectRect from video-space coordinates to the actual view bounds,
// preserving aspect ratio (letterbox/pillarbox aware).
// Non-interactive (allowsHitTesting false).
// NOT production-ready.

import SwiftUI
import CoreGraphics

struct PGSSubtitleView: View {
    let cue: PGSCue?

    var body: some View {
        GeometryReader { geo in
            if let cue, let cgImage = cue.image, cue.videoSize.width > 0, cue.videoSize.height > 0 {
                let viewW = geo.size.width
                let viewH = geo.size.height
                let scaleX = viewW / cue.videoSize.width
                let scaleY = viewH / cue.videoSize.height
                let scale = min(scaleX, scaleY)

                // Letterbox/pillarbox offsets
                let videoDispW = cue.videoSize.width * scale
                let videoDispH = cue.videoSize.height * scale
                let xOff = (viewW - videoDispW) / 2
                let yOff = (viewH - videoDispH) / 2

                let imgW = CGFloat(cgImage.width) * scale
                let imgH = CGFloat(cgImage.height) * scale
                let imgX = xOff + (cue.objectRect.minX + cue.objectRect.width / 2) * scale
                let imgY = yOff + (cue.objectRect.minY + cue.objectRect.height / 2) * scale

                Image(decorative: cgImage, scale: 1.0)
                    .resizable()
                    .frame(width: max(1, imgW), height: max(1, imgH))
                    .position(x: imgX, y: imgY)
            }
        }
        .allowsHitTesting(false)
    }
}
