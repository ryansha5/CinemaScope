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

## Proven working (as of Sprint 57)

| Phase | Content | Status |
|-------|---------|--------|
| 1 | AVPlayer baseline (H.264, Emby HLS) | ✅ PASS |
| 2 | Custom pipeline — H.264 MKV, videoOnly | ✅ PASS |
| 3 | Custom pipeline — HEVC MKV, videoOnly | ✅ PASS — all distortion resolved |
| 4 | Custom pipeline — HEVC + AAC audio | ⏳ Sprint 57 in progress — gap-tolerant HTTP coalescing + zero-buffer refill fix |

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
to extend each batch to include the IDR frame at the next GOP boundary.
**The IDR must be the last frame in the batch by PTS — and the first by
fileOffset** (it is the forward-reference anchor for the tail B-frames).

Sprint 64 root-cause fix: the snap calculation uses `nextIDR + 1` so the
IDR itself is included in the batch.  Before Sprint 64 the formula was
`min(nextIDR, videoSamplesTotal)` which ended the batch at `nextIDR-1` —
one frame short.  The B-frames in the last mini-GOP (~12–16 frames) of
each GOP all reference the IDR as their forward anchor; without it VT
decoded them with a missing reference and produced deterministic corruption
at every GOP boundary (~19.5 s, ~29 s, ~39.8 s before the 20/30/40 s IDRs).

The next batch starts at `nextIDR + 1`.  VT's decoder state for
`AVSampleBufferDisplayLayer` persists across enqueue calls, so the IDR
decoded in batch N is available as a reference for batch N+1's inter-frames.

**Removing the +1 or reverting to `min(nextIDR, …)` reintroduces the
corruption at every GOP boundary.**

Location: `PacketFeeder.fetchPackets` — the `if let mkv = mkvDemuxer, videoIsHEVC { ... }`
GOP-snap block; the line `let extended = min(nextIDR + 1, videoSamplesTotal) - fromVideoIdx`.

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

### 6. NAL format detection: LP check must come before start-code check (Sprint 53)

`PacketFeeder.detectNALFormat` determines whether each video frame is Annex B
or length-prefixed (LP) before handing it to VideoToolbox.

**Never use a byte-prefix start-code fast-path before the LP validation.**

For LP streams with a 4-byte length field, a NAL unit of 256–511 bytes has
the LP prefix `00 00 01 XX`.  Bytes 0–2 match a 3-byte Annex B start code
(`00 00 01`).  If the code returns `.annexB` based on that byte pattern,
`convertAnnexBToLengthPrefixed` treats the `01` byte as the end of a 3-byte
start code, shifts the entire NAL payload by 1 byte, and produces a corrupt
HEVC NAL header.  VideoToolbox decodes the shifted bytes → visible distortion
on every frame in that size range (~260–510 B, typical of non-reference/skip
frames in low-motion scenes).

**Correct order:**
1. `isValidLengthPrefixed` — exact full-walk LP check (all bytes consumed)
2. `looksLikeLPWithTrailingBytes` — LP with 1–3 trailing alignment bytes
3. Fall back to `.annexB` only if both LP checks fail

### 8. Video must be fed via pull model — never push directly to AVSampleBufferDisplayLayer (Sprint 56)

`AVSampleBufferDisplayLayer.enqueue()` called while `isReadyForMoreMediaData=false` has **no effect** — the
frame is silently dropped.  Pushing a 285-frame batch in a tight loop saturates the layer's internal queue
at ~50 frames; all subsequent `enqueue()` calls are no-ops.  The dropped frames produce visible distortion
at deterministic positions (same frames every run because the same queue depth is reached every run).

`FrameRenderer.enqueueVideo(_:sampleIndex:)` uses the pull model:
1. Every incoming `CMSampleBuffer` is appended to `pendingVideoQueue`.
2. `drainVideoQueue()` feeds frames to the layer only while `isReadyForMoreMediaData == true`.
3. `ensureMediaCallbackRegistered()` registers `layer.requestMediaDataWhenReady(on: .main)` whenever the
   queue is non-empty and no callback is active.  The callback drains remaining frames as the layer
   consumes prior ones and cancels itself when the queue is empty.
