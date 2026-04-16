import Foundation

// MARK: - PresentationMode
//
// Two concepts are deliberately separated here:
//
//   VIEWPORT  — the screen region the player is allowed to fill
//               • Scope Safe  → the 2.39:1 canvas (the region between the scope bars)
//               • Full Screen → the entire display
//
//   CONTENT FIT — how the video is scaled inside that viewport
//               • Always "fit" (resizeAspect): never crops, always letterbox/pillarbox
//               • One place performs this math: ScopeCanvasGeometry.videoRect(for:contentRatio:in:)
//
// The default viewport is determined by UI mode, not by the video's aspect ratio.
// See PresentationMode.defaultMode(scopeUIEnabled:).

enum PresentationMode: String, CaseIterable, Identifiable {

    /// Viewport = 2.39:1 scope canvas centred on screen.
    /// Video is fitted inside that canvas.
    /// For scope content: fills the canvas edge-to-edge.
    /// For HDTV/4:3:  pillar-boxed inside the canvas (within the bars).
    case scopeSafe

    /// Viewport = full display.
    /// Video is fitted to the entire screen.
    /// For scope content: letterboxed (bars top/bottom).
    /// For HDTV/4:3:  fills the screen (HDTV) or pillarboxed (4:3).
    case fullScreen

    // Future modes — not yet implemented
    case zoomToFill
    case dynamicAspect
    case constantScopeLock

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scopeSafe:         return "Scope Safe"
        case .fullScreen:        return "Full Screen"
        case .zoomToFill:        return "Zoom to Fill"
        case .dynamicAspect:     return "Dynamic Aspect"
        case .constantScopeLock: return "Constant Scope Lock"
        }
    }

    var isImplemented: Bool {
        switch self {
        case .scopeSafe, .fullScreen: return true
        default: return false
        }
    }

    // MARK: - Default mode selection

    /// The correct default mode for the current UI setting.
    /// UI mode is the single authority for the default viewport — not the aspect ratio.
    ///
    ///   Scope UI on  → Scope Safe  (video stays within the 2.39 canvas)
    ///   Scope UI off → Full Screen (video fills the display)
    static func defaultMode(scopeUIEnabled: Bool) -> PresentationMode {
        scopeUIEnabled ? .scopeSafe : .fullScreen
    }
}
