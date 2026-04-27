import SwiftUI

@main
struct CinemaScopeApp: App {

    // PINEAEnvironment owns auth state, routing, and the embedded EmbySession.
    // AppSettings owns UI preferences (ribbons, scope mode, colour mode, etc.)
    @StateObject private var env      = PINEAEnvironment()
    @StateObject private var settings = AppSettings.shared

    @State private var showSplash = true
    // Sprint 8: track scene phase for device heartbeat on foreground return.
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                // ── Routed content ─────────────────────────────────────────
                // All routing state lives in AppEnvironment (PINEAEnvironment).
                // No local state drives navigation — env is the single source of truth.
                routedContent
                    .animation(.easeInOut(duration: 0.35), value: env.isAuthenticated)
                    .animation(.easeInOut(duration: 0.35), value: env.hasLibraryConnection)
                    .animation(.easeInOut(duration: 0.35), value: env.hasCompletedOnboarding)

                // ── Splash overlay ─────────────────────────────────────────
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 5.6) {
                                withAnimation(.easeOut(duration: 0.6)) {
                                    showSplash = false
                                }
                            }
                        }
                }
            }
            .ignoresSafeArea()
            .animation(.easeOut(duration: 0.6), value: showSplash)
            // Sprint 8: heartbeat — re-register device each time the app returns to foreground.
            // Updates lastSeenAt on the backend. Non-blocking, silent on failure.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, env.isAuthenticated {
                    Task { await env.registerDevice() }
                }
            }
        }
    }

    // MARK: - Routing
    //
    // Flow:  Splash → Welcome → Login/Register → ServerSetup → Onboarding → Home
    // Gate:  All flags owned by AppEnvironment (PINEAEnvironment).

    @ViewBuilder
    private var routedContent: some View {
        if !env.isAuthenticated {
            // Not signed in → auth flow
            WelcomeView()
                .environmentObject(env)
                .transition(.opacity)

        } else if !env.hasLibraryConnection {
            // Signed in, no media library yet
            ServerSetupView()
                .environmentObject(env)
                .transition(.opacity)

        } else if !env.hasCompletedOnboarding {
            // First-run feature tour
            OnboardingView {
                withAnimation(.easeInOut(duration: 0.4)) {
                    env.hasCompletedOnboarding = true
                }
            }
            .environmentObject(settings)
            .transition(.opacity)

        } else {
            // Full app — env.embySession hydrated by didConnectLibrary()
            HomeView()
                .environmentObject(env)
                .environmentObject(env.embySession)
                .environmentObject(settings)
                .transition(.opacity)
        }
    }
}
