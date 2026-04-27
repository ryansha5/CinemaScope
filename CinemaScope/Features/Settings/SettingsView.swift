import SwiftUI

// MARK: - Settings Section

enum SettingsSection: String, CaseIterable, Identifiable {
    case homeScreen  = "Home Screen"
    case playback    = "Playback"
    case startup     = "Startup"
    case server      = "Server"
    case diagnostics = "Diagnostics"
    case playerLab   = "PlayerLab"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .homeScreen:  return "rectangle.grid.1x2.fill"
        case .playback:    return "play.circle.fill"
        case .startup:     return "house.fill"
        case .server:      return "server.rack"
        case .diagnostics: return "stethoscope"
        case .playerLab:   return "skew"
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {

    @EnvironmentObject var env:      PINEAEnvironment
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var session:  EmbySession
    let availableGenres: [String]
    let onDismiss: () -> Void

    @State private var selectedSection:   SettingsSection = .homeScreen
    @State private var showAddRibbon      = false
    @State private var savedFeedback      = false
    @State private var showReconnectSheet = false

    var body: some View {
        ZStack {
            CinemaBackground()

            HStack(alignment: .top, spacing: 0) {
                settingsSidebar
                    .focusSection()

                contentPanel
                    .focusSection()
            }
        }
        .sheet(isPresented: $showAddRibbon) {
            AddRibbonSheet(
                availableGenres: availableGenres,
                existingRibbons: settings.homeRibbons,
                colorMode:       settings.colorMode,
                onAdd: { ribbon in
                    settings.addRibbon(ribbon)
                    showAddRibbon = false
                },
                onDismiss: { showAddRibbon = false }
            )
        }
        .sheet(isPresented: $showReconnectSheet) {
            ServerReconnectSheet(
                session:   session,
                colorMode: settings.colorMode,
                onConnect: { server, user, token in
                    env.didConnectLibrary(server: server, user: user, token: token)
                    showReconnectSheet = false
                },
                onDismiss: { showReconnectSheet = false }
            )
            .environmentObject(env)
        }
    }

    // MARK: - Sidebar

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(CinemaTheme.primary(settings.colorMode))
                .padding(.bottom, 20)

            ForEach(SettingsSection.allCases) { section in
                SidebarNavButton(
                    icon:      section.icon,
                    label:     section.rawValue,
                    isActive:  selectedSection == section,
                    colorMode: settings.colorMode
                ) { selectedSection = section }
            }

            Spacer()

            Button {
                savedFeedback = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    savedFeedback = false
                    onDismiss()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: savedFeedback ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 16))
                    Text(savedFeedback ? "Saved!" : "Save & Exit")
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(savedFeedback ? CinemaTheme.accentGold : CinemaTheme.primary(settings.colorMode))
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    ZStack {
                        (savedFeedback ? CinemaTheme.accentGold : CinemaTheme.peacock)
                            .opacity(savedFeedback ? 0.15 : 0.35)
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.30), location: 0),
                                .init(color: .clear,               location: 0.55),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.55), location: 0),
                                    .init(color: .white.opacity(0.15), location: 1),
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .animation(.easeInOut(duration: 0.2), value: savedFeedback)
            }
            .focusRingFree()
            .padding(.bottom, 8)

            BackButton(colorMode: settings.colorMode, scopeMode: false, onTap: onDismiss)
        }
        .padding(32)
        .frame(width: 280)
        .background(CinemaTheme.peacockDeep.opacity(0.6))
        .overlay(alignment: .trailing) {
            Rectangle().fill(CinemaTheme.peacockLight.opacity(0.15)).frame(width: 1)
        }
    }

    // MARK: - Content panel (switches per section)

    @ViewBuilder
    private var contentPanel: some View {
        switch selectedSection {
        case .homeScreen:  homeScreenPanel
        case .playback:    playbackPanel
        case .startup:     startupPanel
        case .server:      serverPanel
        case .diagnostics: diagnosticsPanel
        case .playerLab:   playerLabPanel
        }
    }

    // MARK: - Home Screen panel

    private var homeScreenPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                panelHeader(
                    title:    "Home Screen",
                    subtitle: "Choose and arrange the rows that appear on your home screen."
                ) {
                    HStack(spacing: 16) {
                        SettingsButton(icon: "plus.circle.fill", label: "Add Row", style: .accent, colorMode: settings.colorMode) {
                            showAddRibbon = true
                        }
                        SettingsButton(icon: "arrow.counterclockwise", label: "Reset", style: .ghost, colorMode: settings.colorMode) {
                            settings.resetToDefaults()
                        }
                    }
                }

                settingsDivider
                sectionTitle("Appearance")

                HStack(spacing: 16) {
                    ForEach(ColorMode.allCases) { mode in
                        ColorModeCard(mode: mode, isActive: settings.colorMode == mode, colorMode: settings.colorMode) {
                            settings.colorMode = mode
                        }
                    }
                    Spacer()
                }
                .padding(.bottom, 8)

                settingsDivider
                sectionTitle("Experimental")

                toggleRow(
                    icon:    "sparkles.rectangle.stack.fill",
                    title:   "HyperView Backdrops",
                    detail:  "When browsing a content row, fills the top of the screen with full-bleed artwork and metadata for the focused title. Still being refined — off by default.",
                    value:   $settings.hyperViewEnabled
                )

                settingsDivider
                sectionTitle("Rows")

                VStack(spacing: 12) {
                    ForEach(settings.homeRibbons) { ribbon in
                        RibbonRow(
                            ribbon:     ribbon,
                            isFirst:    ribbon.id == settings.homeRibbons.first?.id,
                            isLast:     ribbon.id == settings.homeRibbons.last?.id,
                            colorMode:  settings.colorMode,
                            onToggle:   { settings.toggleRibbon(ribbon) },
                            onMoveUp:   { settings.moveUp(ribbon) },
                            onMoveDown: { settings.moveDown(ribbon) },
                            onRemove:   { settings.removeRibbon(ribbon) }
                        )
                    }
                }
                .focusSection()
            }
            .padding(48)
        }
    }

    // MARK: - Playback panel

    private var playbackPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                panelHeader(
                    title:    "Playback",
                    subtitle: "Control how the app behaves during and between episodes."
                )

                settingsDivider
                sectionTitle("Episodes")

                toggleRow(
                    icon:    "play.circle.fill",
                    title:   "Autoplay Next Episode",
                    detail:  "When an episode ends, a countdown will appear and the next episode will start automatically.",
                    value:   $settings.autoplayNextEpisode
                )

                settingsDivider
                sectionTitle("Audio & Subtitles")

                toggleRow(
                    icon:    "captions.bubble.fill",
                    title:   "Show Subtitles by Default",
                    detail:  "When a subtitle track is available, enable it automatically on playback start.",
                    value:   $settings.subtitlesEnabled
                )

                languageRow(
                    icon:    "waveform",
                    title:   "Preferred Audio Language",
                    detail:  "Language code for audio track selection (e.g. \"en\", \"fr\"). Leave blank to use your server default.",
                    value:   $settings.preferredAudioLanguage
                )
            }
            .padding(48)
        }
    }

    // MARK: - Startup panel

    private var startupPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                panelHeader(
                    title:    "Startup",
                    subtitle: "Choose where the app takes you when it first opens."
                )

                settingsDivider
                sectionTitle("Opening Screen")

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3),
                    spacing: 16
                ) {
                    ForEach(NavTab.allCases) { tab in
                        StartupTabCard(
                            tab:       tab,
                            isActive:  settings.startupTab == tab,
                            colorMode: settings.colorMode
                        ) { settings.startupTab = tab }
                    }
                }
                .focusSection()
            }
            .padding(48)
        }
    }

    // MARK: - Diagnostics panel

    private var diagnosticsPanel: some View {
        DiagnosticsPanel(session: session, colorMode: settings.colorMode)
    }

    // MARK: - PlayerLab panel

    private var playerLabPanel: some View {
        PlayerLabPanel(
            colorMode:        settings.colorMode,
            engineMode:       $settings.playbackEngineMode,
            firstFrameMode:   $settings.playerLabFirstFrameMode,
            persistedPath:    $settings.playerLabLastPath
        )
    }

    // MARK: - Server panel

    private var serverPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                panelHeader(
                    title:    "Server",
                    subtitle: "Manage your media server connection and account."
                )

                settingsDivider
                sectionTitle("Current Connection")

                // Server details card
                VStack(spacing: 0) {
                    serverDetailRow(label: "Server URL", value: session.server?.url ?? "Not connected")
                    serverDetailRow(label: "Emby User",  value: session.user?.name  ?? "—")
                    serverDetailRow(label: "Status",
                                   value: session.isAuthenticated ? "Connected" : "Disconnected",
                                   valueColor: session.isAuthenticated ? CinemaTheme.teal : .red.opacity(0.8))
                }
                .background(CinemaTheme.peacockDeep.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(CinemaTheme.peacockLight.opacity(0.15), lineWidth: 1)
                }

                settingsDivider
                sectionTitle("Actions")

                // Reconnect button
                HStack(spacing: 16) {
                    SettingsButton(
                        icon:      "arrow.triangle.2.circlepath",
                        label:     "Change Server / User",
                        style:     .accent,
                        colorMode: settings.colorMode
                    ) { showReconnectSheet = true }

                    SettingsButton(
                        icon:      "rectangle.portrait.and.arrow.left",
                        label:     "Sign Out of PINEA",
                        style:     .destructive,
                        colorMode: settings.colorMode
                    ) { env.signOut() }
                }

                settingsDivider

                // Info note
                HStack(spacing: 14) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(CinemaTheme.peacockLight.opacity(0.6))
                    Text("Signing out removes your PINEA session. Your Emby library and watch history are unaffected and will be available when you sign back in.")
                        .font(.system(size: 15))
                        .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                        .lineSpacing(4)
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .background(CinemaTheme.peacockDeep.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(48)
        }
    }

    private func serverDetailRow(label: String, value: String, valueColor: Color? = nil) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(CinemaTheme.secondary(settings.colorMode))
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.system(size: 16))
                .foregroundStyle(valueColor ?? CinemaTheme.primary(settings.colorMode))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CinemaTheme.peacockLight.opacity(0.1))
                .frame(height: 1)
                .padding(.horizontal, 20)
        }
    }

    // MARK: - Shared panel helpers

    private func panelHeader(title: String, subtitle: String, @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(CinemaTheme.primary(settings.colorMode))
                Text(subtitle)
                    .font(.system(size: 18))
                    .foregroundStyle(CinemaTheme.secondary(settings.colorMode))
            }
            Spacer()
            trailing()
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(CinemaTheme.primary(settings.colorMode))
            .padding(.bottom, 4)
    }

    private var settingsDivider: some View {
        Divider()
            .background(CinemaTheme.peacockLight.opacity(0.2))
            .padding(.vertical, 8)
    }

    // Toggle row (icon + title + detail + toggle)
    private func toggleRow(icon: String, title: String, detail: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(CinemaTheme.accentGold)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(CinemaTheme.primary(settings.colorMode))
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                    .lineLimit(2)
                    .frame(maxWidth: 560, alignment: .leading)
            }

            Spacer()

            SettingsToggle(isOn: value, colorMode: settings.colorMode)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(CinemaTheme.peacockDeep.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(CinemaTheme.peacockLight.opacity(0.15), lineWidth: 1)
        }
    }

    // Language code text-input row
    private func languageRow(icon: String, title: String, detail: String, value: Binding<String>) -> some View {
        HStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(CinemaTheme.accentGold)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(CinemaTheme.primary(settings.colorMode))
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                    .lineLimit(2)
                    .frame(maxWidth: 480, alignment: .leading)
            }

            Spacer()

            TextField("e.g. en", text: value)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(CinemaTheme.primary(settings.colorMode))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(width: 80)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(CinemaTheme.peacockDeep.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(CinemaTheme.peacockLight.opacity(0.15), lineWidth: 1)
        }
    }
}

