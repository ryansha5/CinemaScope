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

**Never remove `.id(pending.id)` from the `PlayerLabHostView` call in the ZStack.**
Without it, SwiftUI reuses the same view instance when `pendingLabPlay` changes from
`PendingLabPlay(A)` to `PendingLabPlay(B)` without passing through `nil` (e.g. a rapid
second play tap, a retry, or any code path that overwrites `pendingLabPlay` directly).
Reuse means `@StateObject private var controller` is not recreated and `.task` (which
has no `id:`) does not rerun — `prepare()` is never called for session B and the stale
controller from session A silently persists.  The `.id(pending.id)` forces a full
view+controller destroy+recreate whenever the session UUID changes.

Locations:
- `HomeView.body` — `if let pending = pendingLabPlay` block inside the root `ZStack`;
  the `PlayerLabHostView` call has `.id(pending.id)` and passes `sessionID: pending.id`.
- `PlayerLabHostView` — `let sessionID: UUID` input; `.task(id: url)` for defense-in-depth
  (restarts the task if `url` ever changes while the view is alive, even if identity holds).

### Sprint 68 — videoOnly=true: skip activateAudioSession to prevent synchronizer interference

**Root cause hypothesis:** `PlayerLabPlaybackController.prepare()` called `activateAudioSession()` unconditionally whenever `hasAudio=true`, including when `renderer.videoOnlyDiagnostic=true` (the default for `PlayerLabHostView`). Changing the system `AVAudioSession` category to `.playback / .moviePlayback` immediately before `feedWindow`'s `enqueueVideo` calls has been observed to interfere with `AVSampleBufferRenderSynchronizer` clock startup on tvOS — the synchronizer's timebase can remain at `rate=0` after `setRate(1)` if an audio route-change notification arrives during the setup window.

**Why Phase 2/3 worked:** Those tests used files with no audio track (`hasAudio=false`) or the audio classification result was `.fallbackToAVPlayer` — meaning `activateAudioSession` was never reached. H.264/AC3/PGS files via `PlayerLabHostView` expose this path for the first time: AC3 is classified as direct-playback, `hasAudio=true`, and `activateAudioSession()` fires during the critical pre-play window.

**Fix:** `activateAudioSession()` and `startAudioEngine()` are now gated on `!renderer.videoOnlyDiagnostic`. When `videoOnly=true`, both calls are skipped and a diagnostic log line is emitted instead. The video synchronizer setup is now identical to Phase 2/3 regardless of whether the file has an audio track.

**Diagnostics added:**
- `[play-check]` log line fires synchronously in `play()` (same run-loop turn) showing `layer.status`, `isReadyForMoreMediaData`, `pendingQ`, `framesEnqueued`, `tbRate`, `tbTime`, and `videoOnly` — the definitive snapshot of renderer state when playback starts.
- `PlayerLabHostView .task END (play() called)  state=X` includes the controller state label right after `play()` so the log shows if the state is immediately `.playing` or if something transitioned it.

**Never call `activateAudioSession()` when `renderer.videoOnlyDiagnostic=true`** — it changes the audio session category with no benefit and risks interfering with the video synchronizer during the critical pre-play window on tvOS.

Locations:
- `PlayerLabPlaybackController.prepare()` — `if hasAudio && !renderer.videoOnlyDiagnostic` guard replacing the unconditional `if hasAudio` block
- `PlayerLabPlaybackController.play()` — `[play-check]` diagnostic block after `renderer.play(from:)`
- `PlayerLabHostView.task` — updated `.task END` log includes `state=\(controller.state.statusLabel)`

### Sprint 69 — Logging gap: controller/renderer fputs invisible in Xcode console