4. All flush paths (`flushAll`, `flushVideo`, `flushForSeek`) clear `pendingVideoQueue` and reset
   `mediaCallbackActive = false` (after `flushAndRemoveImage()` has already cancelled the layer's callback).

**Never call `layer.enqueue()` directly outside `performLayerEnqueue()`** — always go through `enqueueVideo()`.

Location: `FrameRenderer` — `pendingVideoQueue`, `drainVideoQueue()`, `ensureMediaCallbackRegistered()`, `performLayerEnqueue()`.

### 9. AAC→PCM conversion must run off the main thread (Sprint 56)

`AVAudioConverter.convert()` is synchronous.  On the tvOS simulator it takes ~14 ms per AAC packet.
A 263-frame refill batch contains ~513 audio packets → calling `enqueueAudio()` in a tight loop blocks
the main thread for ~7 seconds.  During that 7 seconds, the display layer receives no new frames while
the video clock continues advancing, causing a buffer underrun of ~6 s and ~268 frames whose PTS is
"in the past" when the layer finally sees them — the layer discards them → visible distortion.

`FrameRenderer.enqueueAudio(_:)` dispatches conversion to a private **serial** `DispatchQueue`
(`audioConversionQueue`, QoS `.userInteractive`).  Converted PCM buffers are scheduled onto
`AVAudioPlayerNode` from that same queue.  The serial queue preserves in-order scheduling even
if individual conversions vary in duration.  `AVAudioPlayerNode.scheduleBuffer` is thread-safe.

**Never call `AVAudioConverter.convert()` on the main thread** during a bulk refill cycle.

Location: `FrameRenderer.audioConversionQueue`, `FrameRenderer.enqueueAudio(_:)`.

### 7. EBML lacing must be handled for audio (Sprint 55)

`MKVDemuxer.makeAudioFrames` handles all four Matroska lacing types:
- `0` = no lacing (one frame per block)
- `1` = Xiph lacing
- `2` = fixed-size lacing
- `3` = EBML lacing — **implemented in Sprint 55**

Before Sprint 55, type 3 fell to `default: return []` and those audio blocks were
silently dropped from `audioFrameIndex`.  The lacing-bit fix in Sprint 54 correctly
identified EBML blocks (flags=0x06 → bits [2:1] = 0b11 = 3) but since EBML parsing
wasn't implemented, the audio index ended up nearly empty (≈37% of expected).  The
symptom was `playerNode` running out of PCM buffers after ~2s and going silent for
the remainder of each refill cycle.

**Never remove the `case 3` branch in `makeAudioFrames`** — EBML lacing is widely
used in Matroska audio tracks (especially as an alternative to Xiph for multi-frame
blocks).

Location: `MKVDemuxer.parseEBMLLacedAudio` — the Sprint 55 implementation.

### 10. Gap-tolerant HTTP run coalescing in extractPackets (Sprint 57)

`MKVDemuxer.extractPackets` coalesces consecutive frame locations into single
HTTP byte-range requests.  In interleaved MKV files, consecutive video (or audio)
frames are NOT file-contiguous — they are separated by blocks from the other track
(typically ~4–16 KB of EBML-laced AAC per video frame gap).

The original exact-contiguity check (`c.fileOff == p.fileOff + p.size`) treated every
such interleaving boundary as a run break, producing one HTTP request per frame.
For a 285-frame refill batch at ~35 ms/request on the tvOS simulator, this meant
~10 s per refill.  The video clock advanced 10 s while the refill ran; when
frames finally arrived, their PTS was "in the past" → `AVSampleBufferDisplayLayer`
discarded them silently → deterministic visual distortion at every refill boundary,
at the same frames every run.

**Fix:** coalesce frames whose start-of-next minus end-of-current gap is ≤
`kMaxRunGapBytes` (1 MB).  This collapses an entire refill batch into 1–2 HTTP
requests (~500 ms total).  The fetched chunk contains interleaved data from the
other track; only the target-track frames are extracted via the existing `sliceOff`
logic — interleaved bytes are ignored.

**Never reduce `kMaxRunGapBytes` below the maximum possible interleaving gap** for
the file type in use.  For typical AAC-interleaved HEVC MKV the gap is 4–16 KB.
1 MB provides a large safety margin without meaningfully inflating request sizes
(1 MB overhead per 10-second window is negligible).  **Never revert to the
exact-contiguity check** — it was the root cause of deterministic late-frame
discards across all interleaved files.

Location: `MKVDemuxer.extractPackets` — `kMaxRunGapBytes` constant and the inner
run-building `while` loop.

### 11. Feed loop must return early when cursor is exhausted but indexing is incomplete (Sprint 57)

When the background MKV indexer is still running, `feeder.nextVideoSampleIdx` can
reach `feeder.videoSamplesTotal` before the file is fully indexed.  In that state,
calling `feedWindow` returns 0 frames immediately and re-triggers the LOW WATERMARK
check on the same iteration — creating a tight zero-buffer spin loop that fires many
times per second while the buffer drains visibly.

**Fix:** in the feed loop, check `feeder.nextVideoSampleIdx >= feeder.videoSamplesTotal`
AND `!mkv.isFullyIndexed` *before* the LOW WATERMARK block.  If true, log the state,
re-trigger background indexing if the task isn't already running, then `return` early.
The normal underrun handler (`.buffering` transition + clock pause) takes over cleanly
if the buffer drains to the 0.5 s underrun threshold before the indexer catches up.

**Never fall through to the LOW WATERMARK block** in this state — the tight loop
drains the buffer faster than the indexer can refill it.

Location: `PlayerLabPlaybackController` feed loop — the cursor-exhausted early-return
guard immediately before the LOW WATERMARK threshold check.

### 5. Audio via AVAudioEngine — do NOT use AVSampleBufferAudioRenderer (Sprint 54)

`AVSampleBufferRenderSynchronizer.setRate(1)` is confirmed broken on tvOS for
audio on both simulator and real Apple TV hardware.  The underlying CMTimebase
stays at rate=0 regardless of whether the audio renderer shares a synchronizer
with the display layer or has a dedicated one (Sprint 52 dual-synchronizer
architecture confirmed this extends to the dedicated-synchronizer case too).

`FrameRenderer` uses `AVAudioEngine` + `AVAudioConverter` + `AVAudioPlayerNode`:

```
CMSampleBuffer (AAC/AC3/EAC3/DTS)  →  AVAudioConverter (compressed → Float32 PCM)
→  AVAudioPlayerNode (sequential scheduling)  →  AVAudioEngine  →  output
```

- `startAudioEngine(inputDesc: CMAudioFormatDescription)` initialises the stack
  (replaces `attachAudioRenderer()`).  Call after `AVAudioSession.setActive(true)`.
- `playerNode.play()` is called at the same wall-clock instant as
  `synchronizer.setRate(1, time: startPTS)` in `play(from:)`.
- `playerNode.stop()` is called in all flush paths to clear scheduled PCM buffers.
- `resumeAudioIfNeeded()` restarts the player after seek or underrun recovery.
- `pauseAudioPlayer()` pauses the player on underrun / EOS.

**Never use `AVSampleBufferAudioRenderer` or `AVSampleBufferRenderSynchronizer`
for audio on tvOS** — this is a confirmed platform bug with no known workaround
short of bypassing the entire AVSampleBuffer audio stack.

### Sprint 65 — AC3/EAC3/DTS channel layout requirement

`AudioFormatFactory.makeAC3` and `makeDTSCore` previously created
`CMAudioFormatDescription` objects with `layoutSize=0` (no channel layout).
`AVAudioFormat(cmAudioFormatDescription:)` returns an object with `sr=0/ch=0`
when the description has no layout — and `AVAudioConverter(from:to:)` then crashes
with `EXC_BAD_ACCESS` because it dereferences the nil layout pointer inside Apple's
framework.

**Fix:** all codec paths in `AudioFormatFactory` (`makeMPEG4AAC`, `makeAC3`,
`makeDTSCore`) now embed an explicit `AudioChannelLayout` via the shared
`channelLayoutTag(for:)` helper.  `startAudioEngine` also has a defensive
`sr > 0 && ch > 0` guard that logs and returns cleanly instead of crashing.

**Never create a `CMAudioFormatDescription` for audio without an embedded channel
layout if that description will be passed to `AVAudioFormat(cmAudioFormatDescription:)`.**

Locations: `AudioFormatFactory.channelLayoutTag(for:)`, `FrameRenderer.startAudioEngine`.

### Sprint 66 — DV P7 TV episode distortion: BL filter scope + CRA cold-start

Two root causes of distortion on Dolby Vision Profile 7 TV episodes (vs. DV P7 movies
that worked correctly):

**Root cause A — BL size filter applied beyond preamble:**
`PacketFeeder.fetchPackets` filtered any frame below `kDVBLFrameSizeThreshold` (600 B)
when `isDolbyVisionDualLayer=true`, including legitimate EL B-frames throughout the
entire file.  In a TV episode with a CRA keyframe at `firstVideoKeyframeIndex=24`, this
dropped 83 of 227 frames (37%) from the initial batch — the missing frames created decode
graph holes, which VideoToolbox rendered as wrong-color blocks and greyed-out backgrounds.

**Fix A:** `PacketFeeder.dvBLPreambleEndIndex` (set to `mkv.firstVideoKeyframeIndex` by
`prepare()`) gates the size filter.  The filter now only fires for frames whose index is
strictly less than `dvBLPreambleEndIndex` — the BL-only preamble cluster.  EL frames at
or beyond that index are never filtered by size regardless of their byte count.

**Root cause B — Cold-starting HEVC decoder at CRA_NUT:**
`firstVideoKeyframeIndex` returns the second keyframe in the file — the start of the EL
track.  On some DV P7 encodes this keyframe is CRA_NUT (HEVC NAL type 21) rather than
IDR_N_LP (type 20).  Cold-starting at a CRA without any prior decoder state causes RASL
leading-picture corruption from frame 1 (RASL frames reference the CRA's pre-roll
context which doesn't exist when starting cold).

**Fix B:** `MKVDemuxer.firstIDRVideoKeyframeIndex(from:)` fetches the first 8 bytes of
each candidate keyframe and checks the HEVC NAL unit type.  If the EL boundary is a CRA,
it advances to the next keyframe and repeats until finding an IDR_N_LP (up to
`maxKeyframesToCheck=6` keyframes before falling back).  `prepare()` calls this instead
of using `firstVideoKeyframeIndex` directly as the cursor start.

**Never apply the DV BL size filter to frames at or beyond `dvBLPreambleEndIndex`.**
**Never cold-start the HEVC decoder at a CRA_NUT keyframe** — always find the nearest
IDR_N_LP at or after the EL boundary.

Locations:
- `PacketFeeder.dvBLPreambleEndIndex` — property + gating condition in `fetchPackets`
- `MKVDemuxer.videoFrameHEVCNALType(at:)` — small HTTP fetch to read NAL type
- `MKVDemuxer.firstIDRVideoKeyframeIndex(from:)` — scan for safe IDR start
- `PlayerLabPlaybackController.prepare()` — sets `dvBLPreambleEndIndex`, calls `firstIDRVideoKeyframeIndex`

### Sprint 67 — PlayerLabHostView never called: fullScreenCover .task lifecycle on tvOS

`HomeView` originally presented `PlayerLabHostView` via `.fullScreenCover(item: $pendingLabPlay)`.
On tvOS, the system modal presentation chain for `fullScreenCover` does not reliably complete —
the presented view's `.task` modifier never fires, so `prepare()` is never called.

**Fix:** `PlayerLabHostView` is now rendered directly inside `HomeView.body`'s root `ZStack`
as a conditional `if let pending = pendingLabPlay` overlay with `.zIndex(50)`.  This uses
SwiftUI's standard conditional-rendering lifecycle (view enters hierarchy → `.task` fires
immediately) which is fully reliable on tvOS.  The `fullScreenCover` modifier has been removed.

**Never re-introduce `.fullScreenCover` for `PlayerLabHostView` on tvOS** — the
`.task` lifecycle is broken for fullScreenCover on tvOS and prepare() will silently never run.

Location: `HomeView.body` — `if let pending = pendingLabPlay` block inside the root `ZStack`.

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
| `[P4/Sprint54]` | Audio engine start diagnostic — `isPlaying=true ✅ audio running` is the pass condition |
| `[P4-diag]` | Periodic audio state — `playerNode=▶ playing  audioEngine=✅ running` |
| `[S54]` | AAC→PCM converter errors — investigate if present |
| `[Prepare]` | `isDolbyVisionDualLayer=true/false` — verify DV detection on DV files |
| `[IndexTask]` | Background MKV indexing progress; `cursor exhausted but not fully indexed` = Sprint 57 early-return guard fired (normal for fast-indexing files) |
| `[Buffer]` | Underrun / recovery events |

### Log file location (device/simulator)

```bash
find /Users/$(whoami)/Library/Developer/CoreSimulator -name 'playerlab.log' 2>/dev/null
# Then copy to avoid mount-cache stale reads:
cp <found-path> ~/Documents/CinemaScope/logs/playerlab_latest.log
```

---

## Phase 4 — pending verification

Sprint 54 implements the AVAudioEngine audio path (Sprint 52 dual-synchronizer
confirmed broken on hardware; Sprint 54 replaces it entirely).

Sprint 56 fixes two frame-drop paths:
- Root cause 1: Direct `layer.enqueue()` calls while `isReadyForMoreMediaData=false` silently dropped
  frames.  Fixed with `pendingVideoQueue` + `requestMediaDataWhenReady` pull model.
- Root cause 2: Synchronous AAC→PCM conversion blocked the main thread, causing a buffer underrun
  and late frames.  Fixed with `audioConversionQueue` serial queue.

Sprint 57 fixes the dominant remaining distortion root cause:
- Root cause 3: Per-frame HTTP requests in interleaved MKV files.  Exact-contiguity run coalescing
  in `extractPackets` produced one HTTP request per video frame (~35 ms × 285 frames = ~10 s per
  refill).  The video clock advanced ~10 s during the refill; all frames arrived "late" → discarded.
  Fixed with gap-tolerant coalescing (`kMaxRunGapBytes = 1 MB`) → 1–2 bulk requests per refill (~500 ms).
- Root cause 4: Zero-buffer spin loop when cursor = videoSamplesTotal AND !isFullyIndexed.
  `feedWindow` returned 0 frames and immediately re-triggered LOW WATERMARK, spinning many times/second.
  Fixed with early `return` in the feed loop, falling through to underrun recovery if needed.

To verify, run Phase 4 in Quarantine Lab and check the log immediately after
hitting Play:

**Pass:**
```
[FrameRenderer] ✅ AVAudioEngine started (Sprint 54 audio path)  sr=48000Hz  ch=6
[FrameRenderer] [P4/Sprint54] playerNode.play()  isPlaying=true  ✅ audio running
[P4-diag] vTbRate=1.0  ...  audioEngine=✅ running  playerNode=▶ playing
```

**Fail — engine not starting:**
```
[FrameRenderer] ❌ AVAudioEngine start failed: <error>
```
→ Check the AVAudioSession activation log line.  Ensure `.playback / .moviePlayback`
  category is set and `setActive(true)` succeeded before `startAudioEngine` is called.

**Fail — converter error (no sound, no crash):**
```
[FrameRenderer] [S54] AAC→PCM convert error: <error>
```
→ The `CMAudioFormatDescription` may lack a valid AudioSpecificConfig.
  Check `[6] Building CMAudioFormatDescription` log in prepare().

---

## Emby integration

- `EmbyAPI.rawStreamURL` with `Static=true` produces a direct byte-range stream
  (no transcoding, no HLS segmenting).  The custom pipeline requires this URL.
- `EmbyAPI.playbackURL()` produces the HLS/transcoded URL used by Phase 1 AVPlayer.
- All API calls use `session.server`, `session.user`, `session.token`.