// MARK: - SidebarNavButton

private struct SidebarNavButton: View {
    let icon:      String
    let label:     String
    let isActive:  Bool
    let colorMode: ColorMode
    let onTap:     () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: isActive ? .semibold : .regular))
                    .frame(width: 22)
                Text(label)
                    .font(.system(size: 17, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(
                isActive  ? CinemaTheme.navActive(colorMode) :
                isFocused ? CinemaTheme.primary(colorMode)   :
                            CinemaTheme.secondary(colorMode)
            )
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background {
                ZStack {
                    (isActive ? CinemaTheme.navActive(colorMode) : Color.white)
                        .opacity(
                            isActive && isFocused ? 0.22 :
                            isActive              ? 0.13 :
                            isFocused             ? 0.13 : 0
                        )
                    if isActive || isFocused {
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(isFocused ? 0.40 : 0.16), location: 0),
                                .init(color: .clear,                                   location: 0.6),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(isActive || isFocused ? (isFocused ? 0.65 : 0.35) : 0), location: 0),
                                .init(color: .white.opacity(isActive || isFocused ? (isFocused ? 0.20 : 0.10) : 0), location: 1),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: (isActive || isFocused) ? 1.5 : 0
                    )
            }
            .scaleEffect(isFocused ? 1.02 : 1.0, anchor: .leading)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isFocused)
        }
        .focusRingFree()
        .focused($isFocused)
    }
}