**Root cause:** `PlayerLabLog.setup()` calls `freopen()` to redirect stderr to
`playerlab.log`.  After the redirect, Xcode console only shows stdout (`print()`).
`PlayerLabPlaybackController.record()` and all `FrameRenderer` diagnostic fputs calls
wrote to stderr only → they went to the log file but were completely invisible during
Xcode debugging sessions.  `sessionLog()` in `PlayerLabHostView` always wrote to both
`print()` AND `fputs(stderr)`, so `[Session]` lines appeared in Xcode console and gave
the false impression that controller/renderer logs were also visible.

**Fix:**
- `record()` in `PlayerLabPlaybackController` now calls both `fputs(stderr)` and
  `print()`.  ALL `[PlayerLabPlaybackController]` lines are now visible in Xcode console.
- `FrameRenderer.frLog(_:)` — new private helper that also calls both fputs and print.
  Key lifecycle lines (`init`, `play(from:)`, `pause()`, `resume()`, `flushAll()`,
  `flushForSeek()`, `startAudioEngine` pass/fail, `First frame enqueued`,
  `playerNode.play()`) were migrated to `frLog()`.
- `PacketFeeder.enqueueAndAdvance` — the sample-0 enqueue confirmation now also
  calls `print()` so it is visible in Xcode console.

**Never revert `record()` or `frLog()` back to stderr-only** — the logging gap made
`[PlayerLabPlaybackController]` and `[FrameRenderer]` lines completely invisible during
debugging for the entire duration of Sprints 67 and 68, blocking diagnosis.

Locations:
- `PlayerLabPlaybackController.record()` — `print(line)` added after `fputs`
- `FrameRenderer.frLog(_:)` — new private helper (replaces direct `fputs` calls)
- `PacketFeeder.enqueueAndAdvance` — sample-0 guard now also calls `print()`

### Sprint 70 — H.264/AC3 MKV freeze: DV false positive + buffering indexer starvation

**Root cause A — False-positive `isDolbyVisionDualLayer` on H.264 content:**
`MKVDemuxer.isDolbyVisionDualLayer` fired `true` for a H.264 Friends TV episode.
Dolby Vision Profile 7 dual-layer MKV is always HEVC — H.264 is never DV P7.
The detection false-positives on H.264 files whose first cluster contains many small
non-keyframes (long open-GOP before the first IDR; typical for TV content at 24fps).
This triggered `firstIDRVideoKeyframeIndex(from: firstKF)` which scanned ahead 116
frames, forcing the cursor to start at frame 140 (PTS≈5.8s) instead of frame 0.
With only 208 frames in the initial index window, starting at 140 left only 68 frames.
After any seek to later in the file, the buffer immediately underran.

**Fix A:** In `prepare()`, gate both the false-positive clear and the DV preamble block
on `videoTrack.isHEVC`. Two-step approach:
1. If `feeder.isDolbyVisionDualLayer && !videoTrack.isHEVC` → clear the flag and log.
2. `if let mkv = mkvDemuxer, videoTrack.isHEVC, feeder.isDolbyVisionDualLayer` — the
   preamble scan and cursor advance only run when the codec is confirmed HEVC.

**Never apply the DV BL preamble scan or cursor advance to H.264 content.**

**Root cause B — Background indexer never triggered from `.buffering` state:**
When the buffer underruns (state → `.buffering`), the refill block spins calling
`feedWindow(340 frames)` which returns 0 new frames because `cursor=videoSamplesTotal`.
The Sprint 57 cursor-exhausted guard that calls `triggerBackgroundIndex` lives *after*
the `.buffering` return block and is never reached while in `.buffering` state.  The
indexer stays idle indefinitely → permanent freeze.

**Fix B:** Inside the `.buffering` refill block, after `feedWindow` returns, check if
`cursor >= total && !isFullyIndexed` and call `triggerBackgroundIndex` if so.

**Never omit the cursor-exhausted indexer trigger from the `.buffering` block** — it is
the only path that fires when an underrun occurs while the index is still incomplete.

