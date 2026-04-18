// MARK: - PlayerLab / Render / PlayerLabDisplayView
//
// Sprint 10 — Frame Rendering Proof
//
// Debug-only SwiftUI surface that hosts an AVSampleBufferDisplayLayer.
// The layer is owned by a FrameRenderer passed in from outside, so the
// rendering pipeline and the view lifecycle stay decoupled.
//
// tvOS uses UIKit, so this is a UIViewRepresentable.
// The underlying UIView subclass overrides layoutSubviews() to keep the
// display layer filling the entire view bounds — no AutoLayout needed.
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
        // Attach the display layer once, here.  layoutSubviews keeps it sized.
        view.attachDisplayLayer(renderer.layer)
        fputs("[PlayerLabDisplayView] UIView created — layer attached\n", stderr)
        return view
    }

    func updateUIView(_ uiView: PlayerLabVideoUIView, context: Context) {
        // Force a synchronous layout update when SwiftUI triggers a re-render.
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

    func attachDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        // Remove any previously attached layer
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