// MARK: - SettingsToggle

struct SettingsToggle: View {
    @Binding var isOn: Bool
    let colorMode: ColorMode
    @FocusState private var isFocused: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isOn ? CinemaTheme.accentGold : CinemaTheme.tertiary(colorMode))
                Text(isOn ? "On" : "Off")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isOn ? CinemaTheme.accentGold : CinemaTheme.tertiary(colorMode))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background {
                ZStack {
                    (isOn ? CinemaTheme.accentGold : Color.white)
                        .opacity(isFocused ? 0.18 : (isOn ? 0.10 : 0.06))
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(isFocused ? 0.35 : 0.14), location: 0),
                            .init(color: .clear,                                   location: 0.6),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(isFocused ? 0.60 : (isOn ? 0.30 : 0.15)), location: 0),
                                .init(color: .white.opacity(isFocused ? 0.18 : 0.06), location: 1),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: isFocused ? 1.5 : 1
                    )
            }
            .animation(.easeOut(duration: 0.15), value: isOn)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isFocused)
        }
        .focusRingFree()
        .focused($isFocused)
    }
}

// MARK: - StartupTabCard

private struct StartupTabCard: View {
    let tab:       NavTab
    let isActive:  Bool
    let colorMode: ColorMode
    let onTap:     () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            isActive
                                ? CinemaTheme.accentGold.opacity(0.18)
                                : CinemaTheme.peacockDeep.opacity(0.5)
                        )
                        .frame(height: 70)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(
                                    isActive || isFocused
                                        ? (isActive ? CinemaTheme.accentGold : CinemaTheme.peacock)
                                        : Color.white.opacity(0.12),
                                    lineWidth: isActive ? 2 : 1
                                )
                        }
                    Image(systemName: tab.icon)
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(isActive ? CinemaTheme.accentGold : CinemaTheme.secondary(colorMode))
                }
                .scaleEffect(isFocused ? 1.04 : 1.0)
                .shadow(color: isFocused ? CinemaTheme.peacock.opacity(0.45) : .clear, radius: 14)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)

                HStack(spacing: 6) {
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(CinemaTheme.accentGold)
                    }
                    Text(tab.rawValue)
                        .font(.system(size: 15, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? CinemaTheme.primary(colorMode) : CinemaTheme.secondary(colorMode))
                }
            }
        }
        .focusRingFree()
        .focused($isFocused)
    }
}