Locations:
- `PlayerLabPlaybackController.prepare()` — `if feeder.isDolbyVisionDualLayer && !videoTrack.isHEVC` clear block; `if let mkv = mkvDemuxer, videoTrack.isHEVC, feeder.isDolbyVisionDualLayer` preamble block
- `PlayerLabPlaybackController` feed loop — cursor-exhausted `triggerBackgroundIndex` call inside the `.buffering` refill block

### Sprint 71 — Indexer starvation: feeder totals not updated until full scan completes

**Root cause — `feeder.videoSamplesTotal` only updated at end of full `continueIndexing` scan:**
`triggerBackgroundIndex` called `continueIndexing(untilSeconds: target)` as a single call.
For a typical target of `indexedDurationSeconds + 60.0` (60-second window), scanning
~116 MB of cluster headers over a 2.67 GB file at LAN speeds takes 7–8 seconds.  During
this entire window, `feeder.videoSamplesTotal` showed the OLD value (208 frames), so the
feed loop kept calling `feedWindow` → returned 0 frames → buffer stayed empty → visible
freeze lasting 7–8 s after every buffer underrun.  Additionally, `indexedDurationSeconds`
was only updated at the end of `continueIndexing`, making the feed loop's `indexedDur`
log always show 8.6s throughout the scan — indistinguishable from a genuine hang.

**Fix A — Incremental 15-second steps in `triggerBackgroundIndex`:**
Rewrote `triggerBackgroundIndex` as a loop of `continueIndexing(untilSeconds: step)` calls
with `step = indexedDurationSeconds + 15.0`.  After each step, `feeder.videoSamplesTotal`
is updated immediately.  The feed loop sees new frames after ~1–2 seconds (first step)
instead of waiting 7–8 s for the full scan.  Recovery from underrun drops from ~8 s to <1 s.

**Fix B — Incremental `indexedDurationSeconds` updates inside `continueIndexing`:**
Added `indexedDurationSeconds = frameIndex.last?.pts.seconds ?? indexedDurationSeconds`
after every cluster's `backgroundScanCursor = cursor + total` line.  The feed loop's
`indexedDur=Xs` log now shows real-time progress, not a frozen 8.6s throughout the scan.

**Fix C — Early-start background indexing from `PlayerLabHostView.task`:**
`controller.startEarlyBackgroundIndexing()` is called immediately after `prepare()`
succeeds and before the resume seek.  This gives the indexer a head start while the
seek's HTTP pre-fetch executes.  By the time play() is called and the initial buffer
drains, the indexer has already completed one or more steps — making recovery nearly
instantaneous when the underrun fires.

**Fix D — Full-file scan targets:**
Both `triggerBackgroundIndex` call sites that previously used `indexedDurationSeconds + 60.0`
now use `feeder.duration` (full file) as the target.  The incremental steps handle
bandwidth throttling naturally; a full-file target ensures the indexer eventually covers
any seek destination without needing re-triggering.

**Never revert `triggerBackgroundIndex` to a single `continueIndexing` call** — this
restores the 7–8 s freeze.  **Never remove the `startEarlyBackgroundIndexing()` call
from `PlayerLabHostView.task`** — without it, the indexer has no head start and the first
underrun always causes a visible multi-second freeze.

Locations:
- `MKVDemuxer.continueIndexing` — `indexedDurationSeconds = frameIndex.last?.pts.seconds ?? …` after `backgroundScanCursor = cursor + total`
- `PlayerLabPlaybackController.triggerBackgroundIndex` — incremental while-loop with 15s steps; updates feeder totals after each step
- `PlayerLabPlaybackController.startEarlyBackgroundIndexing()` — new public method, targets `feeder.duration`
- `PlayerLabHostView.task` — `controller.startEarlyBackgroundIndexing()` after seek and before play() (Sprint 72 fix)

### Sprint 72 — Three post-71 fixes: early-start cancellation, nil-element logging, PENDING-LAG false underruns

