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
        icon: "sparkles",
        title: "Welcome to PINEA",
        subtitle: "Your cinema. Elevated.",
        body: "Browse your entire movie and TV collection from your personal media server — beautifully presented, fast, and distraction-free.",
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

    @State private var currentPage   = 0
    @State private var contentVisible = false
    @FocusState private var focusedButton: OnboardingButton?

    enum OnboardingButton: Hashable { case next, skip }

    private var isLastPage: Bool { currentPage == onboardingPages.count - 1 }
    private var page: OnboardingPage { onboardingPages[currentPage] }

    var body: some View {
        ZStack {
            background

            HStack(spacing: 0) {
                // ── Left: PINEA brand sidebar (fixed across all pages) ──────
                brandSidebar
                    .frame(maxWidth: .infinity)

                // ── Right: page content + navigation ───────────────────────
                contentPanel
                    .frame(maxWidth: 620)
            }
            .opacity(contentVisible ? 1 : 0)
            .offset(y: contentVisible ? 0 : 28)
        }
        .animation(.easeOut(duration: 0.55), value: contentVisible)
        .onAppear {
            withAnimation(.easeOut(duration: 0.7).delay(0.15)) { contentVisible = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focusedButton = .next }
        }
    }

    // MARK: - Brand sidebar

    private var brandSidebar: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                Image("pinea_pinecone")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 360)
                    .shadow(color: CinemaTheme.gold.opacity(0.35), radius: 40, x: 0, y: 8)
                    .shadow(color: CinemaTheme.accentGold.opacity(0.18), radius: 80, x: 0, y: 0)

                Text("PINEA")
                    .font(.system(size: 72, weight: .regular, design: .serif))
                    .foregroundStyle(CinemaTheme.gold)
                    .tracking(12)

                Text("Your cinema. Elevated.")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white.opacity(0.40))
                    .tracking(1)
            }

            Spacer()
        }
        .padding(.horizontal, 80)
    }

    // MARK: - Content panel (right side)

    private var contentPanel: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 48) {
                // Page content — animates on page change
                pageContent
                    .id(currentPage)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .leading).combined(with: .opacity)
                    ))
                    .animation(.spring(response: 0.45, dampingFraction: 0.85), value: currentPage)

                // Page indicators + buttons
                VStack(alignment: .leading, spacing: 28) {
                    pageIndicators

                    HStack(spacing: 20) {
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
            }

            Spacer()
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 60)
        .background(.ultraThinMaterial.opacity(0.22))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(LinearGradient(
                    colors: [CinemaTheme.gold.opacity(0.28), CinemaTheme.peacock.opacity(0.15)],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(width: 1)
        }
    }

    // MARK: - Page content

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Icon circle
            ZStack {
                Circle()
                    .fill(page.accent.opacity(0.14))
                    .frame(width: 80, height: 80)
                Circle()
                    .strokeBorder(page.accent.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 80, height: 80)
                Image(systemName: page.icon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(page.accent)
            }

            // Title + subtitle + body
            VStack(alignment: .leading, spacing: 12) {
                Text(page.title)
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.white)

                Text(page.subtitle)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(page.accent)

                Text(page.body)
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.60))
                    .lineSpacing(5)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Page indicators

    private var pageIndicators: some View {
        HStack(spacing: 8) {
            ForEach(onboardingPages) { p in
                Capsule()
                    .fill(currentPage == p.id
                          ? onboardingPages[currentPage].accent
                          : .white.opacity(0.22))
                    .frame(width: currentPage == p.id ? 28 : 8, height: 8)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentPage)
            }
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            CinemaTheme.backgroundGradient(.dark)
            CinemaTheme.radialOverlay(.dark)
        }
        .ignoresSafeArea()
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
                Text(label)
                    .font(.system(size: isPrimary ? 20 : 18,
                                  weight: isPrimary ? .semibold : .medium))
                Image(systemName: icon)
                    .font(.system(size: isPrimary ? 17 : 15,
                                  weight: isPrimary ? .semibold : .medium))
            }
            .foregroundStyle(buttonForeground)
            .padding(.horizontal, isPrimary ? 36 : 28)
            .padding(.vertical, isPrimary ? 18 : 14)
            .background {
                ZStack {
                    if isPrimary {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(isFocused ? CinemaTheme.accentGold : CinemaTheme.accentGold.opacity(0.15))
                    } else {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(.white.opacity(isFocused ? 0.14 : 0.06))
                    }
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            isPrimary
                                ? (isFocused ? Color.clear : CinemaTheme.accentGold.opacity(0.4))
                                : Color.white.opacity(isFocused ? 0.28 : 0.12),
                            lineWidth: 1
                        )
                }
            }
            .scaleEffect(isFocused ? 1.04 : 1.0)
            .shadow(color: isPrimary && isFocused ? CinemaTheme.accentGold.opacity(0.45) : .clear,
                    radius: 20, x: 0, y: 6)
            .animation(.spring(response: 0.25, dampingFraction: 0.72), value: isFocused)
        }
        .focusRingFree()
    }

    private var buttonForeground: Color {
        if isPrimary {
            return isFocused ? .black : CinemaTheme.accentGold
        } else {
            return isFocused ? .white : .white.opacity(0.55)
        }
    }
}
