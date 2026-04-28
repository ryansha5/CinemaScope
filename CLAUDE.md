# CinemaScope — Codebase Context for AI Assistants

## Project overview

CinemaScope is a tvOS media player backed by an Emby server. The app has two
playback stacks:

1. **AVPlayer (legacy)** — used for HLS streams and as a fallback for unsupported
   audio codecs.  Entry point: `PlaybackEngine`.

2. **PlayerLab custom pipeline (active development)** — a fully custom
   MKV demux → decode → render stack that operates below AVPlayer.  Currently
   isolated behind the Quarantine Lab feature flag (Settings → PlayerLab →
   Quarantine Lab).  Entry points: `PlaybackLabMinimalView`,
   `PlayerLabPlaybackController`.

---

## PlayerLab custom pipeline — architecture

```
Emby HTTP byte-range stream
        │
        ▼
  MediaReader            (IO/MediaReader.swift)
        │
        ▼
  MKVDemuxer             (PlayerLab/Demux/MKV/)
  • Parses EBML/Matroska clusters, builds frameIndex
  • Incremental background indexing (continueIndexing)
        │
        ▼
  PacketFeeder           (PlayerLab/Core/PacketFeeder.swift)
  • Reads raw block data from MKVDemuxer
  • Constructs CMSampleBuffers (video + audio)
  • Manages streaming cursors (nextVideoSampleIdx, nextAudioSampleIdx)
  • GOP-boundary batch snapping (Sprint 51)
        │
        ▼
  FrameRenderer          (PlayerLab/Render/FrameRenderer.swift)
  • AVSampleBufferDisplayLayer  ←── synchronizer (video clock)
  • AVSampleBufferAudioRenderer ←── audioSynchronizer (audio clock, Sprint 52)
        │
        ▼
  PlayerLabPlaybackController  (PlayerLab/Render/PlayerLabPlaybackController.swift)
  • Orchestrates prepare → feedWindow → play → rolling feed loop
  • Seek, buffering detection, background index extension
```

**Supporting extractors (Spring Cleaning refactor):**
- `ContainerPreparation` (SC2) — container routing + parse
- `VideoFormatFactory` (SC3A) — CMVideoFormatDescription construction
- `AudioFormatFactory` (SC1) — CMAudioFormatDescription construction
- `BufferPolicy` (SC6) — watermark thresholds
- `SubtitleSetupCoordinator` (SC5) — SRT + PGS subtitle wiring

---

## Proven working (as of Sprint 52)

| Phase | Content | Status |
|-------|---------|--------|
| 1 | AVPlayer baseline (H.264, Emby HLS) | ✅ PASS |
| 2 | Custom pipeline — H.264 MKV, videoOnly | ✅ PASS |
| 3 | Custom pipeline — HEVC MKV, videoOnly | ✅ PASS — all distortion resolved |
| 4 | Custom pipeline — HEVC + AAC audio | ⏳ Sprint 52 committed, pending device run |

Test file for Phase 3: 3840×2160 HEVC MKV (3:10 to Yuma 4K, 76 GB).
All distortion resolved — no corruption at any point in the file.

---

## CRITICAL INVARIANTS — do not break these

### 1. Decode order: fileOffset sort within every batch

`PacketFeeder.fetchPackets` sorts each video batch by `fileOffset` before
enqueuing.  MKV stores blocks in decode order; PTS order is display order.
B-frames have lower PTS than the P-frames they depend on.  VideoToolbox
requires decode order.  **Removing the fileOffset sort causes deterministic
B-frame corruption.**

Location: `PacketFeeder.fetchPackets` — the `sorted(by: { $0.fileOffset < $1.fileOffset })`
call on the video batch.

### 2. GOP-boundary batch snapping (Sprint 51)

Every video batch fed to VideoToolbox must end at a GOP boundary (IDR frame).
If a batch boundary lands mid-GOP, B-frames in the current batch reference
P-frames that are in the *next* batch.  Those P-frames haven't been decoded yet,
so VT produces deterministic chroma corruption at the same positions every run.

`PacketFeeder.fetchPackets` calls `MKVDemuxer.nextVideoKeyframeSampleIndex(from:)`
to extend each batch to the next IDR.  **Removing this extension causes
HEVC chroma corruption at GOP boundaries (~every 20–30 seconds).**

Location: `PacketFeeder.fetchPackets` — the `if let mkv = mkvDemuxer, videoIsHEVC { ... }`
GOP-snap block.

### 3. backgroundScanCursor must advance past the parsed cluster

`MKVDemuxer` indexes clusters incrementally.  `backgroundScanCursor` must
advance by `headerBytes + payloadSize` (past the cluster just parsed), NOT
just to the cluster start.  The fence-post bug (Sprint 50) caused every
cluster to be re-parsed on the next call, duplicating all its frames in
`frameIndex`.  Duplicate frames produce the same corruption symptoms as
missing frames.

Locations:
- `scanClusters()` early-exit path: `backgroundScanCursor = cursor + clusterTotal`
- `continueIndexing()` post-loop: only updates cursor when `!didEarlyExit`

### 4. Dolby Vision dual-layer detection and BL frame filtering