**Root cause A — `startEarlyBackgroundIndexing()` cancelled by seek:**
Sprint 71 called `startEarlyBackgroundIndexing()` before `seek(toFraction:)`.  `seek()`
calls `stopFeedLoop()` which does `backgroundIndexTask?.cancel(); backgroundIndexTask = nil`.
The early-start task immediately saw `Task.isCancelled=true` and returned `(0,0)` — the
indexer got zero head start.  Log evidence: `[IndexTask] 🚀 early-start → ...` then
`[IndexTask] ✅ done → 8.6s  +0v/+0a  target reached` after every seek.

**Fix A:** Moved `startEarlyBackgroundIndexing()` to AFTER `seek(toFraction:)` in
`PlayerLabHostView.task`, immediately before `controller.play()`.  At that point,
`stopFeedLoop()` has already fired and there is no subsequent cancellation.

**Never place `startEarlyBackgroundIndexing()` before the seek** — the seek will cancel
the task before it can do any work.

**Root cause B — `continueIndexing` breaking silently on `nextElement` nil:**
When `parser.nextElement(at: cursor, limit:)` returns nil (HTTP failure or cursor
alignment issue), the while loop breaks immediately with no log.  The outer
`triggerBackgroundIndex` loop retries on the next cycle but still hits the same nil,
producing many `[IndexTask] ✅ done → 8.6s  +0v/+0a` lines without diagnosis.

**Fix B:** Added a `log(...)` call in the `else { break }` branch in
`continueIndexing`'s while loop to record `cursor`, `limit`, `clusterCount`, and
current indexed duration.  If the same cursor appears many times, it is a cursor
alignment bug; if it appears once and then scanning advances, it is a transient HTTP
failure.

**Root cause C — PENDING-LAG false underruns causing choppy playback:**
After a large `feedWindow` call loads 300+ frames into `pendingVideoQueue`, the
`requestMediaDataWhenReady` callback hasn't yet had a chance to drain them to the layer
(both run on the main thread; the callback runs between feed-loop iterations, not
inline).  `actualBuffered` reads 0 (the layer holds nothing past the current clock)
while `optimisticBuffered` = 5.71 s (270 frames in pendingVideoQueue, all with PTS
AHEAD of the clock).  The old underrun check (`actualBuffered < 0.5 s`) fires
unconditionally, enters `.buffering`, pauses the clock, and triggers a redundant
refill — producing the "freeze → play a little → freeze again" choppy pattern.

**Fix C:** `bufferForUnderrunCheck` replaces the bare `actualBuffered` in the underrun
condition.  When `pendingQ > 0 && optimisticBuffered > underrunThreshold`, the pending
frames have future PTS and will drain to the layer via the callback imminently, so
`optimisticBuffered` is used for the check instead of `actualBuffered`.  When
`pendingQ = 0` (pipeline truly empty), `actualBuffered` is used as before.  A new
`checkBuf=` field in the `[Buffer] UNDERRUN` log shows which value triggered the check.

**Never suppress underrun detection when pendingQ=0** — an empty pipeline with
`actualBuffered = 0` is a real underrun and the clock must be paused.

Locations:
- `PlayerLabHostView.task` — `startEarlyBackgroundIndexing()` moved to after `seek()`, before `play()`
- `MKVDemuxer.continueIndexing` — `log(...)` in the `nextElement` nil `else { break }` branch
- `PlayerLabPlaybackController` feed loop — `bufferForUnderrunCheck` replaces `actualBuffered` in underrun condition; `checkBuf=` added to `[Buffer] UNDERRUN` log

### Sprint 73 — Immediate underrun on seek fallback: startup buffer too thin

**Root cause — seek to partially-indexed position leaves < 1 s of buffer:**
After seek to 1165 s (85% of file), `findVideoKeyframeSampleIndex` falls back to the
last keyframe in the 8.6 s startup index (~frame 192, PTS ~8.0 s).  The seek pre-fetch
uses `initialWindowSeconds = 3.0 s` and tries to load 3 s from frame 192, but only ~16
frames exist between frame 192 and `videoSamplesTotal = 208` → **0.67 s of buffer
after seek**.  Clock starts at 8.0 s, drains 0.67 s later → real underrun → `.buffering`
within the first second of playback, every time.

