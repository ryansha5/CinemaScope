import SwiftUI

// MARK: - OnboardingPage

private struct OnboardingPage: Identifiable {
    let id:       Int
    let icon:     String
    let title:    String
    let subtitle: String
    let body:     String
    let accent:   Color
}

private let onboardingPages: [OnboardingPage] = [
    OnboardingPage(
        id: 0,
        icon: "film.stack",
        title: "Welcome to CinemaScope",
        subtitle: "Your Emby library, beautifully presented.",
        body: "Browse your entire movie and TV collection from your personal media server — fast, focused, and distraction-free.",
        accent: CinemaTheme.accentGold
    ),
    OnboardingPage(
        id: 1,
        icon: "house.fill",
        title: "Your Home Screen",
        subtitle: "Curate it your way.",
        body: "Build a home screen that matches how you watch. Add genre rows, rearrange them, hide what you don't need — all from Settings.",
        accent: CinemaTheme.peacock
    ),
    OnboardingPage(
        id: 2,
        icon: "rectangle.inset.filled",
        title: "Scope UI",
        subtitle: "The cinema experience, at home.",
        body: "Toggle Scope UI from the nav bar to letterbox the entire interface in a true 2.39:1 ultra-wide canvas — just like the real thing.",
        accent: Color(red: 0.5, green: 0.85, blue: 1.0)
    ),
    OnboardingPage(
        id: 3,
        icon: "play.circle.fill",
        title: "Ready to Watch",
        subtitle: "Dive straight in.",
        body: "Your library is loaded and ready. Use the remote to navigate, hold Select to pause, and press Menu to exit the player.",
        accent: CinemaTheme.accentGold
    ),
]

// MARK: - OnboardingView

struct OnboardingView: View {

    let onComplete: () -> Void

    @State private var currentPage = 0
    @FocusState private var focusedButton: OnboardingButton?

    enum OnboardingButton: Hashable { case next, skip }

    private var isLastPage: Bool { currentPage == onboardingPages.count - 1 }
    private var page: OnboardingPage { onboardingPages[currentPage] }

    var body: some View {
        ZStack {
            // Background
            CinemaBackground()

            VStack(spacing: 0) {
                Spacer()

                // Page content
                VStack(spacing: 0) {
                    pageContent
                        .id(currentPage)   // forces re-render + re-animation on page change
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal:   .move(edge: .leading).combined(with: .opacity)
                        ))
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: currentPage)
                .frame(maxWidth: 820)

                Spacer()

                // Page indicators + nav buttons
                VStack(spacing: 32) {
                    pageIndicators

                    HStack(spacing: 24) {
                        // Skip button — only on non-last pages
                        if !isLastPage {
                            OnboardingActionButton(
                                label:     "Skip",
                                icon:      "forward.fill",
                                isPrimary: false,
                                isFocused: focusedButton == .skip
                            ) { onComplete() }
                            .focused($focusedButton, equals: .skip)
                        }

                        OnboardingActionButton(
                            label:     isLastPage ? "Get Started" : "Next",
                            icon:      isLastPage ? "play.fill" : "arrow.right",
                            isPrimary: true,
                            isFocused: focusedButton == .next
                        ) {
                            if isLastPage {
                                onComplete()
                            } else {
                                withAnimation { currentPage += 1 }
                                focusedButton = .next
                            }
                        }
                        .focused($focusedButton, equals: .next)
                    }
                    .focusSection()
                }
                .padding(.bottom, 72)
            }
            .padding(.horizontal, 120)
        }
        .onAppear { focusedButton = .next }
    }

    // MARK: - Page content

    private var pageContent: some View {
        VStack(spacing: 36) {
            // Icon
            ZStack {
                Circle()
                    .fill(page.accent.opacity(0.15))
                    .frame(width: 140, height: 140)
                Circle()
                    .strokeBorder(page.accent.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 140, height: 140)
                Image(systemName: page.icon)
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(page.accent)
            }

            // Text
            VStack(spacing: 14) {
                Text(page.title)
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(page.subtitle)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(page.accent)
                    .multilineTextAlignment(.center)

                Text(page.body)
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .frame(maxWidth: 660)
            }
        }
    }

    // MARK: - Page indicators

    private var pageIndicators: some View {
        HStack(spacing: 10) {
            ForEach(onboardingPages) { p in
                Capsule()
                    .fill(currentPage == p.id
                          ? onboardingPages[currentPage].accent
                          : .white.opacity(0.25))
                    .frame(width: currentPage == p.id ? 28 : 8, height: 8)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentPage)
            }
        }
    }
}

// MARK: - OnboardingActionButton

private struct OnboardingActionButton: View {
    let label:     String
    let icon:      String
    let isPrimary: Bool
    let isFocused: Bool
    let action:    () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if isPrimary {
                    Text(label)
                        .font(.system(size: 20, weight: .semibold))
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                } else {
                    Text(label)
                        .font(.system(size: 18, weight: .medium))
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                }
            }
            .foregroundStyle(buttonForeground)
            .padding(.horizontal, isPrimary ? 40 : 32)
            .padding(.vertical, isPrimary ? 18 : 14)
            .background {
                ZStack {
                    tintColor.opacity(isFocused ? 0.55 : 0.14)
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(isFocused ? 0.50 : 0.20), location: 0),
                            .init(color: .white.opacity(isFocused ? 0.12 : 0.04), location: 0.45),
                            .init(color: .clear,                                   location: 0.72),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(isFocused ? 0.82 : 0.35), location: 0),
                                .init(color: .white.opacity(isFocused ? 0.30 : 0.12), location: 1),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: isFocused ? 1.5 : 1.0
                    )
            }
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .shadow(color: tintColor.opacity(isFocused ? 0.55 : 0), radius: 24)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(.plain)
    }

    private var tintColor: Color {
        isPrimary ? CinemaTheme.accentGold : CinemaTheme.peacock
    }

    private var buttonForeground: Color {
        if isPrimary {
            return isFocused ? .black : CinemaTheme.accentGold
        } else {
            return isFocused ? .white : .white.opacity(0.6)
        }
    }
}