// MARK: - DiagnosticsPanel

private struct DiagnosticsPanel: View {
    let session:   EmbySession
    let colorMode: ColorMode

    @State private var systemInfo:    EmbySystemInfo? = nil
    @State private var isLoading:     Bool            = false
    @State private var pingResult:    String?         = nil
    @State private var pingMs:        Int?            = nil
    @State private var lastChecked:   Date?           = nil


    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text("Diagnostics")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(CinemaTheme.primary(colorMode))
                    Text("Check your server connection and app status.")
                        .font(.system(size: 18))
                        .foregroundStyle(CinemaTheme.secondary(colorMode))
                }

                Divider().background(CinemaTheme.peacockLight.opacity(0.2)).padding(.vertical, 8)

                // App info
                diagnosticsSection(title: "App") {
                    diagRow(label: "Version", value: appVersion)
                    diagRow(label: "Device",  value: UIDevice.current.model)
                }

                Divider().background(CinemaTheme.peacockLight.opacity(0.2)).padding(.vertical, 8)

                // Server info
                diagnosticsSection(title: "Server") {
                    if let url = session.server?.url {
                        diagRow(label: "Address", value: url)
                    }
                    if let info = systemInfo {
                        diagRow(label: "Name",    value: info.serverName    ?? "—")
                        diagRow(label: "Version", value: info.version       ?? "—")
                        diagRow(label: "OS",      value: info.operatingSystem ?? "—")
                    }
                    if let ms = pingMs {
                        diagRow(label: "Ping",    value: "\(ms) ms", highlight: ms < 100 ? .green : (ms < 500 ? .yellow : .red))
                    }
                    if let err = pingResult {
                        diagRow(label: "Status",  value: err, highlight: .red)
                    }
                    if let date = lastChecked {
                        diagRow(label: "Checked", value: date.formatted(date: .omitted, time: .shortened))
                    }
                }

                // Check connection button
                HStack(spacing: 16) {
                    SettingsButton(
                        icon:      isLoading ? "arrow.triangle.2.circlepath" : "antenna.radiowaves.left.and.right",
                        label:     isLoading ? "Checking…" : "Check Connection",
                        style:     .accent,
                        colorMode: colorMode
                    ) { Task { await checkConnection() } }
                    .disabled(isLoading)

                    if systemInfo != nil || pingResult != nil {
                        SettingsButton(icon: "arrow.counterclockwise", label: "Clear", style: .ghost, colorMode: colorMode) {
                            systemInfo  = nil
                            pingResult  = nil
                            pingMs      = nil
                            lastChecked = nil
                        }
                    }
                }

            }
            .padding(48)
        }
    }

    private func checkConnection() async {
        guard let server = session.server, let token = session.token else { return }
        isLoading   = true
        pingResult  = nil
        pingMs      = nil
        systemInfo  = nil

        let start = Date()
        do {
            let info  = try await EmbyAPI.fetchSystemInfo(server: server, token: token)
            let ms    = Int(Date().timeIntervalSince(start) * 1000)
            systemInfo  = info
            pingMs      = ms
            lastChecked = Date()
        } catch {
            pingResult  = error.localizedDescription
            lastChecked = Date()
        }
        isLoading = false
    }

    @ViewBuilder
    private func diagnosticsSection(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(CinemaTheme.primary(colorMode))
            VStack(spacing: 0) {
                content()
            }
            .background(CinemaTheme.peacockDeep.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(CinemaTheme.peacockLight.opacity(0.15), lineWidth: 1)
            }
        }
    }

    private func diagRow(label: String, value: String, highlight: Color? = nil) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(CinemaTheme.secondary(colorMode))
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(size: 16, design: .monospaced))
                .foregroundStyle(highlight ?? CinemaTheme.primary(colorMode))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CinemaTheme.peacockLight.opacity(0.1))
                .frame(height: 1)
                .padding(.horizontal, 20)
        }
    }
}