**Root cause detail — `initialWindowSeconds` also caps the seek pre-fetch:**
`seek()` uses `policy.initialWindowSeconds` as the target for its Phase-1 pre-fetch
(`fetchPackets(videoCount: feeder.videoSamplesFor(seconds: initialWindowSeconds), ...)`).
Raising `initialWindowSeconds` from 3 s → 10 s gives a larger pre-fetch target, but the
actual frames loaded are still capped by the cursor position vs. `videoSamplesTotal`.
The fix for the cursor exhaustion case is `waitForStartupBuffer()`.

**Fix A — Raise `initialWindowSeconds` from 3.0 → 10.0 s in BufferPolicy:**
For all cases where the index DOES cover the target (non-seek startup, or seeks early
in the file), this doubles the pre-play buffer and eliminates the immediate LOW WATERMARK
refill on the first feed-loop tick.  The initial feedWindow loads up to 10 s before
`prepare()` returns `.ready`.

**Fix B — Add `startupBufferSeconds = 12.0 s` to BufferPolicy:**
Set above `lowWatermarkSeconds` (10 s) so that after `waitForStartupBuffer()` completes,
the first feed-loop tick does NOT immediately see LOW WATERMARK and trigger a competing
refill while the clock is already running.

**Fix C — Add `waitForStartupBuffer()` to PlayerLabPlaybackController:**
Called from `PlayerLabHostView.task` AFTER `startEarlyBackgroundIndexing()` and BEFORE
`play()`.  Polls at 200 ms, calling incremental `feedWindow` top-ups whenever the
background indexer has made new frames available, until `buffer >= startupBufferSeconds`
or the 15 s timeout fires.  The 200 ms sleeps are suspension points that give the
`@MainActor` background-index Task execution windows between iterations.

**Fix D — `[Buffer] UNDERRUN` log now includes `feederTail=` and `layerTail=`:**
Absolute PTS values of the feeder's last-enqueued frame and the display layer's
last-accepted frame.  Combined with `checkBuf=` (Sprint 72), these three fields
fully characterise whether an underrun is real (both tails at clock) or a pending-lag
false alarm (feederTail well ahead of clock).

**Never call `play()` immediately after `startEarlyBackgroundIndexing()`** without
first calling `await controller.waitForStartupBuffer()`.  On any seek that falls back
to the partially-indexed region, the buffer is < 1 s and the clock will underrun
within that first second.

Locations:
- `BufferPolicy.initialWindowSeconds` — raised 3.0 → 10.0
- `BufferPolicy.startupBufferSeconds` — new constant 12.0
- `PlayerLabPlaybackController.waitForStartupBuffer()` — new async method; polling top-up loop
- `PlayerLabHostView.task` — `await controller.waitForStartupBuffer()` inserted between
  `startEarlyBackgroundIndexing()` and `play()`
- `PlayerLabPlaybackController` feed loop — `feederTail=` and `layerTail=` added to
  `[Buffer] UNDERRUN` log

### Sprint 74 — pendingVideoQueue accumulation: freeze/distortion at predictable intervals

**Root cause — `requestMediaDataWhenReady` fires ~every 2 s on tvOS simulator:**
The callback that drains `pendingVideoQueue` to `AVSampleBufferDisplayLayer` runs on
`DispatchQueue.main`.  The feed loop also runs on `@MainActor`.  Swift tasks have higher
scheduling priority than GCD callbacks on the tvOS simulator, so the callback fires
~every 2 s (not ~every frame).  Each LOW WATERMARK refill adds 195–267 frames to
`pendingVideoQueue` while the callback drains only ~50 frames per 2 s cycle.
`pendingQ` accumulated to 499–555 frames.  When the clock reached the end of the
layer's 2 s accepted window, the layer ran dry briefly → all 499 pending frames dumped
at once → visible freeze + distortion at predictable positions (~19 s, ~34 s, ~36 s
with constant timing every run).

