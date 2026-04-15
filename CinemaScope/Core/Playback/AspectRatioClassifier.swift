import Foundation

// MARK: - Aspect Ratio Bucket

/// The classification buckets for the playback decision engine.
/// Thresholds are based on real-world stream dimensions, not
/// container metadata. Dune at 1920×800 = 2.40:1 → .scope ✓
enum AspectBucket: Equatable {
    case scope          // 2.30 – 2.45  (2.39:1 anamorphic, 2.40:1, 2.35:1)
    case flat           // 1.80 – 1.89  (1.85:1 theatrical flat)
    case hdtv           // 1.74 – 1.79  (16:9 = 1.778)
    case academy        // 1.30 – 1.40  (4:3 = 1.333)
    case unclassified   // anything outside the above ranges

    /// Human-readable label for OSD and debug display.
    var label: String {
        switch self {
        case .scope:        return "Scope  (2.39:1)"
        case .flat:         return "Flat  (1.85:1)"
        case .hdtv:         return "HDTV  (16:9)"
        case .academy:      return "Academy  (4:3)"
        case .unclassified: return "Unclassified"
        }
    }

    /// The canonical scope canvas ratio. All presentation math is
    /// anchored to this value throughout the app.
    static let scopeRatio: Double = 2.39
}

// MARK: - AspectRatioClassifier

/// Pure function classifier. Takes a ratio, returns a bucket.
/// No state, no side effects — easy to unit test in Sprint 2+.
enum AspectRatioClassifier {

    /// Classify a ratio derived from actual stream dimensions.
    static func classify(_ ratio: Double) -> AspectBucket {
        switch ratio {
        case 2.30...2.45: return .scope
        case 1.80...1.89: return .flat
        case 1.74...1.79: return .hdtv
        case 1.30...1.40: return .academy
        default:          return .unclassified
        }
    }

    /// Convenience: classify directly from a VideoDimensions value.
    static func classify(_ dimensions: VideoDimensions) -> AspectBucket {
        classify(dimensions.aspectRatio)
    }
}
