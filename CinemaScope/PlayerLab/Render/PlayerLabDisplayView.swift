// MARK: - PlayerLab / Render / PlayerLabDisplayView
//
// Sprint 10 — Frame Rendering Proof
// Sprint 52 — Identity-safe layer re-attach on renderer change
//
// Debug-only SwiftUI surface that hosts an AVSampleBufferDisplayLayer.
// The layer is owned by a FrameRenderer passed in from outside, so the
// rendering pipeline and the view lifecycle stay decoupled.
//
// tvOS uses UIKit, so this is a UIViewRepresentable.
// The underlying UIView subclass overrides layoutSubviews() to keep the
// display layer filling the entire view bounds — no AutoLayout needed.
//
// Identity-safe update:
//   makeUIView attaches the initial display layer.
//   updateUIView compares the incoming renderer's layer object identity
//   against the currently attached layer.  Re-attach only fires when the
//   layer object itself changes — i.e. when the renderer prop switches from
//   one FrameRenderer instance to another (e.g. phase switch from Phase 3
//   controller to Phase 4 audioController).  During normal playback SwiftUI
//   calls updateUIView on every state change (buffer level, frame count, etc.)
//   but the layer identity stays the same, so no re-attach occurs.
//
// Usage:
//   PlayerLabDisplayView(renderer: controller.renderer)
//       .frame(maxWidth: .infinity, maxHeight: .infinity)
//       .ignoresSafeArea()

import SwiftUI
import AVFoundation
import UIKit
import QuartzCore

// MARK: - PlayerLabDisplayView

struct PlayerLabDisplayView: UIViewRepresentable {

    /// The renderer whose AVSampleBufferDisplayLayer will be displayed.
    let renderer: FrameRenderer

    func makeUIView(context: Context) -> PlayerLabVideoUIView {
        let view = PlayerLabVideoUIView()
        view.backgroundColor = .black
        // Attach the display layer once at creation time.
        // layoutSubviews keeps it sized; updateUIView handles renderer identity changes.
        view.attachDisplayLayer(renderer.layer)
        fputs("[PlayerLabDisplayView] UIView created — layer attached\n", stderr)
        return view
    }

    func updateUIView(_ uiView: PlayerLabVideoUIView, context: Context) {
        // Identity check — only re-attach when the renderer's layer object itself
        // has changed (e.g. phase switch from Phase 3 controller → Phase 4 audioController).
        // During playback SwiftUI calls updateUIView frequently (every Published change),
        // but the layer identity stays the same, so re-attach is skipped and the
        // mid-playback layer teardown regression from the prior Phase 4 attempt cannot occur.
        if uiView.currentDisplayLayer !== renderer.layer {
            fputs("[PlayerLabDisplayView] renderer changed — re-attaching display layer\n", stderr)
            uiView.attachDisplayLayer(renderer.layer)
        }

        // Keep the layer frame in sync with the view bounds on every SwiftUI re-render.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.layer.frame = uiView.bounds
        CATransaction.commit()
    }
}

// MARK: - PlayerLabVideoUIView

/// Plain UIView subclass that hosts one AVSampleBufferDisplayLayer.
/// Keeps the layer exactly filling its own bounds at all times.
final class PlayerLabVideoUIView: UIView {

    private var displayLayer: AVSampleBufferDisplayLayer?

    /// The currently attached display layer.  Read by PlayerLabDisplayView.updateUIView
    /// for the identity check — re-attach only when this differs from the incoming layer.
    var currentDisplayLayer: AVSampleBufferDisplayLayer? { displayLayer }

    func attachDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        // Remove any previously attached layer before adding the new one.
        displayLayer?.removeFromSuperlayer()
        displayLayer = layer
        self.layer.addSublayer(layer)
        layer.frame = bounds
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let dl = displayLayer else { return }
        // Disable implicit animations so the layer never lags during resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dl.frame = bounds
        CATransaction.commit()
    }
}