**Diagnostic evidence from user log:**
```
[feed] t=35.5s  buf=1.4s  optBuf=11.7s  tbRate=1.00  pendingQ=499  lag=10.30s  framesEnq=739
[feed] t=36.6s  buf=10.6s  optBuf=10.6s  tbRate=1.00  pendingQ=0   lag=0.00s   framesEnq=1238
```
`framesEnq` jumped from 739 → 1238 (+499) in one 100 ms feed cycle — all 499 pending
frames reached the layer at once when it ran dry at t=35.5–36.6 s.

**Fix — proactive drain in the feed loop:**
`FrameRenderer.proactiveDrainPending()` is a public wrapper around the private
`drainVideoQueue()`.  Called from `PlayerLabPlaybackController.feedIfNeeded()` on every
tick (~100 ms) when `pendingQ > 0`.  At 25 fps, the feed loop drains ~2.5 frames per
100 ms interval — same rate as content playback — so `pendingQ` stays near zero and
the layer is continuously supplied without waiting for the ~2 s callback.

**Auto-export on disappear:**
`PlayerLabHostView.onDisappear` now calls `exportLog()` automatically so the log is
always saved even when the player freezes and the manual Export button is unreachable.

**Never remove `proactiveDrainPending()` from the feed loop** — without it, `pendingQ`
accumulates on the tvOS simulator and every refill cycle produces visible distortion
at the predictable interval where the layer runs dry.

**Never rely solely on `requestMediaDataWhenReady` to drain `pendingVideoQueue`** on
tvOS — the callback fires too infrequently when the feed loop is the dominant main-thread
occupant.

Locations:
- `FrameRenderer.proactiveDrainPending()` — new public wrapper around `drainVideoQueue()`
- `PlayerLabPlaybackController` feed loop — `if pendingQ > 0 { renderer.proactiveDrainPending() }` before underrun check
- `PlayerLabHostView.onDisappear` — `exportLog()` call added for auto-export on freeze/dismiss

### Sprint 75 — LOW WATERMARK refill races clock when network ≈ content bitrate

**Root cause — LOW WATERMARK refill with critically-low actualBuf causes speed-up + freeze:**
After Sprint 74's proactive drain emptied `pendingVideoQueue`, `optimisticBuffered` dropped to match `actualBuffered` (~1.5 s).  LOW WATERMARK fired at `optBuf=1.11s < 10s` and started a 424-frame HTTP fetch.  At 15.8 Mbps content on a ~16 Mbps LAN, the fetch took ~17 seconds of wall time.  The clock advanced from 22.5 s to 40.21 s during the fetch.  All 374 queued frames (PTS 24–40 s) reached the layer simultaneously and were rendered as a rapid speed-up, after which the buffer was empty again → freeze.

**Root cause B — Background indexer competing for HTTP bandwidth:**
The background indexer made concurrent HTTP range-requests for cluster headers during the LOW WATERMARK refill, reducing effective bandwidth to the refill by 2–4× and inflating the 17-second delay further.

**Fix A — Skip LOW WATERMARK proactive refill when `actualBuf < policy.resumeThreshold`:**
When the real buffer is already below resumeThreshold (1.5 s), a long HTTP fetch will always let the clock outrun the feeder tail.  The LOW WATERMARK guard now `return`s early with a diagnostic log, allowing the UNDERRUN check to fire on a subsequent tick.  UNDERRUN pauses the clock (`rate=0`) BEFORE the fetch — so the display shows a clean still frame, the fetch completes, and the clock resumes from the exact paused PTS without any speed-up or position jump.

