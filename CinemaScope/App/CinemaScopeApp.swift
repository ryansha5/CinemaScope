import SwiftUI

@main
struct CinemaScopeApp: App {

    @StateObject private var session  = EmbySession()
    @StateObject private var settings = AppSettings.shared

    // Splash is shown once per cold launch, regardless of auth state.
    // Caller fades it out at t = 5.6 s so it's fully gone by ~6.2 s total.
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                // ── App content (loads behind the splash) ───────────────────
                if session.isAuthenticated {
                    HomeView()
                        .environmentObject(session)
                        .environmentObject(settings)
                } else {
                    AuthFlowView()
                        .environmentObject(session)
                }

                // ── Splash overlay ──────────────────────────────────────────
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .onAppear {
                            // Dismiss after 5.6 s with a 0.6 s fade-out
                            DispatchQueue.main.asyncAfter(deadline: .now() + 5.6) {
                                withAnimation(.easeOut(duration: 0.6)) {
                                    showSplash = false
                                }
                            }
                        }
                }
            }
            .animation(.easeOut(duration: 0.6), value: showSplash)
        }
    }
}
