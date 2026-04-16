import CoreGraphics

// MARK: - ScopeCanvasGeometry
//
// Single authority for the video rect passed to AVPlayerLayer.
//
// Architecture contract:
//   • This is the ONLY place that maps (mode, contentRatio, screenSize) → CGRect
//   • AVPlayerLayer.videoGravity must be .resizeAspectFill so the layer zooms the
//     raw stream to fill the computed rect while preserving pixel aspect ratio.
//     Embedded letterbox/pillarbox bars in the stream overflow the layer bounds and
//     are clipped — giving a zoom-crop rather than a stretch.
//   • contentRatio = PlaybackEngine.effectiveContentRatio (respects user override,
//     black-bar detection, then raw metadata — in that priority order)

enum ScopeCanvasGeometry {

    // MARK: - Scope canvas

    /// The 2.39:1 scope canvas rect, centred on screen.
    /// This is the viewport used for Scope Safe mode.
    static func canvasRect(in screenSize: CGSize) -> CGRect {
        let canvasHeight = screenSize.width / AspectBucket.scopeRatio
        let yOffset = (screenSize.height - canvasHeight) / 2
        return CGRect(x: 0, y: yOffset, width: screenSize.width, height: canvasHeight)
    }

    // MARK: - Video rect

    /// Returns the exact CGRect for the AVPlayerLayer given the current mode,
    /// effective content ratio, and screen size.
    ///
    /// - scopeSafe:   viewport = 2.39 canvas.  Video fitted inside the canvas.
    /// - fullScreen:  viewport = full screen.  Video fitted to fill the screen.
    static func videoRect(
        for mode: PresentationMode,
        contentRatio: Double,
        in screenSize: CGSize
    ) -> CGRect {
        switch mode {

        case .fullScreen:
            // Viewport is the entire screen.
            // The video is fitted once — no additional scaling from AVPlayerLayer.
            return fitRect(ratio: contentRatio, in: CGRect(origin: .zero, size: screenSize))

        case .scopeSafe:
            // Viewport is the 2.39:1 canvas centred on screen.
            // For scope content: fills the canvas.
            // For HDTV/4:3: pillar-boxed inside the canvas.
            let canvas = canvasRect(in: screenSize)
            return fitRect(ratio: contentRatio, in: canvas)

        default:
            // Unimplemented modes fall back to full screen
            return CGRect(origin: .zero, size: screenSize)
        }
    }

    // MARK: - Fit helper

    /// Scales a rect of the given aspect ratio to fit inside a container,
    /// preserving the ratio, centred.  Black background fills the remainder.
    static func fitRect(ratio: Double, in container: CGRect) -> CGRect {
        guard ratio > 0 else { return container }

        let containerRatio = container.width / container.height

        let fitted: CGSize
        if ratio > containerRatio {
            // Content is wider than container — letter-box (constrain by width)
            fitted = CGSize(width: container.width, height: container.width / ratio)
        } else {
            // Content is taller than container — pillar-box (constrain by height)
            fitted = CGSize(width: container.height * ratio, height: container.height)
        }

        let x = container.minX + (container.width  - fitted.width)  / 2
        let y = container.minY + (container.height - fitted.height) / 2
        return CGRect(origin: CGPoint(x: x, y: y), size: fitted)
    }
}