**Fix B — Cancel background indexer before `await feedWindow()` in both LOW WATERMARK and `.buffering`:**
The indexer is cancelled immediately before the HTTP fetch in both code paths.  Cancellation frees the LAN connection for the refill's bulk sequential reads, reducing refill time by 2–4×.  The proactive indexer trigger in the next feed-loop iteration restarts the indexer once the buffer has recovered.

**Never allow a LOW WATERMARK proactive refill when `actualBuffered < policy.resumeThreshold`** — on bandwidth-constrained networks the clock always outpaces the fetch and the speed-up/freeze pattern recurs deterministically.

**Never omit `cancelBackgroundIndex()` before `await feedWindow()` in the LOW WATERMARK and `.buffering` blocks** — the indexer competes for HTTP bandwidth and inflates refill time.

Locations:
- `PlayerLabPlaybackController` LOW WATERMARK block — `guard actualBuffered >= policy.resumeThreshold` early-return; `cancelBackgroundIndex()` before `await feedWindow()`
- `PlayerLabPlaybackController` `.buffering` block — `cancelBackgroundIndex()` before `await feedWindow()`

### Sprint 76 — Seek snaps to wrong position + distortion at refill boundaries

**Bug 1 root cause — seek resolves against incomplete MKV index:**
`seek(toFraction:)` called `findVideoKeyframeSampleIndex(nearestBeforePTS:)` directly against an index that only covered 8.6 s of a 1364 s file.  The nearest keyframe before PTS 1165 s in that tiny index was frame 186 at PTS 7.758 s.  The seek silently snapped there, so the user always resumed from near the start of the episode instead of the intended 85% position.

**Fix — `ensureMKVIndexedForSeek()` called at the top of `seek(toFraction:)`:**
New private async helper.  Before resolving any keyframe, it extends the MKV index until `indexedDurationSeconds >= targetSeconds + max(2.0, initialWindowSeconds)` (or the file is fully indexed).  Index extension runs in 60-second incremental steps so the @MainActor scheduler stays responsive.  Feeder totals are refreshed after each step.  A delta-warning log fires if the resolved keyframe is still > 30 s from the target (transient HTTP failure or genuine sparse index).

**Never call `findVideoKeyframeSampleIndex` on the MKV path without first calling `ensureMKVIndexedForSeek`** — the startup index covers only the first ~8–10 s and any seek beyond that region silently clamps to the last indexed keyframe.

**Bug 2 root cause — buffering recovery used optimistic feeder tail:**
The `.buffering` recovery check was `let newBuf = feeder.lastEnqueuedVideoPTS - now; if policy.isRecovered(newBuf)`.  `feeder.lastEnqueuedVideoPTS` advances the moment frames enter `pendingVideoQueue`, not when the layer accepts them.  With `pendingQ = 234` and `actualBuf = 1.5 s`, `newBuf` could read 12 s → `isRecovered()` returned true → clock resumed → clock immediately outpaced the shallow layer tail → distortion at every refill boundary.

**Fix A — Recovery gated on actual layer tail:**
`canResume = actualRecoveredBuf >= resumeThreshold`.  `actualRecoveredBuf` is derived from `renderer.actualLayerEnqueuedMaxPTS` — the last PTS the layer physically accepted.  Recovery waits until the layer genuinely has headroom.  (Sprint 76 originally also required `pendingLag2 < 1.0 && pendingQ2 < 24`; those conditions were removed in Sprint 77 — see below.)

**Fix B — `PlayerLabHostView` was creating controller with `videoOnly: true` (default):**
The production player was in video-only diagnostic mode for all content, silently skipping audio session activation and audio engine start.  Changed to `PlayerLabPlaybackController(videoOnly: false)`.

**Never use `feeder.lastEnqueuedVideoPTS` (optimistic) for buffering recovery or underrun suppression** — use `renderer.actualLayerEnqueuedMaxPTS` (actual) instead.

