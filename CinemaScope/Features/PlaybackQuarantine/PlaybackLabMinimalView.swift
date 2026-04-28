// MARK: - Features / PlaybackQuarantine / PlaybackLabMinimalView
//
// Playback Quarantine Sprint — isolated pipeline test interface.
//
// Design rules:
//   • No shared PlaybackEngine, AVPlayer fallback, or PINEA routing.
//   • No autoplay. No DV stripping (Phase 2+). No first-frame mode.
//   • Uses EmbySession to browse the server and resolve a raw stream URL.
//   • Audio is detached from the synchronizer until Phase 4.
//
// Layout:
//   Left sidebar  — library browser + phase picker
//   Right panel   — video surface, transport controls, status log

import SwiftUI
import AVKit
import AVFoundation
import CoreMedia

// MARK: - QuarantinePhase

enum QuarantinePhase: String, CaseIterable, Identifiable {
    case phase1AVPlayer = "Phase 1"
    case phase2H264     = "Phase 2"
    case phase3HEVC     = "Phase 3"
    case phase4Audio    = "Phase 4"

    var id: String { rawValue }

    var label: String { rawValue }

    var subtitle: String {
        switch self {
        case .phase1AVPlayer: return "AVPlayer baseline"
        case .phase2H264:     return "H.264 video only"
        case .phase3HEVC:     return "HEVC video only"
        case .phase4Audio:    return "Audio isolated"
        }
    }

    var icon: String {
        switch self {
        case .phase1AVPlayer: return "play.tv.fill"
        case .phase2H264:     return "film.stack"
        case .phase3HEVC:     return "4k.tv.fill"
        case .phase4Audio:    return "waveform"
        }
    }
}

// MARK: - PlaybackLabMinimalView

struct PlaybackLabMinimalView: View {

    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var session:  EmbySession
    @EnvironmentObject private var settings: AppSettings

    // MARK: Browser state
    @State private var libraries:      [EmbyLibrary] = []
    @State private var selectedLib:    EmbyLibrary?  = nil
    @State private var items:          [EmbyItem]    = []
    @State private var selectedItem:   EmbyItem?     = nil
    @State private var isBrowseLoading: Bool         = false
    @State private var browseError:    String?       = nil

    // MARK: Playback state
    @State private var phase:          QuarantinePhase = .phase2H264
    /// When true, Dolby Vision NALs (types 62/63) are stripped from HEVC before
    /// handing to VideoToolbox.  Default ON — most 4K HEVC files contain DV NALs
    /// even when not flagged as "Dolby Vision" content; passing them through
    /// silently corrupts VideoToolbox decoder state.  Toggle OFF to confirm
    /// whether distortion is caused by DV NALs (it should reappear when OFF).
    @State private var dvStripEnabled: Bool            = true
    @State private var logLines:       [String]        = []
    @State private var avPlayer:       AVPlayer?       = nil

    // Phase 2/3 controller — audio renderer NOT attached.
    @StateObject private var controller      = PlayerLabPlaybackController(videoOnly: true)
    // Phase 4 controller — audio renderer attached to its own synchronizer.
    // Kept in a separate StateObject so Phase 2/3 and Phase 4 never share a clock.
    @StateObject private var audioController = PlayerLabPlaybackController(videoOnly: false)

    var body: some View {
        ZStack {
            // Background
            CinemaTheme.backgroundGradient(settings.colorMode)
                .ignoresSafeArea()
            CinemaTheme.radialOverlay(settings.colorMode)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                // ── Left sidebar ─────────────────────────────────────────
                sidebar
                    .frame(width: 420)

                Divider()
                    .background(CinemaTheme.peacockLight.opacity(0.2))

                // ── Right panel ──────────────────────────────────────────
                playerPanel
            }
        }
        .task { await loadLibraries() }
        .onChange(of: selectedLib) { _, lib in
            guard let lib else { return }
            Task { await loadItems(library: lib) }
        }
        .onChange(of: controller.state) { _, s in
            log("State → \(s.statusLabel)")
        }
        .onChange(of: audioController.state) { _, s in
            if phase == .phase4Audio { log("State → \(s.statusLabel)") }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Label("Quarantine Lab", systemImage: "flask.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(CinemaTheme.teal)
                Spacer()
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(CinemaTheme.textSecondary(settings.colorMode))
                    }
                    .buttonStyle(LabFocusButtonStyle())
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 20)

