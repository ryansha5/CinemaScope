# Playback Quarantine Sprint — Status Report

**Date:** April 28, 2026  
**Branch:** main  
**Goal:** Prove clean end-to-end playback (video + audio) through the custom PlayerLab pipeline before touching shared routing, HomeView, or PlaybackEngine.

---

## Architecture Overview

The quarantine test UI is `PlaybackLabMinimalView` — a two-panel tvOS view (sidebar browser + player panel) that bypasses every shared engine layer. It has two independent controller instances:

- `controller` (`videoOnly: true`) — Phases 2 and 3
- `audioController` (`videoOnly: false`) — Phase 4

Both use `EmbyAPI.fetchMediaInfo` → `EmbyAPI.rawStreamURL` (`Static=true` byte-range) to get a direct stream URL that bypasses Emby's transcoding.

Entry point: Settings → PlayerLab → "Quarantine Lab" button.

---

## Phase 1 — AVPlayer Baseline

**Status: ✅ PASS**

Uses `EmbyAPI.playbackURL()` → `AVPlayer`. Confirmed working on H.264 content. Establishes that Emby connectivity, token, and URL resolution are all sound.

---

## Phase 2 — H.264 Custom Pipeline (videoOnly: true)

**Status: ✅ PASS**

Tests the full custom pipeline — `MKVDemuxer` → `PacketFeeder` → `FrameRenderer` — with audio silently dropped.

**Fixes applied to get here:**

- `secondarySystemBackground` unavailable on tvOS → replaced with `Color.white.opacity(0.07)` (4 occurrences)
- `textInputAutocapitalization` / `keyboardType` unavailable on tvOS → removed
- `EmbyLibrary` not `Equatable` for `.onChange(of: selectedLib)` → added `Equatable` conformance to `EmbyModels.swift`
- tvOS focus navigation: Siri remote could not traverse sidebar ↔ player panel
  - Fixed: `.focusSection()` on both VStack panels
  - Fixed: `.buttonStyle(.plain)` suppresses tvOS native focus highlight → replaced all buttons with `LabFocusButtonStyle` (custom `ButtonStyle` using `@Environment(\.isFocused)`, 1.06× scale + teal shadow)

---

## Phase 3 — HEVC Custom Pipeline (videoOnly: true)

**Status: ⚠️ PARTIAL — Video plays but periodic frame distortion unresolved**

### What works
HEVC streams play back. Duration tracking, the feed loop, and seek all function. Audio is intentionally suppressed.

### Distortion investigation

#### Root cause 1 — identified and fixed
`PacketFeeder.fetchPackets()` had a BL-frame size filter that ran on **all** HEVC files whenever `stripDolbyVisionNALsEnabled = true`, not just on confirmed DV dual-layer files:

```swift
// BEFORE (broken):
if PacketFeeder.stripDolbyVisionNALsEnabled
    && pkt.data.count < PacketFeeder.kDVBLFrameSizeThreshold {  // 600 B
    continue
}

// AFTER (fixed):
if isHEVC
    && PacketFeeder.stripDolbyVisionNALsEnabled
    && isDolbyVisionDualLayer   // ← new gate
    && pkt.data.count < PacketFeeder.kDVBLFrameSizeThreshold {
    continue
}
```

Non-DV HEVC encodes legitimately produce frames under 600 B in static or low-motion scenes. Dropping them removes decoder reference frames and causes corruption every 10–20 seconds (pattern varies with scene cuts).

**Changes to implement this fix:**

`PacketFeeder.swift` — added instance property:
```swift
var isDolbyVisionDualLayer: Bool = false
```

`MKVDemuxer.swift` — added computed property:
```swift
var isDolbyVisionDualLayer: Bool { firstVideoKeyframeIndex > 0 }
```

`firstVideoKeyframeIndex` detects DV Profile 7 dual-layer structure by checking whether all inter-frames between the first two keyframes are tiny (< 200 B, characteristic of BL skip frames). A 2 KB guard on the first keyframe size was later added to prevent false positives from non-DV files with skip-coded frames near the start.

