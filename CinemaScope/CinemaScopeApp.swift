import SwiftUI

@main
struct CinemaScopeApp: App {

    @StateObject private var session  = EmbySession()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            if session.isAuthenticated {
                HomeView()
                    .environmentObject(session)
                    .environmentObject(settings)
            } else {
                AuthFlowView()
                    .environmentObject(session)
            }
        }
    }
}