// MARK: - PlayerLabPanel

private struct PlayerLabPanel: View {
    let colorMode:     ColorMode
    @Binding var engineMode:    PlaybackEngineMode  // Sprint 43: replaces old isEnabled Bool
    @Binding var firstFrameMode: Bool               // Sprint 44: debug — feed only the first keyframe
    @Binding var persistedPath: String

    @State private var labFilePath:   String = ""
    @State private var labIsRunning:  Bool   = false
    @State private var labLog:        String = ""
    @State private var labSuccess:    Bool?  = nil
    @State private var labShowPlayer: Bool   = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {

                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text("PlayerLab")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(CinemaTheme.primary(colorMode))
                    Text("Custom demux + decode engine for MKV/MP4. H.264/HEVC via VideoToolbox; AAC/AC3/EAC3/TrueHD audio.")
                        .font(.system(size: 18))
                        .foregroundStyle(CinemaTheme.secondary(colorMode))
                }

                Divider().background(CinemaTheme.peacockLight.opacity(0.2)).padding(.vertical, 4)

                // Playback Engine Mode selector — three-way choice
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 16) {
                        Image(systemName: "switch.2")
                            .font(.system(size: 22))
                            .foregroundStyle(CinemaTheme.accentGold)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Playback Engine")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(CinemaTheme.primary(colorMode))
                            Text(engineMode == .avPlayerOnly
                                    ? "AVPlayer handles all playback — PlayerLab is bypassed entirely."
                                 : engineMode == .playerLabPreferred
                                    ? "PlayerLab plays compatible files; AVPlayer handles the rest and all fallbacks."
                                    : "PlayerLab is forced for all files. Expect failures on unsupported content.")
                                .font(.system(size: 14))
                                .foregroundStyle(CinemaTheme.tertiary(colorMode))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 24).padding(.top, 20)

                    // Mode buttons
                    HStack(spacing: 12) {
                        ForEach(PlaybackEngineMode.allCases, id: \.rawValue) { mode in
                            let isSelected = engineMode == mode
                            Button {
                                engineMode = mode
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: mode == .avPlayerOnly ? "play.tv.fill"
                                                     : mode == .playerLabPreferred ? "switch.2"
                                                     : "flask.fill")
                                        .font(.system(size: 20))
                                    Text(mode.shortLabel)
                                        .font(.system(size: 12, weight: .semibold))
                                        .multilineTextAlignment(.center)
                                }
                                .padding(.vertical, 14)
                                .padding(.horizontal, 16)
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(isSelected ? Color.black : CinemaTheme.primary(colorMode))
                                .background(isSelected ? CinemaTheme.accentGold : CinemaTheme.peacockDeep.opacity(0.5),
                                            in: RoundedRectangle(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(isSelected
                                                      ? CinemaTheme.accentGold
                                                      : CinemaTheme.peacockLight.opacity(0.2), lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 20)
                }
                .background(CinemaTheme.peacockDeep.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(CinemaTheme.peacockLight.opacity(0.15), lineWidth: 1)
                }

                // Restore-baseline hint when AVPlayerOnly is selected
                if engineMode == .avPlayerOnly {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(CinemaTheme.accentGold)
                        Text("AVPlayer Only is active. All content plays through the standard AVPlayer path. Use this to restore a known-good baseline before debugging PlayerLab.")
                            .font(.system(size: 14))
                            .foregroundStyle(CinemaTheme.secondary(colorMode))
                    }
                    .padding(16)
                    .background(CinemaTheme.peacockDeep.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                }

                // First Frame Mode toggle (Sprint 44)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 20) {
                        Image(systemName: "photo.on.rectangle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(firstFrameMode ? CinemaTheme.accentGold : CinemaTheme.secondary(colorMode))
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("First Frame Mode")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(CinemaTheme.primary(colorMode))
                            Text(firstFrameMode
                                 ? "PlayerLab will feed exactly one keyframe and stop. Use to prove the MKV→HEVC→displayLayer pipeline before enabling continuous playback."
                                 : "Normal continuous playback. Disable First Frame Mode for regular use.")
                                .font(.system(size: 14))
                                .foregroundStyle(CinemaTheme.tertiary(colorMode))
                        }
                        Spacer()
                        Toggle("", isOn: $firstFrameMode)
                            .toggleStyle(.switch)
                            .tint(CinemaTheme.accentGold)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 24).padding(.vertical, 20)
                }
                .background(firstFrameMode
                             ? CinemaTheme.accentGold.opacity(0.08)
                             : CinemaTheme.peacockDeep.opacity(0.4),
                             in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(firstFrameMode
                                      ? CinemaTheme.accentGold.opacity(0.35)
                                      : CinemaTheme.peacockLight.opacity(0.15), lineWidth: 1)
                }

                // Path input card
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 20) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(CinemaTheme.accentGold)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("MP4 File Path")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(CinemaTheme.primary(colorMode))
                            Text("Local H.264 or HEVC MP4. Path persists across sessions.")
                                .font(.system(size: 14))
                                .foregroundStyle(CinemaTheme.tertiary(colorMode))
                        }
                        Spacer()
                        TextField("/path/to/sample.mp4", text: $labFilePath)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundStyle(CinemaTheme.primary(colorMode))
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .frame(width: 380)
                            .onChange(of: labFilePath) { newPath in
                                persistedPath = newPath   // persist to AppSettings
                            }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 20)
                }
                .background(CinemaTheme.peacockDeep.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(CinemaTheme.peacockLight.opacity(0.15), lineWidth: 1)
                }

                // Run / Clear / Watch buttons
                HStack(spacing: 16) {
                    SettingsButton(
                        icon:      labIsRunning ? "arrow.triangle.2.circlepath" : "play.circle.fill",
                        label:     labIsRunning ? "Running…" : "Run Pipeline Test",
                        style:     .accent,
                        colorMode: colorMode
                    ) {
                        Task { await runTest() }
                    }
                    .disabled(labIsRunning || labFilePath.trimmingCharacters(in: .whitespaces).isEmpty)

                    // Watch Video — opens PlayerLabPlayerView (Sprints 10–14)
                    SettingsButton(
                        icon:      "tv.fill",
                        label:     "Watch Video",
                        style:     engineMode.playerLabEnabled ? .accent : .ghost,
                        colorMode: colorMode
                    ) {
                        labShowPlayer = true
                    }
                    .disabled(labFilePath.trimmingCharacters(in: .whitespaces).isEmpty)

                    if !labLog.isEmpty {
                        SettingsButton(icon: "arrow.counterclockwise", label: "Clear", style: .ghost, colorMode: colorMode) {
                            labLog     = ""
                            labSuccess = nil
                        }
                    }
                }
                .fullScreenCover(isPresented: $labShowPlayer) {
                    PlayerLabPlayerView(
                        url: URL(fileURLWithPath: labFilePath.trimmingCharacters(in: .whitespaces))
                    )
                }
                .onAppear {
                    // Restore last used path from AppSettings
                    if labFilePath.isEmpty && !persistedPath.isEmpty {
                        labFilePath = persistedPath
                    }
                }

                // Result status
                if let success = labSuccess {
                    HStack(spacing: 12) {
                        Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(success ? .green : .red)
                        Text(success
                             ? "VideoToolbox decoded frames — pipeline working ✓"
                             : "Pipeline test failed — see log below")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(success ? .green : .red)
                    }
                    .padding(.horizontal, 24).padding(.vertical, 18)
                    .background(
                        (success ? Color.green : Color.red).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder((success ? Color.green : Color.red).opacity(0.25), lineWidth: 1)
                    }
                }

                // Log output — show the last 40 lines so the newest output
                // (step 5 decode results) is always visible without needing to
                // scroll an inner view on tvOS.
                if !labLog.isEmpty {
                    let tail: String = {
                        let lines = labLog.components(separatedBy: "\n")
                        let slice = lines.suffix(40)
                        return slice.joined(separator: "\n")
                    }()
                    VStack(alignment: .leading, spacing: 8) {
                        let total = labLog.components(separatedBy: "\n").count
                        Text("Log (last 40 of \(total) lines)")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(CinemaTheme.secondary(colorMode))
                        Text(tail)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(CinemaTheme.secondary(colorMode))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(CinemaTheme.peacockDeep.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(CinemaTheme.peacockLight.opacity(0.15), lineWidth: 1)
                            }
                    }
                }
            }
            .padding(48)
        }
    }

    private func runTest() async {
        let path = labFilePath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }
        labIsRunning = true
        labLog       = ""
        labSuccess   = nil

        let url     = URL(fileURLWithPath: path)
        let harness = PlayerLabHarness()
        await harness.runTest(mp4: url, packetCount: 10)

        labLog     = harness.formattedLog
        labSuccess = harness.log.contains { $0.message.contains("Sprint 9 milestone") }
        labIsRunning = false
    }

    // Row helper — icon + title + subtitle + arbitrary trailing control
    @ViewBuilder
    private func settingsRow<Trailing: View>(
        icon:     String,
        title:    String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(CinemaTheme.accentGold)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(CinemaTheme.primary(colorMode))
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(CinemaTheme.tertiary(colorMode))
                    .lineLimit(2)
                    .frame(maxWidth: 560, alignment: .leading)
            }

            Spacer()

            trailing()
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(CinemaTheme.peacockDeep.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(CinemaTheme.peacockLight.opacity(0.15), lineWidth: 1)
        }
    }
}

