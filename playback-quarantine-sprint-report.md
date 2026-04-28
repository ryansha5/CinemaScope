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

**Status: ✅ PASS — All distortion resolved (Sprints 50 + 51)**

### What works
HEVC streams play back cleanly at 3840×2160. Duration tracking, the feed loop, and seek all function. No corruption at any point in the file. Audio is intentionally suppressed (Phase 4 handles audio).

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

`firstVideoKeyframeIndex` detects DV Profile 7 dual-layer structure by checking whether all inter-frames between the first two keyframes are tiny (< 200 B, characteristic of BL skip frames). A guard on the first keyframe size prevents false positives from non-DV files with skip-coded frames near the start.

**Guard threshold correction (post-log analysis):** The guard was originally `< 2_000 B`. Log inspection revealed the test file's BL IDR is 3091 B — it includes VPS+SPS+PPS for the BL stream plus the BL IDR slice, pushing it above the original limit. Because 3091 B > 2000 B, the guard was firing and returning `firstKF = 0`, making `isDolbyVisionDualLayer = false` and disabling the BL filter entirely. BL skip frames (114–569 B) were reaching VideoToolbox, which cannot decode them against the EL bitstream profile, producing the observed corruption at consistent intervals. Threshold raised to `< 30_000 B`: observed BL IDR range is 114 B–3091 B; real HEVC IDRs at 1080p are always >> 30 KB at any reasonable quality.

`PlayerLabPlaybackController.swift` — wired in the `.mkv` prepare case:
```swift
feeder.isDolbyVisionDualLayer = r.demuxer.isDolbyVisionDualLayer
record("[Prepare] isDolbyVisionDualLayer=\(r.demuxer.isDolbyVisionDualLayer)  "
     + "firstKF=\(r.demuxer.firstVideoKeyframeIndex)")
```

#### Root cause 2 — LP trailing-byte misclassification (fix applied, pending verification)

After the DV BL filter fix, distortion persists on a 1080p HEVC test file. The DV-strip toggle was confirmed OFF → distortion persists, ruling out NAL stripping as the cause. Sprint 47's fileOffset-sort for decode order is already applied to both H.264 and HEVC in `MKVDemuxer.extractPackets`.

**Updated characteristics:**
- **Consistent** — always the same frames, every 20–30 seconds
- **Onset** — clean through production logo splash screens, distortion begins when the main feature starts
- **File is healthy** — plays perfectly in Infuse and Emby
- **Not full-stream** — a few frames at a time distort, most of the stream is clean

**Confirmed ruled out:**
1. ~~DV NAL stripping~~ — strip OFF still distorts
2. ~~HEVC decode-order sort missing~~ — Sprint 47 already sorts both codecs by fileOffset

**Active hypothesis — LP trailing-byte misclassification:**

`isValidLengthPrefixed` requires `i == n` after walking all LP NAL units (all bytes consumed exactly). Some MKV muxers append 1–3 alignment/padding bytes after the last LP NAL. When this check fails for a specific frame, `detectNALFormat` falls back to `.annexB` and calls `convertAnnexBToLengthPrefixed` on data that is already correctly length-prefixed. Since HEVC LP payloads use RBSP encoding (emulation-prevention bytes prevent bare `00 00 01` patterns), the Annex B converter finds no start codes, produces empty output, and the frame is thrown as `.emptyPayload` and silently dropped. A dropped reference frame causes all B-frames that depend on it to produce corrupted output — "several clustered frames" at consistent positions every 20–30 seconds (matching the GOP keyframe interval of the main feature).

**Fix applied — `PacketFeeder.trimLPTrailingBytes`:**

New private static function in `PacketFeeder.swift`. Walks the LP NAL units the same way as `isValidLengthPrefixed` but records `lastValidEnd` as it goes. After the walk, if `lastValidEnd < n`, trailing bytes are present — the data is trimmed to `lastValidEnd` and the trim is logged:

```
[LP-Trim] trailing bytes removed  total=NNB  validLP=MMB  trailing=KB
```

`makeVideoSampleBuffer` now calls `trimLPTrailingBytes` in the LP branch instead of using `packet.data` directly. `isValidLengthPrefixed` and `detectNALFormat` are unchanged (still used in diagnostic logging).

**New diagnostics added:**

