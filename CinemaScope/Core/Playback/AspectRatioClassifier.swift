import Foundation

// MARK: - AspectBucket

/// Classification buckets for aspect ratio display and override matching.
/// Buckets are used for the OSD badge and to map overrides to ratios.
/// They do NOT drive viewport selection (that is `PresentationMode.defaultMode`).
enum AspectBucket: Equatable {

    case scope          // 2.35 – 2.40  (theatrical anamorphic: 2.35, 2.39, 2.40)
    case flat           // 1.82 – 1.88  (theatrical flat: 1.85:1)
    case hdtv           // 1.74 – 1.79  (16:9 = 1.778)
    case academy        // 1.30 – 1.40  (4:3 = 1.333)
    case unclassified   // anything outside the above ranges

    /// Human-readable label for OSD and debug display.
    var label: String {
        switch self {
        case .scope:        return "Scope  (2.39)"
        case .flat:         return "Flat  (1.85)"
        case .hdtv:         return "16:9"
        case .academy:      return "4:3"
        case .unclassified: return "Custom"
        }
    }

    /// The canonical 2.39:1 scope canvas ratio.
    /// All scope viewport geometry is anchored to this value.
    static let scopeRatio: Double = 2.39
}

// MARK: - AspectRatioClassifier

/// Classifies a measured aspect ratio into a bucket.
///
/// Detection priority (handled by PlaybackEngine, not here):
///   1. User override from AspectRatioStore          (highest)
///   2. Black-bar detection via BlackBarDetector
///   3. Container / presentation-size metadata       (this classifier)
///   4. Fallback: .unclassified
///
/// Tolerances are practical — based on how real-world encodes differ
/// from the exact theoretical ratios:
///   2.35 – 2.40  covers 2.35:1, 2.39:1, 2.40:1 anamorphic
///   1.82 – 1.88  covers 1.85:1 theatrical flat
///   1.74 – 1.79  covers 16:9 (1.778) with encoding drift
///   1.30 – 1.40  covers 4:3 (1.333) and near-square formats
enum AspectRatioClassifier {

    static func classify(_ ratio: Double) -> AspectBucket {
        switch ratio {
        case 2.35...2.40: return .scope
        case 1.82...1.88: return .flat
        case 1.74...1.79: return .hdtv
        case 1.30...1.40: return .academy
        default:          return .unclassified
        }
    }

    static func classify(_ dimensions: VideoDimensions) -> AspectBucket {
        classify(dimensions.aspectRatio)
    }

    // MARK: - Ratio proximity helpers

    /// Returns the nearest named bucket ratio to a raw value.
    /// Used to snap the "detected" ratio to a clean number for display.
    static func nearestNamedRatio(_ ratio: Double) -> Double {
        let candidates: [Double] = [2.39, 1.85, 16.0/9.0, 4.0/3.0]
        return candidates.min(by: { abs($0 - ratio) < abs($1 - ratio) }) ?? ratio
    }
}