// MARK: - RibbonRow

struct RibbonRow: View {
    let ribbon:     HomeRibbon
    let isFirst:    Bool
    let isLast:     Bool
    let colorMode:  ColorMode
    let onToggle:   () -> Void
    let onMoveUp:   () -> Void
    let onMoveDown: () -> Void
    let onRemove:   () -> Void

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: ribbon.type.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(ribbon.enabled ? CinemaTheme.accentGold : CinemaTheme.tertiary(colorMode))
                    .frame(width: 28)
                Text(ribbon.type.displayName)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(ribbon.enabled ? CinemaTheme.primary(colorMode) : CinemaTheme.tertiary(colorMode))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                SettingsButton(
                    icon:      ribbon.enabled ? "eye.fill" : "eye.slash",
                    label:     ribbon.enabled ? "Visible" : "Hidden",
                    style:     ribbon.enabled ? .accent : .ghost,
                    colorMode: colorMode
                ) { onToggle() }

                SettingsButton(icon: "chevron.up",   label: "", style: .ghost, colorMode: colorMode) { onMoveUp() }
                    .disabled(isFirst).opacity(isFirst ? 0.3 : 1)
                    .accessibilityLabel("Move \(ribbon.type.displayName) up")

                SettingsButton(icon: "chevron.down", label: "", style: .ghost, colorMode: colorMode) { onMoveDown() }
                    .disabled(isLast).opacity(isLast ? 0.3 : 1)
                    .accessibilityLabel("Move \(ribbon.type.displayName) down")