            Divider()
                .background(CinemaTheme.peacockLight.opacity(0.2))

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {

                    // Phase picker
                    phaseSection

                    Divider()
                        .background(CinemaTheme.peacockLight.opacity(0.15))

                    // DV strip toggle
                    dvStripSection

                    Divider()
                        .background(CinemaTheme.peacockLight.opacity(0.15))

                    // Library browser
                    browserSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
        }
        .background(CinemaTheme.peacockDeep.opacity(0.6))
        .focusSection()   // tvOS: directional swipes from the right panel land here
    }

    // MARK: DV Strip Section

    private var dvStripSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OPTIONS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CinemaTheme.textTertiary(settings.colorMode))
                .kerning(1.5)

            Button {
                dvStripEnabled.toggle()
                log("DV strip → \(dvStripEnabled ? "ON" : "OFF")")
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: dvStripEnabled ? "checkmark.square.fill" : "square")
                        .font(.system(size: 18))
                        .foregroundStyle(dvStripEnabled ? CinemaTheme.teal : CinemaTheme.textTertiary(settings.colorMode))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("DV NAL Strip")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(CinemaTheme.textPrimary(settings.colorMode))
                        Text(dvStripEnabled
                             ? "Stripping types 62/63 — clean HEVC"
                             : "⚠️ DV NALs pass through — may corrupt")
                            .font(.system(size: 12))
                            .foregroundStyle(dvStripEnabled
                                ? CinemaTheme.textTertiary(settings.colorMode)
                                : .orange)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(CinemaTheme.peacockDeep.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(dvStripEnabled
                            ? CinemaTheme.teal.opacity(0.3)
                            : Color.orange.opacity(0.4), lineWidth: 1)
                )
            }
            .buttonStyle(LabFocusButtonStyle())
        }
    }

    // MARK: Phase Section

    private var phaseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PHASE")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CinemaTheme.textTertiary(settings.colorMode))
                .kerning(1.5)

            VStack(spacing: 8) {
                ForEach(QuarantinePhase.allCases) { p in
                    phaseRow(p)
                }
            }
        }
    }

    private func phaseRow(_ p: QuarantinePhase) -> some View {
        Button {
            if phase != p {
                phase = p
                stopPlayback()
                log("Phase → \(p.rawValue): \(p.subtitle)")
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: p.icon)
                    .font(.system(size: 16))
                    .frame(width: 22)
                    .foregroundStyle(phase == p ? CinemaTheme.teal : CinemaTheme.textSecondary(settings.colorMode))

                VStack(alignment: .leading, spacing: 2) {
                    Text(p.label)
                        .font(.system(size: 16, weight: phase == p ? .semibold : .regular))
                        .foregroundStyle(phase == p ? .white : CinemaTheme.textSecondary(settings.colorMode))
                    Text(p.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(CinemaTheme.textTertiary(settings.colorMode))
                }

                Spacer()

                if phase == p {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CinemaTheme.teal)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(phase == p
                ? CinemaTheme.teal.opacity(0.15)
                : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(phase == p
                        ? CinemaTheme.teal.opacity(0.4)
                        : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(LabFocusButtonStyle())
    }

    // MARK: Browser Section

    private var browserSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LIBRARY")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CinemaTheme.textTertiary(settings.colorMode))
                .kerning(1.5)

            if isBrowseLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading…")
                        .font(.system(size: 14))
                        .foregroundStyle(CinemaTheme.textTertiary(settings.colorMode))
                }
            } else if let err = browseError {
                Text(err)
                    .font(.system(size: 13))
                    .foregroundStyle(.red.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Library picker
                if !libraries.isEmpty {
                    libraryPicker
                }

                // Item list
                if !items.isEmpty {
                    itemList
                } else if selectedLib != nil && !isBrowseLoading {
                    Text("No items")
                        .font(.system(size: 14))
                        .foregroundStyle(CinemaTheme.textTertiary(settings.colorMode))
                }
            }
        }
    }

    private var libraryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(libraries) { lib in
                    Button {
                        selectedLib = lib
                    } label: {
                        Text(lib.name)
                            .font(.system(size: 13, weight: selectedLib?.id == lib.id ? .semibold : .regular))
                            .foregroundStyle(selectedLib?.id == lib.id ? CinemaTheme.teal : CinemaTheme.textSecondary(settings.colorMode))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                selectedLib?.id == lib.id
                                    ? CinemaTheme.teal.opacity(0.15)
                                    : CinemaTheme.peacockDeep.opacity(0.4)
                            )
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        selectedLib?.id == lib.id
                                            ? CinemaTheme.teal.opacity(0.5)
                                            : CinemaTheme.peacockLight.opacity(0.2),
                                        lineWidth: 1)
                            )
                    }
                    .buttonStyle(LabFocusButtonStyle())
                }
            }
        }
    }

    private var itemList: some View {
        VStack(spacing: 6) {
            ForEach(items) { item in
                itemRow(item)
            }
        }
    }

    private func itemRow(_ item: EmbyItem) -> some View {
        let isSelected = selectedItem?.id == item.id
        return Button {
            selectedItem = item
            log("Selected: \(item.name) (\(item.productionYear.map{"\($0)"} ?? "—"))")
        } label: {
            HStack(spacing: 12) {
                // Poster thumbnail
                posterView(item: item, size: CGSize(width: 36, height: 54))

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : CinemaTheme.textSecondary(settings.colorMode))
                        .lineLimit(2)
                    if let year = item.productionYear {
                        Text("\(year)")
                            .font(.system(size: 12))
                            .foregroundStyle(CinemaTheme.textTertiary(settings.colorMode))
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(CinemaTheme.teal)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected
                ? CinemaTheme.teal.opacity(0.12)
                : Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected
                        ? CinemaTheme.teal.opacity(0.35)
                        : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(LabFocusButtonStyle())
    }

    @ViewBuilder
    private func posterView(item: EmbyItem, size: CGSize) -> some View {
        if let server = session.server,
           let url = EmbyAPI.primaryImageURL(server: server, itemId: item.id, tag: item.imageTags?.primary, width: Int(size.width * 2)) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                default:
                    placeholderPoster(size: size)
                }
            }
        } else {
            placeholderPoster(size: size)
        }
    }

    private func placeholderPoster(size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(CinemaTheme.peacockDeep)
            .frame(width: size.width, height: size.height)
            .overlay(
                Image(systemName: "film")
                    .font(.system(size: 12))
                    .foregroundStyle(CinemaTheme.peacockLight.opacity(0.5))
            )
    }

    // MARK: - Player Panel

    private var playerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Video surface
            videoSurface
                .frame(maxWidth: .infinity)
                .aspectRatio(16/9, contentMode: .fit)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 32)
                .padding(.top, 28)

            // Selected item info + controls
            HStack(alignment: .top, spacing: 32) {

                // Item info + transport
                VStack(alignment: .leading, spacing: 16) {
                    selectedItemInfo

                    transportControls
                        .padding(.top, 4)

                    controllerStateView
                }

                // Log
                logView
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 24)

            Spacer(minLength: 0)
        }
        .focusSection()   // tvOS: directional swipes from the sidebar land here
    }

    // MARK: Video Surface

    @ViewBuilder
    private var videoSurface: some View {
        if phase == .phase1AVPlayer {
            if let player = avPlayer {
                VideoPlayer(player: player)
            } else {
                emptyVideoSurface(label: "Phase 1 — AVPlayer\nSelect a title and press Play")
            }
        } else {
            ZStack {
                Color.black
                PlayerLabDisplayView(renderer: activeController.renderer)
                if activeController.state == .idle || activeController.state == .loading {
                    emptyVideoSurface(label: "\(phase.label) — \(phase.subtitle)\nSelect a title and press Play")
                }
            }
        }
    }

    @ViewBuilder
    private func emptyVideoSurface(label: String) -> some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: "flask.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(CinemaTheme.teal.opacity(0.5))
                Text(label)
                    .font(.system(size: 16))
                    .foregroundStyle(CinemaTheme.textTertiary(settings.colorMode))
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: Item Info

    private var selectedItemInfo: some View {
        Group {
            if let item = selectedItem {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(CinemaTheme.textPrimary(settings.colorMode))
                        .lineLimit(1)
                    HStack(spacing: 12) {
                        if let year = item.productionYear {
                            Text("\(year)")
                                .font(.system(size: 14))
                                .foregroundStyle(CinemaTheme.textTertiary(settings.colorMode))
                        }
                        if let mins = item.runtimeMinutes {
                            Text("\(mins)m")
                                .font(.system(size: 14))
                                .foregroundStyle(CinemaTheme.textTertiary(settings.colorMode))
                        }
                        Text(phase.subtitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(CinemaTheme.teal)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(CinemaTheme.teal.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            } else {
                Text("No title selected")
                    .font(.system(size: 16))
                    .foregroundStyle(CinemaTheme.textTertiary(settings.colorMode))
            }
        }
    }

    // MARK: Transport Controls

    private var transportControls: some View {
        HStack(spacing: 14) {
            transportButton(
                icon:     "play.fill",
                label:    "Play",
                enabled:  selectedItem != nil,
                accent:   true
            ) {
                Task { await startPlayback() }
            }

            transportButton(
                icon:    "pause.fill",
                label:   "Pause",
                enabled: isActivelyPlaying
            ) {
                pausePlayback()
            }

            transportButton(
                icon:    "stop.fill",
                label:   "Stop",
                enabled: isActivelyPlaying || activeController.state == .paused
            ) {
                stopPlayback()
            }
        }
    }

    private func transportButton(
        icon: String,
        label: String,
        enabled: Bool,
        accent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(enabled ? (accent ? .black : .white) : CinemaTheme.textTertiary(settings.colorMode))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                enabled
                    ? (accent ? CinemaTheme.teal : CinemaTheme.peacockDeep.opacity(0.8))
                    : Color.white.opacity(0.05)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(enabled ? 0.1 : 0.04), lineWidth: 1)
            )
        }
        .buttonStyle(LabFocusButtonStyle())
        .disabled(!enabled)
    }

    // MARK: Controller State

    private var controllerStateView: some View {
        Group {
            if phase != .phase1AVPlayer {
                HStack(spacing: 8) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 8, height: 8)
                    Text(activeController.state.statusLabel)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(CinemaTheme.textSecondary(settings.colorMode))
                }
            }
        }
    }

    private var stateColor: Color {
        switch activeController.state {
        case .playing:              return .green
        case .buffering, .loading:  return .yellow
        case .failed:               return .red
        case .paused:               return .orange
        default:                    return CinemaTheme.peacockLight
        }
    }

    // MARK: Log

    private var logView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LOG")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CinemaTheme.textTertiary(settings.colorMode))
                    .kerning(1.5)
                Spacer()
                if !logLines.isEmpty {
                    Button("Clear") { logLines = [] }
                        .font(.system(size: 12))
                        .foregroundStyle(CinemaTheme.textTertiary(settings.colorMode))
                        .buttonStyle(LabFocusButtonStyle())
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(logLines.indices, id: \.self) { i in
                            Text(logLines[i])
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(CinemaTheme.textSecondary(settings.colorMode))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 160)
                .background(Color.black.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(CinemaTheme.peacockLight.opacity(0.15), lineWidth: 1)
                )
                .onChange(of: logLines.count) { _, count in
                    if count > 0 {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Active controller

    /// Returns the right controller for the active phase.
    /// Phase 4 uses audioController (videoOnly:false); all others use controller (videoOnly:true).
    private var activeController: PlayerLabPlaybackController {
        phase == .phase4Audio ? audioController : controller
    }

    // MARK: - Derived

    private var isActivelyPlaying: Bool {
        if phase == .phase1AVPlayer { return avPlayer != nil }
        return activeController.state == .playing || activeController.state == .buffering
    }

    // MARK: - Data Loading

    private func loadLibraries() async {
        guard let server = session.server,
              let user   = session.user,
              let token  = session.token else {
            browseError = "Not authenticated"
            return
        }
        isBrowseLoading = true
        browseError     = nil
        do {
            let libs = try await EmbyAPI.fetchLibraries(server: server, userId: user.id, token: token)
            libraries = libs.filter { $0.collectionType == "movies" || $0.collectionType == "tvshows" || $0.collectionType == nil }
            selectedLib = libraries.first
            log("Loaded \(libraries.count) libraries")
        } catch {
            browseError = "Failed to load libraries: \(error.localizedDescription)"
            log("❌ Libraries: \(error.localizedDescription)")
        }
        isBrowseLoading = false
    }

    private func loadItems(library: EmbyLibrary) async {
        guard let server = session.server,
              let user   = session.user,
              let token  = session.token else { return }
        isBrowseLoading = true
        do {
            let response = try await EmbyAPI.fetchItems(
                server: server, userId: user.id, token: token,
                parentId: library.id, limit: 200
            )
            items = response.items
            log("Loaded \(items.count) items from \(library.name)")
        } catch {
            browseError = "Failed to load items: \(error.localizedDescription)"
            log("❌ Items: \(error.localizedDescription)")
        }
        isBrowseLoading = false
    }

    // MARK: - Playback

    private func startPlayback() async {
        guard let item   = selectedItem,
              let server = session.server,
              let token  = session.token else { return }

        log("▶ \(item.name) — \(phase.label)")
        stopPlayback()

        switch phase {

        // ── Phase 1: AVPlayer ─────────────────────────────────────────
        case .phase1AVPlayer:
            do {
                let result = try await EmbyAPI.playbackURL(
                    server: server, userId: session.user?.id ?? "",
                    token: token, itemId: item.id, itemName: item.name
                )
                let player = AVPlayer(url: result.url)
                avPlayer = player
                player.play()
                log("AVPlayer started")
            } catch {
                log("❌ AVPlayer: \(error.localizedDescription)")
            }

        // ── Phases 2–4: PlayerLab raw stream ─────────────────────────
        case .phase2H264, .phase3HEVC, .phase4Audio:
            guard let mediaSource = try? await EmbyAPI.fetchMediaInfo(
                server: server, userId: session.user?.id ?? "",
                token: token, itemId: item.id
            ) else {
                log("❌ fetchMediaInfo failed")
                return
            }

            let container = mediaSource.container ?? "mkv"
            guard let streamURL = EmbyAPI.rawStreamURL(
                server:        server,
                token:         token,
                itemId:        item.id,
                mediaSourceId: mediaSource.id,
                container:     container
            ) else {
                log("❌ rawStreamURL failed")
                return
            }

            log("URL resolved → \(streamURL.absoluteString.prefix(80))…")

            // Apply the DV strip toggle before prepare() reads it.
            PacketFeeder.stripDolbyVisionNALsEnabled = dvStripEnabled
            log("dvStrip → \(dvStripEnabled ? "ON (types 62/63 stripped)" : "OFF (DV NALs pass through)")")
            activeController.firstFrameMode = false

            do {
                try await activeController.prepare(url: streamURL)
                log("prepare() → \(activeController.state.statusLabel)")
                activeController.play()
            } catch {
                log("❌ prepare: \(error.localizedDescription)")
            }
        }
    }

    private func pausePlayback() {
        if phase == .phase1AVPlayer {
            avPlayer?.pause()
        } else {
            activeController.pause()
        }
        log("⏸ paused")
    }

    private func stopPlayback() {
        avPlayer?.pause()
        avPlayer = nil
        if phase != .phase1AVPlayer {
            activeController.stop()
        }
        log("⏹ stopped")
    }

    // MARK: - Log

    private func log(_ msg: String) {
        let ts = Date().formatted(.dateTime.hour().minute().second())
        logLines.append("[\(ts)] \(msg)")
        if logLines.count > 300 { logLines.removeFirst(logLines.count - 300) }
    }
}

// MARK: - LabFocusButtonStyle
//
// Custom ButtonStyle that preserves our hand-crafted appearance while still
// participating in the tvOS focus engine properly.
//
// Behaviour:
//   • Focusable — the Siri remote can land on it via directional swipes.
//   • On focus: scales up 1.05× and adds a teal glow so the focused button
//     is unmistakably visible without overriding the label's own colors.
//   • On press:  scales down slightly for tactile feedback.
//   • Keeps the label's own background, corner radius, and text styling intact.

private struct LabFocusButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.06 : 1.0))
            .shadow(
                color: isFocused ? CinemaTheme.teal.opacity(0.55) : .clear,
                radius: isFocused ? 12 : 0
            )
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}