Locations:
- `PlayerLabPlaybackController.ensureMKVIndexedForSeek(_:windowSeconds:)` — new helper; called at top of `seek(toFraction:)`
- `PlayerLabPlaybackController.seek(toFraction:)` — `ensureMKVIndexedForSeek` call + delta-warning log
- `PlayerLabPlaybackController` `.buffering` recovery — `canResume` gates on `actualRecoveredBuf` only
- `PlayerLabHostView` — `PlayerLabPlaybackController(videoOnly: false)` explicit

### Sprint 77 — Pending-lag stall gate causes permanent deadlock

**Root cause — stall gate fires immediately after play() on every startup:**
Sprint 76's `criticalPendingLag` block entered `.buffering` and set `rate=0` whenever
`actualBuffered < resumeThreshold && pendingLag > 1.0 && pendingQ > 24`.  This fired
on the very first feed-loop tick after `play()` because the startup buffer load
(`waitForStartupBuffer`) leaves ~240 frames in `pendingVideoQueue` (lag ~10 s,
`actualBuf ~1.5 s`).  With the clock paused, `framesEnq` never advanced, and the
`.buffering` refill loop kept adding ~47 frames per cycle → `pendingQ` grew from
241 → 2145 without bound.  The `canResume` condition also had `pendingQ2 < 24` which
the refill loop actively prevented from ever being met → permanent `.buffering` freeze.

**Why this was wrong:** The large pendingQ immediately after play() is expected and
benign.  `proactiveDrainPending()` (Sprint 74) drains the queue at ~2.5 frames per
100 ms feed-loop tick — the same rate as content playback.  The layer does not run
dry while the queue is being drained continuously; no clock intervention is needed.

**Fix A — Remove the stall-transition block entirely:**
The entire `criticalPendingLag` path (which set `rate=0` and called
`transition(to: .buffering, ...)`) has been deleted.  In its place: a log-only
`⚠️ PENDING-LAG` warning when `pendingLag > 1.0 && actualBuffered < resumeThreshold`.
True underruns (actualBuf below underrunThreshold) are still caught by the unchanged
`bufferForUnderrunCheck` block further down the feed loop.

**Fix B — Remove `pendingQ2 < 24` and `pendingLag2 < 1.0` from `canResume`:**
The `.buffering` recovery condition is now simply `actualRecoveredBuf >= resumeThreshold`.
After the clock resumes, `proactiveDrainPending()` clears the pending backlog within
a few hundred milliseconds — no pre-resume gate on queue depth is needed.

**Never add a `.buffering` stall transition based on `pendingQ` or `pendingLag` alone** —
the pending queue is naturally large immediately after any large buffer pre-load
(startup, seek, or refill), and a clock-pause at that moment creates a feedback loop
that grows pendingQ unboundedly.

**Never gate `canResume` on `pendingQ < N`** — the `.buffering` refill loop adds frames
on every cycle, so any fixed pendingQ threshold is unreachable from inside .buffering.

Locations:
- `PlayerLabPlaybackController` feed loop — `criticalPendingLag` block removed; replaced with log-only `⚠️ PENDING-LAG`
- `PlayerLabPlaybackController` `.buffering` recovery — `canResume` simplified to `actualRecoveredBuf >= policy.resumeThreshold`

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

### Where to read logs — IMPORTANT

`PlayerLabLog.setup()` calls `freopen()` to redirect **stderr** to `playerlab.log`.
After that redirect, Xcode console shows **stdout** (`print()`) only.

**Sprint 69 fix:** `record()` in `PlayerLabPlaybackController` and `frLog()` in
`FrameRenderer` now write to BOTH stderr (→ file) AND stdout (→ Xcode console).
`[Session]` lines from `PlayerLabHostView.sessionLog()` always wrote to both; all
other controller/renderer lines were stderr-only and were invisible in Xcode console.

After the fix, `[PlayerLabPlaybackController]` and `[FrameRenderer]` lines appear
directly in the Xcode console alongside `[Session]` lines.  You should no longer
need to read the log file for normal debugging.

The file is still written for crash post-mortem:

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