                if case .genre = ribbon.type {
                    SettingsButton(icon: "trash", label: "", style: .destructive, colorMode: colorMode) { onRemove() }
                        .accessibilityLabel("Remove \(ribbon.type.displayName) row")
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(CinemaTheme.peacockDeep.opacity(ribbon.enabled ? 0.5 : 0.25), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    ribbon.enabled
                        ? CinemaTheme.peacockLight.opacity(0.2)
                        : CinemaTheme.peacockLight.opacity(0.08),
                    lineWidth: 1)
        }
    }
}

// MARK: - AddRibbonSheet

struct AddRibbonSheet: View {

    let availableGenres:  [String]
    let existingRibbons:  [HomeRibbon]
    let colorMode:        ColorMode
    let onAdd:            (HomeRibbon) -> Void
    let onDismiss:        () -> Void

    @State private var selectedItemType = "Movie"
    @FocusState private var focusedGenre: String?

    private var unusedGenres: [String] {
        availableGenres.filter { genre in
            !existingRibbons.contains(where: {
                if case .genre(let n, _) = $0.type { return n == genre }
                return false
            })
        }
    }

    var body: some View {
        ZStack {
            CinemaBackground()
            VStack(alignment: .leading, spacing: 32) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add a Row")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(CinemaTheme.primary(colorMode))
                        Text("Pick a genre to add as a home screen row.")
                            .font(.system(size: 18))
                            .foregroundStyle(CinemaTheme.secondary(colorMode))
                    }
                    Spacer()
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(CinemaTheme.tertiary(colorMode))
                    }
                    .focusRingFree()
                }

                HStack(spacing: 12) {
                    Text("Content type:")
                        .font(.system(size: 18))
                        .foregroundStyle(CinemaTheme.secondary(colorMode))
                    ForEach(["Movie", "Series"], id: \.self) { type in
                        SettingsButton(
                            icon:  type == "Movie" ? "film" : "tv",
                            label: type == "Movie" ? "Movies" : "TV Shows",
                            style: selectedItemType == type ? .accent : .ghost,
                            colorMode: colorMode
                        ) { selectedItemType = type }
                    }
                }

                if unusedGenres.isEmpty {
                    Text("All genres already added.")
                        .font(.system(size: 18))
                        .foregroundStyle(CinemaTheme.tertiary(colorMode))
                } else {
                    let cols = Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: cols, spacing: 16) {
                            ForEach(unusedGenres, id: \.self) { genre in
                                GenrePickerCell(genre: genre, isFocused: focusedGenre == genre, colorMode: colorMode) {
                                    onAdd(HomeRibbon(type: .genre(name: genre, itemType: selectedItemType)))
                                }
                                .focused($focusedGenre, equals: genre)
                            }
                        }
                    }
                }
            }
            .padding(60)
        }
    }
}