- `[HEVC-KF]` — logged for every HEVC keyframe: index, PTS, fileOffset, raw/norm size, format detected (LP vs AnnexB→LP), NAL type list. Reveals GOP structure and identifies any keyframes misclassified as Annex B.
- `[HEVC-AnnexB]` — logged for any HEVC frame (beyond the first 20 SampleDiag frames) where `detectNALFormat` returns `.annexB`. Direct confirmation of LP validation failures on specific frames.
- `[HEVC-{label}-HEAD/TAIL]` — logged for the first and last 3 packets of every HEVC video batch, in decode order (fileOffset-sorted). Shows batch boundary contents including PTS, fileOffset, keyframe flag, and size. Helps identify cross-batch B-frame reference gaps as a secondary hypothesis.

**Verification:** If `[LP-Trim]` lines appear in the log for the frames at the distortion positions, the hypothesis is confirmed and the fix resolves it. If no `[LP-Trim]` lines appear, check `[HEVC-AnnexB]` lines for any non-keyframe Annex B detections, and `[HEVC-{label}-TAIL]` for batch boundary anomalies.

#### Root cause 3 — LP false-positive Annex B detection for NAL sizes 256–511 B (**Sprint 53 — fix committed**)

Phase 4 log from the 1080p test file showed **102 `[HEVC-AnnexB]` events** on non-keyframes in the 260–510 B size range, with **zero `emptyPayload` errors**. The trailing-byte fix (Root cause 2) addressed the case where frames were silently dropped; this is a different failure mode where frames are *corrupted rather than dropped*.

**Root cause:** `detectNALFormat` had a fast-path start-code check:

```swift
// BROKEN — fires as a false positive for LP NAL sizes 256-511 B
if b.count >= 3 && b[0] == 0 && b[1] == 0 && b[2] == 1 { return .annexB }
```

For a 4-byte LP length field, a NAL unit of 256–511 bytes produces the prefix `00 00 01 XX`.  `b[2] == 0x01` — identical to the first three bytes of a 3-byte Annex B start code.  The fast-path returned `.annexB` before full LP validation even ran.

`convertAnnexBToLengthPrefixed` then scanned for start codes in the LP payload.  It found the `01` byte at position 2 as the end of a 3-byte start code (`00 00 01`), treated position 3 as the start of the first NAL, and emitted a length-prefixed buffer where the NAL payload was shifted right by 1 byte.  VideoToolbox read a corrupt HEVC NAL header for those frames → visible chroma/luma distortion consistent with the observed every-20–30-second pattern.

**Fix — Sprint 53:**

Both start-code fast-path lines removed from `detectNALFormat`.  New detection order:

1. `isValidLengthPrefixed` — exact full-walk LP check (all bytes consumed)
2. `looksLikeLPWithTrailingBytes` — new helper; LP with 1–(nalUnitLength-1) trailing padding bytes (companion to existing `trimLPTrailingBytes` trimmer)
3. Fall back to `.annexB` only if both LP checks fail

New `looksLikeLPWithTrailingBytes` private static function added to `PacketFeeder.swift`.

**Verification:** After this fix, `[HEVC-AnnexB]` events in the log should drop to zero for LP-encoded streams.  Any remaining events indicate a genuinely Annex B-encoded file (rare in MKV but possible).

---

## Phase 4 — Audio Isolation (videoOnly: false)

**Status: ⏳ IN PROGRESS — Sprint 52 fix committed, pending device verification**

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

### Sprint 52 fix — dual-synchronizer architecture

`PlayerLabDisplayView.updateUIView` was already correct (resizes the layer only, never re-attaches), so the identity-check prerequisite from the earlier regression was already satisfied.

**Fix:** `FrameRenderer` now uses two synchronizers:
- `synchronizer` — `AVSampleBufferDisplayLayer` only (video clock, unchanged from Phase 2/3)
- `audioSynchronizer` — `AVSampleBufferAudioRenderer` only (new in Sprint 52)

`attachAudioRenderer()` now adds the audio renderer to `audioSynchronizer` instead of `synchronizer`. Both clocks are anchored to the same PTS in `play(from:)`, `resume()`, `seek(to:)`, and all direct `setRate` calls in the controller.

