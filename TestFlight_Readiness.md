# CinemaScope — TestFlight Beta Readiness

**Version:** 1.0 (Build 1)  
**Platform:** tvOS 18+  
**Xcode target:** CinemaScope (Apple TV)  
**Date:** April 2026

---

## What's In This Build

CinemaScope is a native tvOS Emby client with a cinema-first design philosophy. Beta 1 includes the full feature set across six sprints:

- **Sprint A – Core Navigation & Library**: Home screen with configurable ribbons, Movies/TV/Collections/Playlists grid views, library loading via Emby API
- **Sprint B – Media Playback**: AVPlayer integration, direct play + HLS transcode fallback, automatic retrying on format failure, OSD overlay, progress reporting to Emby
- **Sprint C – Detail & Discovery**: Full detail views for movies, series, episodes, collections; TMDB metadata enrichment; cast cards; season/episode browser; tech specs panel; favorites toggling
- **Sprint D – Search**: Full-text search, genre/scope filters, sort options (A–Z, year, rating, random), recent searches
- **Sprint E – Settings & Personalization**: Autoplay next episode with countdown, subtitle/audio defaults, startup tab picker, diagnostics panel, Scope UI (2.39:1 cinema layout), color mode (dark/light)
- **Sprint F – Polish & Beta Hardening**: Loading skeletons, cached image loading, first-run onboarding tour, accessibility labels/hints

---

## TestFlight Release Notes (What to Test)

> Copy this text into the "What to Test" field when submitting to TestFlight.

```
Welcome to the first CinemaScope beta!

CinemaScope is a tvOS Emby client focused on a clean, cinema-inspired experience.

TO GET STARTED:
1. Launch the app and enter your Emby server address (e.g. http://192.168.1.10:8096)
2. Select your user and enter your password
3. Complete the brief feature tour (or tap Skip)
4. Your library will load — browse movies, TV, and more

KEY THINGS TO TEST:
• Browsing home screen ribbons (Continue Watching, Recently Added, etc.)
• Playing a movie or TV episode — direct play and transcoded playback
• Autoplay next episode countdown at the end of an episode
• Scope UI toggle (ultra-wide 2.39:1 layout) in the nav bar
• Settings → Startup tab, Playback toggles, Diagnostics connection check
• Search with filters and sort options
• Detail views: cast, tech specs, season browser for TV shows

KNOWN LIMITATIONS IN THIS BUILD:
• Cross-season autoplay is not yet supported (falls back to home screen)
• Audio/subtitle track selection is settings-only; AVPlayer track switching not yet wired
• No offline mode

Please report any crashes, playback failures, or visual glitches via the TestFlight feedback button.
```

---

## Pre-Submission Checklist

### App Store Connect Setup
- [ ] App ID created for the tvOS target in Apple Developer portal
- [ ] App record created in App Store Connect (tvOS platform)
- [ ] Privacy nutrition labels completed (no data collected / not linked to user)
- [ ] Age rating questionnaire completed (expected: 17+ for unrestricted web access, or 4+ for personal server)
- [ ] At least one screenshot per required size uploaded (1920×1080 for tvOS)

### Build Configuration
- [ ] Build scheme set to **Release** (not Debug) before archiving
- [ ] `MARKETING_VERSION` = `1.0` — confirmed ✅
- [ ] `CURRENT_PROJECT_VERSION` = `1` — confirmed ✅
- [ ] Signing certificate: Distribution provisioning profile applied
- [ ] All capabilities match what's declared in the entitlements file
- [ ] No debug `print` statements left in shipping code paths (they're in non-shipping paths only — playback logs are acceptable for beta)

### Functionality Smoke Test (run before every build upload)
- [ ] Cold launch → splash → auth screen appears
- [ ] Server entry accepts a valid Emby URL and moves to user picker
- [ ] Login succeeds and onboarding tour appears (first run only)
- [ ] Home screen ribbons load within 10 seconds on LAN
- [ ] Tapping any movie/show opens detail view with backdrop
- [ ] Play button starts video without error (test direct play if server supports it)
- [ ] OSD appears on remote tap; scrubber is focusable and scrollable
- [ ] Menu button exits player and returns to detail
- [ ] Episode autoplay countdown appears at end of episode
- [ ] Settings → Diagnostics → Check Connection returns server info
- [ ] Search returns results for a known movie title
- [ ] App doesn't crash when the Emby server is unreachable (error state shown)
- [ ] Sign Out returns to server entry screen

### Accessibility
- [ ] VoiceOver: all buttons announce a readable label (no "button" without context)
- [ ] Dynamic Type: headings scale reasonably (tvOS respects system font size)
- [ ] Focus order is logical: top-left → right → down on all screens
- [ ] All interactive elements are reachable via remote D-pad navigation

---

## Known Issues (Beta 1)

| # | Area | Description | Severity | Workaround |
|---|------|-------------|----------|------------|
| 1 | Playback | Cross-season autoplay not supported — app returns to home when a season ends | Medium | Navigate to next season manually |
| 2 | Playback | Audio/subtitle track selection in-player not yet implemented (settings toggle has no effect during playback) | Low | Use Emby server defaults |
| 3 | Search | Results are limited to 100 items; very large libraries may feel truncated | Low | Use more specific search terms |
| 4 | Detail | TMDB metadata fetch may time out on poor connections; Emby data shown as fallback | Low | None required |
| 5 | Collections | Nested collections (BoxSets within BoxSets) only show one level deep | Low | None |

---

## Architecture Overview (for reviewers)

```
CinemaScope/
├── App/               CinemaScopeApp, SplashView
├── Core/
│   ├── Playback/      PlaybackEngine (AVPlayer wrapper), AspectRatioClassifier, PresentationMode
│   └── Theme/         CinemaTheme, AppSettings
├── Features/
│   ├── Auth/          ServerEntry → UserPicker → Login flow
│   ├── Onboarding/    4-page first-run feature tour
│   ├── Home/          HomeView, MediaRow, MediaCard, SectionGridView, GridCard
│   ├── Detail/        DetailView, SeasonDetailView, CollectionDetailView
│   ├── Player/        PlayerContainerView (UIKit), OSDView, NextEpisodeCountdown
│   ├── Search/        SearchView with filters + sort
│   └── Settings/      SettingsView with 4 panels
├── Services/
│   ├── Emby/          EmbyAPI, EmbyModels, EmbyLibraryStore, EmbySession
│   └── TMDB/          TMDBAPI (enrichment only — no account required)
└── Shared/
    └── Components/    BackButton, CachedAsyncImage, SkeletonView, SearchPill, …
```

**Third-party dependencies:** None (pure Swift / SwiftUI / AVFoundation / UIKit)

---

## Feedback & Contact

Bug reports via TestFlight feedback are preferred. For direct contact, reach the developer at shryan17@gmail.com.
