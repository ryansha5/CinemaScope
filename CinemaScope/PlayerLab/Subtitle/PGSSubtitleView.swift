// MARK: - PlayerLab / Subtitle / PGSSubtitleView
// Sprint 28 — Bitmap subtitle overlay for PGS cues.
// Sprint 40 — Rendering quality + positioning improvements:
//   • Safe-area clamping: subtitle centre is kept ≥5% away from the edges of
//     the video display area so bitmaps cannot be clipped by bezels/overscan.
//   • windowRect fallback: when objectRect.origin is (0,0) and the cue carries
//     a non-trivial WDS window rect, the window midpoint is used as the position
//     anchor instead of the origin — avoids accidental top-left placement for
//     content that omits PCS composition object co-ordinates.
//   • Forced-cue display is handled by PGSSubtitleController (Sprint 40); this
//     view simply renders whatever currentCue the controller publishes.
//
// Scales objectRect from video-space coordinates to the actual view bounds,
// preserving aspect ratio (letterbox/pillarbox aware).
// Non-interactive (allowsHitTesting false).
// NOT production-ready.

import SwiftUI
import CoreGraphics

struct PGSSubtitleView: View {
    let cue: PGSCue?

    // MARK: - Layout helper

    /// All positioning/scaling arithmetic lives here, outside any @ViewBuilder
    /// closure.  @ViewBuilder treats `if/else` as a view-building expression
    /// (ConditionalContent<A,B>), so deferred `let` assignment across an if/else
    /// branch inside a GeometryReader would cause "buildExpression unavailable"
    /// errors.  Keeping math in a plain method avoids the ambiguity entirely.
    private struct Layout {
        let imgW:     CGFloat
        let imgH:     CGFloat
        let clampedX: CGFloat
        let clampedY: CGFloat
    }

    private func layout(for cue: PGSCue, cgImage: CGImage, in viewSize: CGSize) -> Layout {
        let viewW  = viewSize.width
        let viewH  = viewSize.height
        let scaleX = viewW / cue.videoSize.width
        let scaleY = viewH / cue.videoSize.height
        let scale  = min(scaleX, scaleY)

        // Letterbox / pillarbox offsets
        let videoDispW = cue.videoSize.width  * scale
        let videoDispH = cue.videoSize.height * scale
        let xOff       = (viewW - videoDispW) / 2
        let yOff       = (viewH - videoDispH) / 2

        let imgW = CGFloat(cgImage.width)  * scale
        let imgH = CGFloat(cgImage.height) * scale

        // ── Position anchor ──────────────────────────────────────────────────
        // Primary source: PCS composition object (x, y) stored in objectRect.
        // Sprint 40 fallback: if objectRect.origin is (0, 0) and the cue
        // carries a WDS window rect with a non-trivial position, use the
        // window midpoint instead — handles encoders that leave PCS x/y at
        // zero but author a correct WDS.
        let useWindowFallback = cue.objectRect.origin == .zero
            && (cue.windowRect?.origin ?? .zero) != .zero
        let posX: CGFloat = useWindowFallback
            ? (cue.windowRect?.midX ?? (cue.objectRect.minX + cue.objectRect.width  / 2))
            : (cue.objectRect.minX + cue.objectRect.width  / 2)
        let posY: CGFloat = useWindowFallback
            ? (cue.windowRect?.midY ?? (cue.objectRect.minY + cue.objectRect.height / 2))
            : (cue.objectRect.minY + cue.objectRect.height / 2)

        // Raw centre position in view coordinates (before clamping).
        let rawX = xOff + posX * scale
        let rawY = yOff + posY * scale

        // ── Safe-area clamping (Sprint 40) ───────────────────────────────────
        // Keep the subtitle bitmap centre at least 5% of the video display
        // dimension away from any edge, accounting for half-image extents.
        // maxBound is floored to minBound if the image is wider than the safe
        // zone (extreme edge case) so clamping degrades gracefully rather than
        // producing an inverted range.
        let hMargin = videoDispW * 0.05
        let vMargin = videoDispH * 0.05

        let minX = xOff + hMargin + imgW / 2
        let maxX = Swift.max(minX, xOff + videoDispW - hMargin - imgW / 2)
        let minY = yOff + vMargin + imgH / 2
        let maxY = Swift.max(minY, yOff + videoDispH - vMargin - imgH / 2)

        return Layout(
            imgW:     imgW,
            imgH:     imgH,
            clampedX: Swift.min(Swift.max(rawX, minX), maxX),
            clampedY: Swift.min(Swift.max(rawY, minY), maxY)
        )
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            if let cue, let cgImage = cue.image,
               cue.videoSize.width > 0, cue.videoSize.height > 0 {
                let l = layout(for: cue, cgImage: cgImage, in: geo.size)
                Image(decorative: cgImage, scale: 1.0)
                    .resizable()
                    .frame(width: max(1, l.imgW), height: max(1, l.imgH))
                    .position(x: l.clampedX, y: l.clampedY)
            }
        }
        .allowsHitTesting(false)
    }
}