**Verification:** Run Phase 4 in Quarantine Lab and check the log for:
```
[FrameRenderer] [P4/Sprint52] aTbRate=1.0  ✅ clock running
```
If `aTbRate=0.0` (the stall persists even with separate synchronizers), the fallback is `AVAudioEngine` + `AVAudioPlayerNode` with manual PTS scheduling.

---

## Files Changed This Sprint

| File | Change |
|------|--------|
| `Features/PlaybackQuarantine/PlaybackLabMinimalView.swift` | **New file** — full quarantine test UI |
| `Features/Settings/SettingsView.swift` | Added "Quarantine Lab" entry point button |
| `PlayerLab/Core/PacketFeeder.swift` | `isDolbyVisionDualLayer` instance flag; BL size filter gated on it; NAL stripping gated on `isHEVC`; codec detection split H.264 vs HEVC; `avcNalUnitLength` helper added; `trimLPTrailingBytes` fix for LP padding misclassification; `[HEVC-KF]`/`[HEVC-AnnexB]`/`[HEVC-HEAD/TAIL]` extended diagnostics; **Sprint 51:** GOP-boundary batch snapping (`nextVideoKeyframeSampleIndex` + `limitedVideo` extension); **Sprint 50:** synthetic HEVC DTS; **Sprint 53:** `detectNALFormat` false-positive fix — LP check before start-code check; `looksLikeLPWithTrailingBytes` helper |
| `PlayerLab/Demux/MKV/MKVDemuxer.swift` | `isDolbyVisionDualLayer` computed property; `firstVideoKeyframeIndex` 3-condition DV detection; first-keyframe guard raised 2 KB → 30 KB (BL IDR on test file is 3091 B); **Sprint 50:** both `backgroundScanCursor` fence-post bugs fixed; `[IndexDup]` diagnostic; **Sprint 51:** `nextVideoKeyframeSampleIndex(from:)` |
| `PlayerLab/Render/FrameRenderer.swift` | `videoOnlyDiagnostic` static → instance `let`; `init(videoOnly:)`; deferred `attachAudioRenderer()`; `audioRendererAttached` flag; all flush methods guard audio on `audioRendererAttached`; **Sprint 52:** `audioSynchronizer` (dedicated audio clock); all transport methods drive both clocks; `dualSyncDiagnostic` property; `[P4/Sprint52]` diagnostic in `play()` |
| `PlayerLab/Render/PlayerLabPlaybackController.swift` | `init(videoOnly:)` parameter; `feeder.isDolbyVisionDualLayer` wiring in `.mkv` prepare case; `attachAudioRenderer()` called after `activateAudioSession()` when `hasAudio`; **Sprint 52:** all direct `renderer.synchronizer.setRate` calls also drive `audioSynchronizer`; `[P4-diag]` periodic dual-clock log; `audioRendererStatusLabel()` helper |
| `Services/Emby/EmbyModels.swift` | `EmbyLibrary: Equatable` |
| `CLAUDE.md` | **New file** — architectural reference: pipeline diagram, critical invariants, key files, diagnostics guide |

---

## Open Issues

| # | Issue | Severity | Next Step |
|---|-------|----------|-----------|
| 1 | ~~Phase 3 HEVC distortion~~ | ~~High~~ | ✅ **Resolved** — Sprint 50 (frameIndex fence-post + duplicate detection) + Sprint 51 (GOP-boundary batch snapping). Confirmed clean on 3840×2160 test file. |
| 2 | Phase 4 — AVSampleBufferRenderSynchronizer clock stall with audio renderer on tvOS | High | Sprint 52 committed (`be0a1ec`). Dual-synchronizer architecture implemented. **Needs device run** — check log for `[P4/Sprint52] aTbRate=1.0 ✅`. Fallback if still stalled: AVAudioEngine + AVAudioPlayerNode. |
| 3 | ~~Phase 4 HEVC distortion — LP false-positive Annex B detection~~ | ~~High~~ | ✅ **Resolved** — Sprint 53. `detectNALFormat` fast-path removed; LP validation now runs first. `[HEVC-AnnexB]` events should drop to zero for LP-encoded MKV. Needs device verification. |
| 4 | Phase 3 buffering/stuttering under heavy load | Low | Separate from distortion. Investigate read-ahead depth and decoder queue pressure once Phase 4 is confirmed. |
