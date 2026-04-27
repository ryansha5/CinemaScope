import SwiftUI

// MARK: - AuthFlowView (compatibility shim)
//
// The Emby-direct auth flow (ServerEntry → UserPicker → Login) was replaced by
// WelcomeView / LoginView / RegisterView / ServerSetupView driven by AppEnvironment
// (PINEAEnvironment).  This shim forwards any remaining references so they compile.

struct AuthFlowView: View {
    @EnvironmentObject var env: AppEnvironment
    var body: some View {
        WelcomeView().environmentObject(env)
    }
}
