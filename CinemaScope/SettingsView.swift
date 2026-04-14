import SwiftUI

struct SettingsView: View {

    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var session:  EmbySession
    let availableGenres: [String]
    let onDismiss: () -> Void

    @State private var showAddRibbon  = false
    @State private var savedFeedback  = false

    var body: some View {
        ZStack {
            CinemaBackground()

            HStack(alignment: .top, spacing: 0) {
                // Left panel — nav
                settingsSidebar
                    .focusSection()

                // Right panel — content
                ribbonEditor
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
    }

    // MARK: - Sidebar

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(CinemaTheme.primary(settings.colorMode))
                .padding(.bottom, 20)

            sidebarItem(icon: "rectangle.grid.1x2.fill", label: "Home Screen")

            Spacer()

            // Save button — settings auto-persist but this gives
            // explicit confirmation and is a clear exit point
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
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    savedFeedback
                        ? CinemaTheme.accentGold.opacity(0.15)
                        : CinemaTheme.peacock.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            savedFeedback
                                ? CinemaTheme.accentGold.opacity(0.5)
                                : CinemaTheme.peacockLight.opacity(0.2),
                            lineWidth: 1
                        )
                }
                .animation(.easeInOut(duration: 0.2), value: savedFeedback)
            }
            .focusRingFree()
            .padding(.bottom, 8)

            // Back without saving
            BackButton(colorMode: settings.colorMode, scopeMode: false, onTap: onDismiss)
        }
        .padding(32)
        .frame(width: 260)
        .background(CinemaTheme.peacockDeep.opacity(0.6))
        .overlay(alignment: .trailing) {
            Rectangle().fill(CinemaTheme.peacockLight.opacity(0.15)).frame(width: 1)
        }
    }

    private func sidebarItem(icon: String, label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16))
            Text(label).font(.system(size: 18, weight: .medium))
        }
        .foregroundStyle(CinemaTheme.accentGold)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CinemaTheme.peacockDeep.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(CinemaTheme.accentGold.opacity(0.4), lineWidth: 1)
        }
    }

    // MARK: - Ribbon Editor

    private var ribbonEditor: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Home Screen")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(CinemaTheme.primary(settings.colorMode))
                        Text("Choose and arrange the rows that appear on your home screen.")
                            .font(.system(size: 18))
                            .foregroundStyle(CinemaTheme.secondary(settings.colorMode))
                    }
                    Spacer()
                    HStack(spacing: 16) {
                        // Add ribbon
                        SettingsButton(icon: "plus.circle.fill", label: "Add Row", style: .accent, colorMode: settings.colorMode) {
                            showAddRibbon = true
                        }
                        // Reset
                        SettingsButton(icon: "arrow.counterclockwise", label: "Reset", style: .ghost, colorMode: settings.colorMode) {
                            settings.resetToDefaults()
                        }
                    }
                }

                // Color Mode picker
                VStack(alignment: .leading, spacing: 16) {
                    Text("Appearance")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(CinemaTheme.primary(settings.colorMode))

                    HStack(spacing: 16) {
                        ForEach(ColorMode.allCases) { mode in
                            ColorModeCard(
                                mode:      mode,
                                isActive:  settings.colorMode == mode,
                                colorMode: settings.colorMode
                            ) { settings.colorMode = mode }
                        }
                        Spacer()
                    }
                }
                .padding(.bottom, 8)

                Divider()
                    .background(CinemaTheme.peacockLight.opacity(0.2))
                    .padding(.bottom, 8)

                // Color Mode
                VStack(alignment: .leading, spacing: 16) {
                    Text("Appearance")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(CinemaTheme.primary(settings.colorMode))

                    HStack(spacing: 16) {
                        ForEach(ColorMode.allCases, id: \.rawValue) { mode in
                            ColorModeCard(mode: mode, isActive: settings.colorMode == mode,
                                          colorMode: settings.colorMode, onTap: {
                                settings.colorMode = mode
                            })
                        }
                    }
                }
                .padding(.bottom, 16)

                Divider()
                    .background(CinemaTheme.peacockLight.opacity(0.2))
                    .padding(.bottom, 16)

                Text("Home Screen")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(CinemaTheme.primary(settings.colorMode))
                    .padding(.bottom, 4)

                // Ribbon list — separate focusSection from header
                // so navigating up from top row reaches Add/Reset buttons
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
            // Icon + name
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

            // Controls
            HStack(spacing: 10) {
                // Toggle enabled
                SettingsButton(
                    icon:      ribbon.enabled ? "eye.fill" : "eye.slash",
                    label:     ribbon.enabled ? "Visible" : "Hidden",
                    style:     ribbon.enabled ? .accent : .ghost,
                    colorMode: colorMode
                ) { onToggle() }

                // Move up
                SettingsButton(icon: "chevron.up", label: "", style: .ghost, colorMode: colorMode) { onMoveUp() }
                    .disabled(isFirst)
                    .opacity(isFirst ? 0.3 : 1)

                // Move down
                SettingsButton(icon: "chevron.down", label: "", style: .ghost, colorMode: colorMode) { onMoveDown() }
                    .disabled(isLast)
                    .opacity(isLast ? 0.3 : 1)

                // Remove (only for user-added genre/custom ribbons)
                if case .genre = ribbon.type {
                    SettingsButton(icon: "trash", label: "", style: .destructive, colorMode: colorMode) { onRemove() }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            CinemaTheme.peacockDeep.opacity(ribbon.enabled ? 0.5 : 0.25),
            in: RoundedRectangle(cornerRadius: 12)
        )
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
                // Header
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

                // Item type picker
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

                // Genre grid
                if unusedGenres.isEmpty {
                    Text("All genres already added.")
                        .font(.system(size: 18))
                        .foregroundStyle(CinemaTheme.tertiary(colorMode))
                } else {
                    let cols = Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: cols, spacing: 16) {
                            ForEach(unusedGenres, id: \.self) { genre in
                                GenrePickerCell(
                                    genre:     genre,
                                    isFocused: focusedGenre == genre,
                                    colorMode: colorMode
                                ) {
                                    let ribbon = HomeRibbon(
                                        type: .genre(name: genre, itemType: selectedItemType)
                                    )
                                    onAdd(ribbon)
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
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
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
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(borderColor, lineWidth: isFocused ? 2 : 1)
            }
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
        }
        .focusRingFree()
        .focused($isFocused)
    }

    private var foregroundColor: Color {
        switch style {
        case .accent:      return isFocused ? .black : CinemaTheme.accentGold
        case .ghost:       return isFocused ? CinemaTheme.primary(colorMode) : CinemaTheme.secondary(colorMode)
        case .destructive: return isFocused ? CinemaTheme.primary(colorMode) : .red.opacity(0.7)
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .accent:      return isFocused ? CinemaTheme.accentGold : CinemaTheme.accentGold.opacity(0.15)
        case .ghost:       return isFocused ? CinemaTheme.peacock.opacity(0.5) : CinemaTheme.peacockDeep.opacity(0.5)
        case .destructive: return isFocused ? Color.red.opacity(0.5) : Color.red.opacity(0.1)
        }
    }

    private var borderColor: Color {
        switch style {
        case .accent:      return isFocused ? CinemaTheme.accentGold : CinemaTheme.accentGold.opacity(0.3)
        case .ghost:       return isFocused ? .white.opacity(0.4) : CinemaTheme.peacockLight.opacity(0.2)
        case .destructive: return isFocused ? .red.opacity(0.6) : .red.opacity(0.2)
        }
    }
}

struct ColorModeCard: View {
    let mode:      ColorMode
    let isActive:  Bool
    let colorMode: ColorMode   // current active mode (for token colors)
    let onTap:     () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 14) {
                // Preview swatch
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(previewBackground)
                        .frame(width: 160, height: 90)
                        .overlay {
                            // Fake UI chrome in preview
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
                .shadow(
                    color: isFocused ? CinemaTheme.peacock.opacity(0.5) : .clear,
                    radius: 16
                )
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
            ? LinearGradient(
                colors: [CinemaTheme.darkBg0, CinemaTheme.darkBg2, CinemaTheme.darkBg4],
                startPoint: .topLeading, endPoint: .bottomTrailing
              )
            : LinearGradient(
                colors: [CinemaTheme.frostBase, CinemaTheme.frostMid, CinemaTheme.frostDeep],
                startPoint: .topLeading, endPoint: .bottomTrailing
              )
    }

    private var previewAccent: Color {
        mode == .dark ? CinemaTheme.gold : CinemaTheme.peacock
    }
}