`PlayerLabPlaybackController.swift` — wired in the `.mkv` prepare case:
```swift
feeder.isDolbyVisionDualLayer = r.demuxer.isDolbyVisionDualLayer
record("[Prepare] isDolbyVisionDualLayer=\(r.demuxer.isDolbyVisionDualLayer)  "
     + "firstKF=\(r.demuxer.firstVideoKeyframeIndex)")
```

#### Root cause 2 — unresolved ⚠️

After the above fix, distortion persists on a 1080p HEVC test file. Characteristics:

- **Consistent** — always the same frames, not random
- **Onset** — clean through production logo splash screens, distortion begins when the main feature starts
- **File is healthy** — plays perfectly in Infuse and Emby
- **Not full-stream** — a few frames at a time distort, most of the stream is clean

**Hypotheses (not yet tested):**

1. `stripDolbyVisionNALs()` is incorrectly stripping legitimate NALs from non-DV frames. The NAL-level stripping pass (`if isHEVC && stripDolbyVisionNALsEnabled`) still runs on **all** HEVC files, not just DV ones. If this file has any NAL type 62/63 content (HDR10+ metadata, DV single-layer RPU, or encoder-specific use of reserved NAL types), those bytes would be removed from specific frames consistently.
   - **Diagnostic:** toggle DV strip OFF in the sidebar → if distortion disappears, the stripping code is at fault and needs to be gated on `isDolbyVisionDualLayer` just like the size filter.

2. NAL unit boundary mis-parsing in `stripDolbyVisionNALs()` causing the function to misidentify legitimate NAL payload bytes as type 62/63 headers on certain frame data patterns.

3. B-frame decode order issue for HEVC content — Sprint 47 added decode-order sorting for H.264 B-frames; HEVC may have the same requirement but not the same fix.

4. `firstVideoKeyframeIndex` heuristic still producing a false positive for this file, causing `isDolbyVisionDualLayer = true` and re-enabling the 600 B size filter. The 2 KB guard helps but may not be sufficient for all files.

**The single most valuable next step:** run the DV-strip toggle test (off = no stripping at all). If distortion disappears, the fix is to move the entire `stripDolbyVisionNALs()` call inside an `isDolbyVisionDualLayer` guard, not just the size filter.

---

## Phase 4 — Audio Isolation (videoOnly: false)

**Status: ❌ BLOCKED — AVSampleBufferRenderSynchronizer clock hard-stalls**

### What was attempted

Phase 4 uses `audioController` (`videoOnly: false`) — a completely separate `PlayerLabPlaybackController` instance with its own `FrameRenderer`, `AVSampleBufferRenderSynchronizer`, and `AVSampleBufferAudioRenderer`.

Test file: 1080p HEVC + AAC 5.1.

### Diagnostic log (500ms after play())

```
prepare() → Ready
  hasAudio=true  audioAttached=true
State → ▶ Playing
[P4-diag] audioRenderer.status=rendering ✅
[P4-diag] tbRate=0.0  tbTime=0.043s
```

Everything is set up correctly. The audio renderer primed. But `tbRate=0.0` — the synchronizer's CMTimebase clock is frozen at the initial anchor PTS and never starts.

### Root cause

`AVSampleBufferRenderSynchronizer.setRate(1)` fails silently on tvOS when `AVSampleBufferAudioRenderer` is attached to the same synchronizer. The failure is permanent — no amount of retrying `setRate(1)` un-blocks it. A 20-attempt retry loop (2 seconds, every 100 ms) confirmed this.

This behaviour occurs even when:
- `AVAudioSession` is active (`.playback` / `.moviePlayback`) before attachment
- Audio renderer attachment is deferred until `prepare()` step 7 (after session activation, before `feedWindow`)
- Audio renderer has already reached `.rendering` status

The synchronizer accepting `rate=1` as a property value but the underlying CMTimebase staying at rate=0 is a known tvOS-specific divergence between `synchronizer.rate` (API value) and `CMTimebaseGetRate(synchronizer.timebase)` (actual clock rate).

### Attempted fixes

