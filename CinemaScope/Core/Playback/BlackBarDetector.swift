import CoreGraphics
import AVFoundation

// MARK: - BlackBarDetector
//
// Estimates the true visible image area by sampling rows of a video frame
// and finding where the content ends and black bars begin.
//
// Design goals:
//   • Works on a downsampled CGImage (≤320px wide) — cheap to compute
//   • Scans top and bottom, stopping at the first non-black row
//   • Uses average luminance per row against a configurable threshold
//   • Left/right bar detection is included for future use
//   • Returns an adjusted aspect ratio; nil if detection is inconclusive
//
// Accuracy notes (Day 1):
//   • Covers the common "scope movie in 1080p container" case
//   • Will not catch soft-vignette fades or very dark scenes
//   • A user override always takes priority (see AspectRatioStore)

enum BlackBarDetector {

    // MARK: - Configuration

    /// Luminance [0–1] below which a row is considered "black".
    /// 0.05 catches near-pure-black encoding artifacts without false positives.
    static let blackThreshold: Double = 0.05

    /// Column range fraction to sample (centre 80%), avoiding edge encoding noise.
    static let widthSampleFraction: Double = 0.80

    /// Column stride: sample every Nth pixel to keep this fast.
    static let columnStride: Int = 4

    /// Minimum bars (px at original resolution) that are worth reporting.
    /// Below this, we treat the content as filling the frame.
    static let minimumBarFraction: Double = 0.02   // 2 % of height

    // MARK: - Public API

    /// Analyse a CGImage (ideally downsampled to ≤320px wide for speed)
    /// and return the estimated effective aspect ratio of the visible content.
    ///
    /// Returns nil if the frame is too dark to read, bars are below the
    /// minimum threshold, or the pixel data cannot be accessed.
    static func effectiveRatio(from image: CGImage) -> Double? {
        let width  = image.width
        let height = image.height
        guard width > 4, height > 4 else { return nil }

        // Render into an 8-bit RGBA bitmap context
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow   = bytesPerPixel * width
        let bitmapCount   = bytesPerRow * height

        var pixels = [UInt8](repeating: 0, count: bitmapCount)
        guard let ctx = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let sampleStart = Int(Double(width) * (1.0 - widthSampleFraction) / 2.0)
        let sampleEnd   = width - sampleStart

        let topBars    = countBlackRows(
            pixels: pixels, bytesPerRow: bytesPerRow,
            width: width, height: height,
            fromTop: true, sampleStart: sampleStart, sampleEnd: sampleEnd
        )
        let bottomBars = countBlackRows(
            pixels: pixels, bytesPerRow: bytesPerRow,
            width: width, height: height,
            fromTop: false, sampleStart: sampleStart, sampleEnd: sampleEnd
        )

        let totalBars    = topBars + bottomBars
        let minBarPixels = Int(Double(height) * minimumBarFraction)

        // If bars are negligible, the content fills the frame — don't override
        guard totalBars >= minBarPixels else { return nil }

        let visibleHeight = height - totalBars
        guard visibleHeight > 0 else { return nil }

        let ratio = Double(width) / Double(visibleHeight)

        // Sanity check: must be a plausible film ratio
        guard ratio >= 1.0 && ratio <= 5.0 else { return nil }

        return ratio
    }

    // MARK: - Private

    private static func countBlackRows(
        pixels: [UInt8], bytesPerRow: Int,
        width: Int, height: Int,
        fromTop: Bool,
        sampleStart: Int, sampleEnd: Int
    ) -> Int {
        var blackRows = 0
        let maxScan = height / 2   // never scan more than half the frame

        for i in 0..<maxScan {
            let row = fromTop ? i : (height - 1 - i)
            let rowBase = row * bytesPerRow

            var lumaSum: Double = 0
            var sampleCount  = 0

            var col = sampleStart
            while col < sampleEnd {
                let pixBase = rowBase + col * 4
                let r = Double(pixels[pixBase + 0])
                let g = Double(pixels[pixBase + 1])
                let b = Double(pixels[pixBase + 2])
                // Rec.601 luma
                lumaSum += (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
                sampleCount += 1
                col += columnStride
            }

            let avgLuma = sampleCount > 0 ? lumaSum / Double(sampleCount) : 0
            if avgLuma < blackThreshold {
                blackRows += 1
            } else {
                break   // first non-black row — stop
            }
        }
        return blackRows
    }
}

// MARK: - AVAssetImageGenerator + BlackBarDetector convenience

extension BlackBarDetector {

    /// Asynchronously samples a frame near the midpoint of an AVAsset and
    /// runs black-bar detection.  Returns nil on any failure.
    ///
    /// The image is downsampled to at most 320 px wide for efficiency.
    static func detectFrom(asset: AVAsset, duration: Double) async -> Double? {
        guard duration > 0 else { return nil }

        let sampleTime = CMTime(
            seconds: max(duration * 0.15, min(duration * 0.5, 30)),
            preferredTimescale: 600
        )

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 2, preferredTimescale: 600)

        do {
            let (cgImage, _) = try await generator.image(at: sampleTime)
            return effectiveRatio(from: cgImage)
        } catch {
            print("[BlackBarDetector] Frame sample failed: \(error.localizedDescription)")
            return nil
        }
    }
}
