import SwiftUI

/// Manages the three-step auth flow:
/// ServerEntry → UserPicker → Login → HomeView
struct AuthFlowView: View {

    @EnvironmentObject var session: EmbySession

    enum Step {
        case server
        case userPicker(EmbyServer)
        case login(EmbyServer, EmbyUser)
    }

    @State private var step: Step = .server

    var body: some View {
        Group {
            switch step {
            case .server:
                ServerEntryView { server in
                    step = .userPicker(server)
                }

            case .userPicker(let server):
                UserPickerView(
                    server:   server,
                    onSelect: { user in step = .login(server, user) },
                    onBack:   { step = .server }
                )

            case .login(let server, let user):
                LoginView(
                    server:  server,
                    user:    user,
                    onLogin: { token in
                        session.login(server: server, user: user, token: token)
                    },
                    onBack: { step = .userPicker(server) }
                )
            }
        }
        .animation(.easeInOut(duration: 0.25), value: stepID)
    }

    private var stepID: Int {
        switch step {
        case .server:       return 0
        case .userPicker:   return 1
        case .login:        return 2
        }
    }
}