| Attempt | Result |
|---------|--------|
| Defer `attachAudioRenderer()` until after `AVAudioSession.setActive(true)` | No change — clock still stalls |
| 20-attempt retry loop re-issuing `setRate(1, time: .invalid)` every 100 ms | No change — all retries fail |
| Separate `audioSynchronizer` for the audio renderer (video on `synchronizer`, audio on `audioSynchronizer`) | Caused Phase 3 regression — `PlayerLabDisplayView.updateUIView` was calling `attachDisplayLayer` on every SwiftUI re-render, repeatedly tearing and re-attaching the display layer mid-playback → all distortion symptoms returned |

### Regression note

The separate-synchronizer approach modified `PlayerLabDisplayView.updateUIView` to re-attach the display layer on prop change. SwiftUI calls `updateUIView` on every state change during playback (frame count, buffer level, etc.), so the layer was being removed and re-added continuously, disrupting the display link and causing decoder corruption.

**All Phase 4 changes have been reverted.** Phase 3 code is restored to the state that preceded Phase 4 work (i.e., the `isDolbyVisionDualLayer` fix is present but the open distortion question remains).

### Phase 4 path forward

The dual-synchronizer approach is architecturally correct — the audio renderer must not share a synchronizer with the video display layer on tvOS. The implementation needs:

1. `PlayerLabDisplayView.updateUIView` must only call `attachDisplayLayer` when the renderer *identity* changes (not on every prop update). Track the attached layer identity and compare before re-attaching.

2. With two independent clocks, A/V sync requires manual drift correction or a clock-tying mechanism (e.g., a `CADisplayLink` that adjusts `audioSynchronizer`'s rate/offset based on the video timebase).

3. Alternatively, investigate whether `AVAudioEngine` + `AVAudioPlayerNode` with manual PTS scheduling can replace `AVSampleBufferAudioRenderer` entirely, avoiding the synchronizer stall altogether.

---

## Files Changed This Sprint

| File | Change |
|------|--------|
| `Features/PlaybackQuarantine/PlaybackLabMinimalView.swift` | **New file** — full quarantine test UI |
| `Features/Settings/SettingsView.swift` | Added "Quarantine Lab" entry point button |
| `PlayerLab/Core/PacketFeeder.swift` | `isDolbyVisionDualLayer` instance flag; BL size filter gated on it; NAL stripping gated on `isHEVC`; codec detection split H.264 vs HEVC; `avcNalUnitLength` helper added |
| `PlayerLab/Demux/MKV/MKVDemuxer.swift` | `isDolbyVisionDualLayer` computed property; `firstVideoKeyframeIndex` 3-condition DV detection with 2 KB first-keyframe guard |
| `PlayerLab/Render/FrameRenderer.swift` | `videoOnlyDiagnostic` static → instance `let`; `init(videoOnly:)`; deferred `attachAudioRenderer()`; `audioRendererAttached` flag; all flush methods guard audio on `audioRendererAttached` |
| `PlayerLab/Render/PlayerLabPlaybackController.swift` | `init(videoOnly:)` parameter; `feeder.isDolbyVisionDualLayer` wiring in `.mkv` prepare case; `attachAudioRenderer()` called after `activateAudioSession()` when `hasAudio` |
| `Services/Emby/EmbyModels.swift` | `EmbyLibrary: Equatable` |

---

## Open Issues

| # | Issue | Severity | Next Step |
|---|-------|----------|-----------|
| 1 | Phase 3 HEVC distortion — specific frames corrupt, consistent position | High | Test with DV strip toggle OFF; if clean, gate `stripDolbyVisionNALs()` call on `isDolbyVisionDualLayer` |
| 2 | Phase 4 — AVSampleBufferRenderSynchronizer clock stall with audio renderer on tvOS | High | Fix `PlayerLabDisplayView.updateUIView` to use identity check; re-implement dual-synchronizer; consider AVAudioEngine alternative |
| 3 | Phase 3 buffering/stuttering | Low | Separate issue from distortion; investigate read-ahead depth and decoder queue pressure once distortion is resolved |
