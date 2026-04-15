import CoreGraphics

enum ScopeCanvasGeometry {

    /// The 2.39:1 scope canvas rect, centered on screen.
    /// Used as the bounding box for Fit Inside Scope mode only.
    static func canvasRect(in screenSize: CGSize) -> CGRect {
        let canvasHeight = screenSize.width / AspectBucket.scopeRatio
        let yOffset = (screenSize.height - canvasHeight) / 2
        return CGRect(x: 0, y: yOffset, width: screenSize.width, height: canvasHeight)
    }

    static func videoRect(
        for mode: PresentationMode,
        contentRatio: Double,
        in screenSize: CGSize
    ) -> CGRect {
        switch mode {

        case .fillScope:
            // Natural presentation — fit the video into the full screen
            // using its own aspect ratio. Black bars appear wherever
            // the video doesn't fill (sides for 4:3, top/bottom for ultra-wide).
            // This is what AVPlayer's resizeAspect does natively when given
            // the full screen rect — we just make that explicit here.
            return fitRect(ratio: contentRatio, in: CGRect(origin: .zero, size: screenSize))

        case .fitInsideScope:
            // Fit the video inside the 2.39:1 canvas, centered.
            // Results in a smaller image than fillScope for non-scope content.
            let canvas = canvasRect(in: screenSize)
            return fitRect(ratio: contentRatio, in: canvas)

        default:
            return CGRect(origin: .zero, size: screenSize)
        }
    }

    /// Fit a rect of the given aspect ratio inside a container,
    /// centered, preserving the ratio. Black background fills remainder.
    private static func fitRect(ratio: Double, in container: CGRect) -> CGRect {
        guard ratio > 0 else { return container }

        let containerRatio = container.width / container.height

        let fitted: CGSize
        if ratio > containerRatio {
            // Content is wider than container — constrain by width
            fitted = CGSize(width: container.width, height: container.width / ratio)
        } else {
            // Content is taller than container — constrain by height
            fitted = CGSize(width: container.height * ratio, height: container.height)
        }

        let x = container.minX + (container.width  - fitted.width)  / 2
        let y = container.minY + (container.height - fitted.height) / 2
        return CGRect(origin: CGPoint(x: x, y: y), size: fitted)
    }
}
