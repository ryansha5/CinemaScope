import UIKit
import SwiftUI

// MARK: - FocusRingFreeButton
//
// Subclasses UIButton to intercept the tvOS focus ring at the UIKit level.
// The system injects _TVFocusRingView as a sibling of any focused UIView.
// By overriding didUpdateFocus and returning nil for focusItemContainer
// we prevent the ring from being added entirely.

final class FocusRingFreeButton: UIButton {

    override func didUpdateFocus(
        in context: UIFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        // Do NOT call super — this is what triggers the system ring injection
        // We handle our own visual focus state via SwiftUI's @FocusState
    }

    // Return nil so the focus engine has nowhere to attach the ring view
    override var focusItemContainer: UIFocusItemContainer? { nil }

    // Prevent the system from adding any focus-related subviews
    override func addSubview(_ view: UIView) {
        // Block any view whose class name contains "Focus" or "Ring" or "Halo"
        let name = String(describing: type(of: view))
        guard !name.contains("Focus"),
              !name.contains("Ring"),
              !name.contains("Halo") else { return }
        super.addSubview(view)
    }
}

// MARK: - FocusRingFreeButtonStyle
//
// A SwiftUI ButtonStyle that uses FocusRingFreeButton as the underlying
// UIKit control instead of the default UIButton.

struct FocusRingFreeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(FocusRingFreeButtonRepresentable())
    }
}

// MARK: - FocusRingFreeButtonRepresentable
//
// Inserts a zero-size FocusRingFreeButton into the hierarchy so that
// SwiftUI's button infrastructure uses our subclass.

private struct FocusRingFreeButtonRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> FocusRingFreeButton {
        let button = FocusRingFreeButton(type: .custom)
        button.backgroundColor = .clear
        return button
    }
    func updateUIView(_ uiView: FocusRingFreeButton, context: Context) {}
}

// MARK: - View extension for convenience

extension View {
    /// Applies FocusRingFreeButtonStyle and disables the system focus effect.
    func focusRingFree() -> some View {
        self
            .buttonStyle(FocusRingFreeButtonStyle())
            .focusEffectDisabled()
    }
}
