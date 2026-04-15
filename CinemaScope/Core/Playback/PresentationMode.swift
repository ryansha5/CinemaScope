import Foundation

enum PresentationMode: String, CaseIterable, Identifiable {
    case fillScope
    case fitInsideScope
    case zoomToFill
    case dynamicAspect
    case constantScopeLock

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fillScope:         return "Fill Scope"
        case .fitInsideScope:    return "Fit Inside Scope"
        case .zoomToFill:        return "Zoom to Fill"
        case .dynamicAspect:     return "Dynamic Aspect"
        case .constantScopeLock: return "Constant Scope Lock"
        }
    }

    var isImplemented: Bool {
        switch self {
        case .fillScope, .fitInsideScope: return true
        default: return false
        }
    }

    /// Always returns a valid mode — unclassified content defaults to fitInsideScope.
    static func automatic(for bucket: AspectBucket) -> PresentationMode {
        switch bucket {
        case .scope:        return .fillScope
        case .flat,
             .hdtv,
             .academy,
             .unclassified: return .fitInsideScope
        }
    }
}
