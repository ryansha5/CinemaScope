import SwiftUI

struct ServerEntryView: View {

    let onConnect: (EmbyServer) -> Void

    @State private var urlText   = ""
    @State private var isLoading = false
    @State private var error:    String? = nil

    enum Field { case urlField, connectButton }
    @FocusState private var focused: Field?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 48) {
                VStack(spacing: 12) {
                    Text("CinemaScope")
                        .font(.system(size: 52, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Connect to your Emby server")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.5))
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("Server URL")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))

                    TextField("http://192.168.1.10:8096", text: $urlText)
                        .font(.system(size: 24, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(24)
                        .background(.white.opacity(focused == .urlField ? 0.15 : 0.08),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .focused($focused, equals: .urlField)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(maxWidth: 700)
                        .onSubmit { focused = .connectButton }
                        .onKeyPress(.tab) {
                            focused = .connectButton
                            return .handled
                        }

                    if let error {
                        Text(error)
                            .font(.system(size: 18))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                }

                Button {
                    connect()
                } label: {
                    Group {
                        if isLoading {
                            ProgressView().progressViewStyle(.circular).tint(.black)
                        } else {
                            Text("Connect")
                                .font(.system(size: 22, weight: .semibold))
                        }
                    }
                    .frame(width: 200, height: 56)
                    .background(
                        focused == .connectButton ? Color.white : Color.white.opacity(0.85),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .foregroundStyle(.black)
                    .scaleEffect(focused == .connectButton ? 1.05 : 1.0)
                    .animation(.easeOut(duration: 0.15), value: focused)
                }
                .focused($focused, equals: .connectButton)
                .buttonStyle(.plain)
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                .onKeyPress(.tab) {
                    focused = .urlField
                    return .handled
                }
            }
            .padding(80)
        }
        .onAppear { focused = .urlField }
    }

    private func connect() {
        var raw = urlText.trimmingCharacters(in: .whitespaces)
        if !raw.hasPrefix("http://") && !raw.hasPrefix("https://") {
            raw = "http://" + raw
        }
        if raw.hasSuffix("/") { raw = String(raw.dropLast()) }

        guard URL(string: raw) != nil else {
            error = "That doesn't look like a valid URL."
            return
        }

        isLoading = true
        error     = nil

        Task {
            let server = EmbyServer(url: raw)
            do {
                _ = try await EmbyAPI.fetchUsers(server: server)
                isLoading = false
                onConnect(server)
            } catch {
                isLoading  = false
                self.error = "Couldn't reach server: \(error.localizedDescription)"
            }
        }
    }
}