For DV Profile 7 dual-layer MKV, the first cluster contains BL-only skip frames
(~110–3091 B) that a standard HEVC decoder cannot process.  These must be
detected and filtered before reaching VideoToolbox.

- `MKVDemuxer.isDolbyVisionDualLayer` detects DV P7 via `firstVideoKeyframeIndex`
  (checks that inter-frames between the first two IDRs are tiny BL skip frames,
  with a 30 KB guard on the first keyframe size to avoid false positives).
- `PacketFeeder.isDolbyVisionDualLayer` receives this flag from the controller.
- The BL size filter in `PacketFeeder.fetchPackets` is gated on
  `isHEVC && stripDolbyVisionNALsEnabled && isDolbyVisionDualLayer`.
  **Never apply the BL filter to non-DV HEVC** — legitimate HEVC frames in
  static scenes can be under 600 B.

### 5. Audio on dedicated audioSynchronizer, NOT the video synchronizer (Sprint 52)

`AVSampleBufferRenderSynchronizer.setRate(1)` silently fails on tvOS when both
`AVSampleBufferDisplayLayer` and `AVSampleBufferAudioRenderer` are attached to
the same synchronizer — the underlying CMTimebase stays at rate=0.

`FrameRenderer` uses two synchronizers:
- `synchronizer` — video display layer only
- `audioSynchronizer` — audio renderer only (attached via `attachAudioRenderer()`)

**Never add `audioRenderer` to `synchronizer`** — this was the original Phase 4
bug and is confirmed unreliable on tvOS.

---

## Key file locations

```
CinemaScope/PlayerLab/
  Core/
    PacketFeeder.swift          — fetch + enqueue pipeline, GOP-snap, DV filter
    BufferPolicy.swift          — watermark thresholds (SC6)
    ContainerPreparation.swift  — container routing (SC2)
  Demux/
    MKV/
      MKVDemuxer.swift          — EBML parse, frameIndex, incremental indexing
  Decode/
    VideoFormatFactory.swift    — CMVideoFormatDescription (SC3A)
  Audio/
    AudioFormatFactory.swift    — CMAudioFormatDescription (SC1)
  Render/
    FrameRenderer.swift         — AVSampleBufferDisplayLayer + dual synchronizers
    PlayerLabPlaybackController.swift — orchestrator
    PlayerLabDisplayView.swift  — UIViewRepresentable host (identity-safe updateUIView)
  Subtitle/
    SubtitleSetupCoordinator.swift  — SRT + PGS wiring (SC5)

CinemaScope/Features/PlaybackQuarantine/
  PlaybackLabMinimalView.swift  — two-panel tvOS test UI (sidebar + player)
                                   controller (videoOnly:true)  = Phase 2/3
                                   audioController (videoOnly:false) = Phase 4
```

---

## Diagnostics guide

### Log prefixes to watch

| Prefix | Meaning |
|--------|---------|
| `[IndexDup]` | MKV frame-index duplication check — must show `✅ no duplicate file offsets` |
| `[fetchPackets] GOP-snap` | Batch extended to next IDR — normal, expected every ~24 frames |
| `[HEVC-KF]` | Every HEVC keyframe: PTS, fileOffset, size, NAL type list |
| `[HEVC-AnnexB]` | HEVC frame where detectNALFormat returned .annexB — investigate if frequent |
| `[LP-Trim]` | LP trailing bytes trimmed — expected on some encoders |
| `[P4/Sprint52]` | Audio dual-sync diagnostic — `aTbRate=1.0` is the pass condition |
| `[P4-diag]` | Periodic A/V drift — should stay within ±20 ms |
| `[Prepare]` | `isDolbyVisionDualLayer=true/false` — verify DV detection on DV files |
| `[IndexTask]` | Background MKV indexing progress |
| `[Buffer]` | Underrun / recovery events |

### Log file location (device/simulator)

```bash
find /Users/$(whoami)/Library/Developer/CoreSimulator -name 'playerlab.log' 2>/dev/null
# Then copy to avoid mount-cache stale reads:
cp <found-path> ~/Documents/CinemaScope/logs/playerlab_latest.log
```

---

## Phase 4 — pending verification

Sprint 52 (committed as `be0a1ec`) implements the dual-synchronizer fix.
To verify, run Phase 4 in Quarantine Lab and check the log immediately after
hitting Play:

**Pass:** `[FrameRenderer] [P4/Sprint52] aTbRate=1.0 ... ✅ clock running`

**Fail:** `[FrameRenderer] [P4/Sprint52] aTbRate=0.0 ... ❌ clock still stalled`

If it fails, the fallback path is `AVAudioEngine` + `AVAudioPlayerNode` with
manual PTS scheduling (avoids `AVSampleBufferAudioRenderer` entirely).

---

## Emby integration

- `EmbyAPI.rawStreamURL` with `Static=true` produces a direct byte-range stream
  (no transcoding, no HLS segmenting).  The custom pipeline requires this URL.
- `EmbyAPI.playbackURL()` produces the HLS/transcoded URL used by Phase 1 AVPlayer.
- All API calls use `session.server`, `session.user`, `session.token`.