struct GenrePickerCell: View {
    let genre:     String
    let isFocused: Bool
    let colorMode: ColorMode
    let onTap:     () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(genre)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isFocused ? .black : CinemaTheme.primary(colorMode))
                .padding(.horizontal, 20).padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(
                    isFocused ? CinemaTheme.accentGold : CinemaTheme.peacock.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            isFocused ? CinemaTheme.accentGold : CinemaTheme.peacockLight.opacity(0.25),
                            lineWidth: isFocused ? 2 : 1
                        )
                }
                .scaleEffect(isFocused ? 1.04 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
        }
        .focusRingFree()
    }
}

// MARK: - SettingsButton

struct SettingsButton: View {
    enum Style { case accent, ghost, destructive }
    let icon:      String
    let label:     String
    let style:     Style
    let colorMode: ColorMode
    let action:    () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: label.isEmpty ? 0 : 8) {
                Image(systemName: icon).font(.system(size: 16, weight: .medium))
                if !label.isEmpty {
                    Text(label).font(.system(size: 16, weight: .medium)).lineLimit(1)
                }
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, label.isEmpty ? 14 : 18)
            .padding(.vertical, 12)
            .background { glassBackground }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { glassBorder }
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .shadow(color: glowColor.opacity(isFocused ? 0.55 : 0), radius: 22, x: 0, y: 0)
            .shadow(color: .white.opacity(isFocused ? 0.16 : 0), radius: 6, x: 0, y: -4)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
        }
        .focusRingFree()
        .focused($isFocused)
    }

    private var foregroundColor: Color {
        switch style {
        case .accent:      return isFocused ? .black : CinemaTheme.accentGold
        case .ghost:       return isFocused ? CinemaTheme.primary(colorMode) : CinemaTheme.secondary(colorMode)
        case .destructive: return isFocused ? .white : .red.opacity(0.8)
        }
    }

    private var tintColor: Color {
        switch style {
        case .accent:      return CinemaTheme.accentGold
        case .ghost:       return CinemaTheme.peacock
        case .destructive: return .red
        }
    }

    private var glowColor: Color {
        switch style {
        case .accent:      return CinemaTheme.accentGold
        case .ghost:       return CinemaTheme.teal
        case .destructive: return .red
        }
    }

    @ViewBuilder private var glassBackground: some View {
        ZStack {
            tintColor.opacity(isFocused ? 0.45 : 0.12)
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(isFocused ? 0.52 : 0.22), location: 0.00),
                    .init(color: .white.opacity(isFocused ? 0.14 : 0.05), location: 0.44),
                    .init(color: .clear,                                   location: 0.72),
                ],
                startPoint: .top, endPoint: .bottom
            )
            LinearGradient(
                stops: [
                    .init(color: .clear,                                   location: 0.65),
                    .init(color: .white.opacity(isFocused ? 0.12 : 0.04), location: 1.00),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    @ViewBuilder private var glassBorder: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(isFocused ? 0.80 : 0.38), location: 0.00),
                        .init(color: .white.opacity(isFocused ? 0.32 : 0.16), location: 0.50),
                        .init(color: .white.opacity(isFocused ? 0.12 : 0.06), location: 1.00),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                lineWidth: isFocused ? 1.5 : 1.0
            )
    }
}

// MARK: - ColorModeCard

struct ColorModeCard: View {
    let mode:      ColorMode
    let isActive:  Bool
    let colorMode: ColorMode
    let onTap:     () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(previewBackground)
                        .frame(width: 160, height: 90)
                        .overlay {
                            VStack(spacing: 6) {
                                HStack(spacing: 4) {
                                    ForEach(0..<4, id: \.self) { _ in
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(previewAccent.opacity(0.7))
                                            .frame(width: 24, height: 6)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(previewAccent.opacity(0.9))
                                        .frame(width: 40, height: 14)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                Spacer()
                            }
                            .padding(.top, 10)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(
                                    isActive || isFocused
                                        ? CinemaTheme.peacock
                                        : Color.white.opacity(0.15),
                                    lineWidth: isActive ? 2.5 : 1
                                )
                        }
                }
                .scaleEffect(isFocused ? 1.04 : 1.0)
                .shadow(color: isFocused ? CinemaTheme.peacock.opacity(0.5) : .clear, radius: 16)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)

                HStack(spacing: 8) {
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(CinemaTheme.peacock)
                    }
                    Text(mode.displayName)
                        .font(.system(size: 16, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? CinemaTheme.primary(colorMode) : CinemaTheme.secondary(colorMode))
                }
            }
        }
        .focusRingFree()
        .focused($isFocused)
    }

    private var previewBackground: LinearGradient {
        mode == .dark
            ? LinearGradient(colors: [CinemaTheme.darkBg0, CinemaTheme.darkBg2, CinemaTheme.darkBg4], startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [CinemaTheme.frostBase, CinemaTheme.frostMid, CinemaTheme.frostDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var previewAccent: Color { mode == .dark ? CinemaTheme.gold : CinemaTheme.peacock }
}
