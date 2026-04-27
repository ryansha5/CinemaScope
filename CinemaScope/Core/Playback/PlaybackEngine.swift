import AVFoundation
import Combine

// MARK: - Playback State

enum PlaybackState: Equatable {
    case idle
    case loading
    case retrying(String)   // message shown during automatic fallback attempt
    case playing
    case paused
    case failed(String)
}

// MARK: - Video Dimensions

struct VideoDimensions: Equatable {
    let width: Int
    let height: Int

    var aspectRatio: Double {
        guard height > 0 else { return 0 }
        return Double(width) / Double(height)
    }

    var debugDescription: String {
        String(format: "%d × %d  (%.4f : 1)", width, height, aspectRatio)
    }
}

// MARK: - PlaybackEngine

@MainActor
final class PlaybackEngine: ObservableObject {

    // MARK: - Published state

    @Published private(set) var playbackState:      PlaybackState = .idle
    @Published private(set) var videoDimensions:    VideoDimensions? = nil
    @Published private(set) var aspectBucket:       AspectBucket = .unclassified
    @Published              var presentationMode:   PresentationMode = .fullScreen
    @Published private(set) var aspectRatioOverride: AspectRatioOverride = .auto
    @Published private(set) var detectedContentRatio: Double? = nil
    @Published private(set) var currentTime:        Double = 0
    @Published private(set) var duration:           Double = 0
    /// True when ≤ 12 seconds remain — triggers the autoplay countdown overlay.
    @Published private(set) var nearingEnd:         Bool   = false

    // MARK: - Audio track state
    //
    // Populated from the Emby MediaSource after PlaybackInfo is fetched.
    // The OSD audio picker will bind to these when implemented.
    // `selectedAudioTrackIndex` is the Emby stream index handed to PlaybackInfo,
    // either chosen automatically or overridden by the user via selectAudioTrack().

    /// All audio tracks available for the current item.
    @Published private(set) var availableAudioTracks: [AvailableAudioTrack] = []
    /// The Emby stream index that was actually requested (automatic or explicit).
    @Published private(set) var selectedAudioTrackIndex: Int? = nil

    // MARK: - Effective content ratio
    //
    // This is the SINGLE source of truth for the video's aspect ratio.
    // Priority: user override > black-bar detection > metadata dimensions.
    //
    // ScopeCanvasGeometry reads this value — nothing else touches raw dimensions.

    var effectiveContentRatio: Double {
        // 1. User override (highest priority)
        if let fixed = aspectRatioOverride.fixedRatio { return fixed }
        // 2. Black-bar detection
        if let detected = detectedContentRatio { return detected }
        // 3. Raw container/presentation metadata
        return videoDimensions?.aspectRatio ?? AspectBucket.scopeRatio
    }

    // MARK: - Scope UI context (set before each load via setPlaybackContext)

    private(set) var scopeUIEnabled: Bool = false
    private var serverURL:           String = ""
    private var itemId:              String = ""

    // MARK: - AVFoundation

    private(set) var player: AVPlayer = AVPlayer()
    private var dimensionObserver:     AnyCancellable?
    private var statusObserver:        AnyCancellable?
    private var timeObserver:          Any?
    private var pendingStartTicks:     Int64 = 0
    private var blackBarDetectionTask: Task<Void, Never>? = nil

    // MARK: - Progress reporting context

    private var reportingServer:        EmbyServer? = nil
    private var reportingToken:         String?     = nil
    private var reportingItemId:        String?     = nil
    private var reportingUserId:        String?     = nil
    private var reportingSessionId:     String      = UUID().uuidString
    private var reportingMediaSourceId: String      = ""
    private var reportingPlayMethod:    String      = "Transcode"
    private var progressReportTimer:    Timer?      = nil
    private var hasReportedStart                    = false

    // MARK: - Retry context

    private var retryHandler: (() async -> Void)? = nil

    // MARK: - Diagnostic context (for HTTP 500 / transcode failure logging)

    private var diagnosticItemName: String = ""
    private var diagnosticIsRetry:  Bool   = false
    private var currentURL:         URL?   = nil

    // MARK: - Playback context (must be called before load())

    /// Set the UI context so the engine can choose the correct default viewport.
    /// Also loads any persisted aspect ratio override for this item.
    func setPlaybackContext(scopeUIEnabled: Bool, serverURL: String, itemId: String) {
        self.scopeUIEnabled = scopeUIEnabled
        self.serverURL      = serverURL
        self.itemId         = itemId
        // Restore any stored override (or .auto if none)
        self.aspectRatioOverride = AspectRatioStore.shared.override(
            serverURL: serverURL, itemId: itemId
        )
        print("[PlaybackEngine] context — scopeUI=\(scopeUIEnabled) item=\(itemId) override=\(aspectRatioOverride.label)")
    }

    // MARK: - Load

    func load(url: URL, startTicks: Int64 = 0) {
        stopProgressTimer()
        blackBarDetectionTask?.cancel()
        blackBarDetectionTask = nil

        if let token = timeObserver {
            player.removeTimeObserver(token)
            timeObserver = nil
        }

        playbackState           = .loading
        videoDimensions         = nil
        aspectBucket            = .unclassified
        detectedContentRatio    = nil
        currentTime             = 0
        duration                = 0
        nearingEnd              = false
        hasReportedStart        = false
        // Note: availableAudioTracks / selectedAudioTrackIndex are NOT cleared here.
        // setAvailableAudioTracks() is called before load() by HomeView; keeping
        // the previous values visible during the loading transition avoids a flicker
        // if the OSD is open while a retry load begins.

        // Mode follows UI setting — not aspect ratio
        presentationMode = PresentationMode.defaultMode(scopeUIEnabled: scopeUIEnabled)

        // Preserve any user override already set via setPlaybackContext
        // (aspectRatioOverride is NOT reset here)

        pendingStartTicks = startTicks
        currentURL = url
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        observeStatus(of: item)
        observeDimensions(of: item)
        observeTime()
    }

    /// Optional: provide a fallback handler called automatically on playback failure.
    func setRetryHandler(_ handler: @escaping () async -> Void) {
        retryHandler = handler
    }

    /// Set Emby progress-reporting context before load().
    func setReportingContext(
        server: EmbyServer, userId: String, token: String, itemId: String,
        mediaSourceId: String, playSessionId: String, playMethod: String
    ) {
        reportingServer        = server
        reportingToken         = token
        reportingItemId        = itemId
        reportingUserId        = userId
        reportingSessionId     = playSessionId
        reportingMediaSourceId = mediaSourceId
        reportingPlayMethod    = playMethod
    }

    // MARK: - Diagnostic info (must be set before each load())

    /// Records item identity and retry state so the engine can emit a rich
    /// HTTP 500 / transcode-failure log without the caller needing to catch it.
    func setDiagnosticInfo(itemName: String, isRetry: Bool) {
        diagnosticItemName = itemName
        diagnosticIsRetry  = isRetry
    }

    // MARK: - Audio track management

    /// Populates the available track list from the Emby MediaSource.
    /// Call this after a successful PlaybackInfo fetch, before load().
    /// `selectedIndex` is the stream index that was actually requested —
    /// either the automatic fallback pick or a previously-stored override.
    func setAvailableAudioTracks(_ tracks: [AvailableAudioTrack], selectedIndex: Int?) {
        availableAudioTracks   = tracks
        selectedAudioTrackIndex = selectedIndex
        let names = tracks.map { t in
            "\(t.streamIndex):\(t.label)\(t.isDefault ? "*" : "")"
        }.joined(separator: ", ")
        print("[PlaybackEngine] audio tracks: [\(names)] selected=\(selectedIndex.map{"\($0)"} ?? "auto")")
    }

    /// Placeholder for the future OSD audio track picker.
    /// Stores the selection to `AudioTrackStore` so it persists across sessions.
    /// The caller is responsible for re-requesting PlaybackInfo with the new
    /// AudioStreamIndex and reloading the engine.
    func selectAudioTrack(at streamIndex: Int) {
        selectedAudioTrackIndex = streamIndex
        if !serverURL.isEmpty {
            AudioTrackStore.shared.setOverride(
                .explicit(streamIndex: streamIndex),
                serverURL: serverURL,
                itemId:    itemId
            )
        }
        print("[PlaybackEngine] audio track selected: index=\(streamIndex) — caller must reload with new PlaybackInfo")
    }

    /// Returns any persisted audio track override for the current item,
    /// or nil if no override is stored (use automatic selection).
    func storedAudioTrackIndex() -> Int? {
        guard !serverURL.isEmpty else { return nil }
        return AudioTrackStore.shared.override(serverURL: serverURL, itemId: itemId).streamIndex
    }

    // MARK: - Aspect ratio override (called from OSD)

    /// Apply a user-selected aspect ratio override and persist it.
    func setAspectRatioOverride(_ override: AspectRatioOverride) {
        aspectRatioOverride = override

        // Persist so the same title is never mislabelled again
        if !serverURL.isEmpty {
            AspectRatioStore.shared.setOverride(override, serverURL: serverURL, itemId: itemId)
        }

        // Update the bucket badge to match the override (for OSD display)
        if let bucket = override.bucket {
            aspectBucket = bucket
        } else if let dims = videoDimensions {
            // Reset to what the classifier says from metadata
            let effectiveRatio = detectedContentRatio ?? dims.aspectRatio
            aspectBucket = AspectRatioClassifier.classify(effectiveRatio)
        }

        print("[PlaybackEngine] AR override set to \(override.label)")
    }

    // MARK: - Transport

    func play() {
        player.play()
        playbackState = .playing
        startProgressTimer()
        reportProgress(isPaused: false)
    }

    func pause() {
        player.pause()
        playbackState = .paused
        stopProgressTimer()
        reportProgress(isPaused: true)
    }

    func togglePlayPause() {
        switch playbackState {
        case .playing: pause()
        case .paused:  play()
        default: break
        }
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        let time = CMTime(seconds: fraction * duration, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        blackBarDetectionTask?.cancel()
        blackBarDetectionTask = nil
        stopProgressTimer()
        reportStop()
        player.pause()
        nearingEnd    = false
        playbackState = .idle
    }

    /// Cancel the nearing-end signal so the countdown won't re-appear after the user dismisses it.
    func suppressNearingEnd() {
        nearingEnd = false
    }

    // MARK: - Private: observation

    private func observeStatus(of item: AVPlayerItem) {
        statusObserver = item.publisher(for: \.status)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    if self.pendingStartTicks > 0 {
                        let seconds  = Double(self.pendingStartTicks) / 10_000_000.0
                        let seekTime = CMTime(seconds: seconds, preferredTimescale: 600)
                        self.player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
                        self.pendingStartTicks = 0
                    }
                    let asset = item.asset
                    Task {
                        if let dur = try? await asset.load(.duration),
                           dur.seconds.isFinite, dur.seconds > 0 {
                            await MainActor.run {
                                self.duration = dur.seconds
                                // Kick off black-bar detection once we have duration
                                self.scheduleBlackBarDetection(asset: asset, duration: dur.seconds)
                            }
                        }
                    }
                    self.reportStart()
                    self.play()

                case .failed:
                    let err   = item.error as NSError?
                    let msg   = item.error?.localizedDescription ?? "Unknown error"
                    let under = err?.userInfo[NSUnderlyingErrorKey] as? NSError
                    let code  = err?.code ?? 0
                    print("[PlaybackEngine] ❌ Error \(code): \(msg)")
                    print("[PlaybackEngine] ❌ Underlying: \(under?.localizedDescription ?? "none")")

                    if let retry = self.retryHandler {
                        print("[PlaybackEngine] 🔄 Retrying with fallback...")
                        self.retryHandler  = nil
                        self.playbackState = .retrying("Finding compatible format…")
                        Task { await retry() }
                        return
                    }

                    // ── HTTP 500 / transcode crash diagnostic dump ────────────────────
                    // -16847 = HTTP 500 from Emby's transcode endpoint.
                    // Extract key URL params so we can correlate server-side logs.
                    if code == -16847 || (under?.code == -16847) {
                        let urlParams  = self.urlQueryParams(self.currentURL)
                        let audioIdx   = urlParams["AudioStreamIndex"] ?? "?"
                        let videoCodec = urlParams["VideoCodec"]       ?? "?"
                        let audioCodec = urlParams["AudioCodec"]       ?? "?"
                        let path       = self.currentURL.flatMap { "\($0.path)" } ?? "?"
                        print("""
[PlaybackEngine] 💥 HTTP 500 TRANSCODE FAILURE REPORT
  Item:            \(self.diagnosticItemName) [\(self.reportingItemId ?? "?")]
  Path attempt:    \(self.diagnosticIsRetry ? "RETRY (forcedTranscodeURL)" : "PRIMARY")
  PlaySessionId:   \(self.reportingSessionId)
  URL AudioStreamIndex: \(audioIdx)
  URL VideoCodec:       \(videoCodec)
  URL AudioCodec:       \(audioCodec)
  URL path prefix:      \(path.prefix(120))
""")
                    }

                    let friendly: String
                    switch code {
                    case -11800:  friendly = "Cannot open this file. The server may be unreachable."
                    case -11850:  friendly = "Unsupported format. Check your Emby server transcoding settings."
                    case -11819, -11828: friendly = "Cannot decode this video on Apple TV."
                    case -16847:  friendly = "The server failed to transcode this file (HTTP 500). Check Emby logs."
                    default: friendly = msg
                    }
                    self.playbackState = .failed(friendly)

                default: break
                }
            }
    }

    private func observeDimensions(of item: AVPlayerItem) {
        dimensionObserver = item.publisher(for: \.presentationSize)
            .receive(on: RunLoop.main)
            .compactMap { size -> VideoDimensions? in
                guard size.width > 0, size.height > 0 else { return nil }
                return VideoDimensions(width: Int(size.width), height: Int(size.height))
            }
            .first()
            .sink { [weak self] dims in
                guard let self else { return }
                self.videoDimensions = dims
                // Classify the raw metadata ratio for badge display
                self.aspectBucket = AspectRatioClassifier.classify(dims.aspectRatio)
                // If the user has an override, apply its bucket instead
                if let overrideBucket = self.aspectRatioOverride.bucket {
                    self.aspectBucket = overrideBucket
                }
                // Mode is already set from scopeUIEnabled in load() — don't override it here
                print("[PlaybackEngine] dims=\(dims.debugDescription) bucket=\(self.aspectBucket.label) mode=\(self.presentationMode.label)")
            }
    }

    private func observeTime() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let secs = time.seconds
            if secs.isFinite { self.currentTime = secs }
            if self.duration == 0,
               let d = self.player.currentItem?.duration.seconds,
               d.isFinite, d > 0 {
                self.duration = d
            }
            if !self.nearingEnd,
               self.duration > 30,
               self.duration - self.currentTime <= 12 {
                self.nearingEnd = true
            }
        }
    }

    // MARK: - Black-bar detection

    private func scheduleBlackBarDetection(asset: AVAsset, duration: Double) {
        // Skip if user already has a manual override
        guard aspectRatioOverride == .auto else { return }

        blackBarDetectionTask = Task { [weak self] in
            guard let self else { return }
            guard let detected = await BlackBarDetector.detectFrom(
                asset: asset, duration: duration
            ) else {
                print("[PlaybackEngine] Black-bar detection: no bars found")
                return
            }

            guard !Task.isCancelled else { return }

            let metadataRatio = self.videoDimensions?.aspectRatio ?? 0
            let delta = abs(detected - metadataRatio) / max(metadataRatio, 0.001)

            // Only apply if the detected ratio differs from metadata by >5%
            // (avoids false positives from dark opening scenes)
            if delta > 0.05 {
                print("[PlaybackEngine] Black-bar detection: \(String(format: "%.3f", detected)) (metadata: \(String(format: "%.3f", metadataRatio))) — applying")
                await MainActor.run { [weak self] in
                    guard let self, self.aspectRatioOverride == .auto else { return }
                    self.detectedContentRatio = detected
                    self.aspectBucket = AspectRatioClassifier.classify(detected)
                }
            } else {
                print("[PlaybackEngine] Black-bar detection: \(String(format: "%.3f", detected)) — within 5%% of metadata, not applying")
            }
        }
    }

    // MARK: - Progress reporting

    private var currentPositionTicks: Int64 {
        Int64(currentTime * 10_000_000)
    }

    private func reportStart() {
        guard !hasReportedStart,
              let server = reportingServer,
              let token  = reportingToken,
              let itemId = reportingItemId,
              let userId = reportingUserId else { return }
        hasReportedStart = true
        let sid      = reportingSessionId
        let sourceId = reportingMediaSourceId
        let method   = reportingPlayMethod
        Task {
            await EmbyAPI.reportPlaybackStart(
                server: server, userId: userId, token: token,
                itemId: itemId, mediaSourceId: sourceId,
                playSessionId: sid, playMethod: method)
        }
    }

    private func reportProgress(isPaused: Bool) {
        guard let server = reportingServer,
              let token  = reportingToken,
              let itemId = reportingItemId else { return }
        let ticks    = currentPositionTicks
        let sid      = reportingSessionId
        let sourceId = reportingMediaSourceId
        let method   = reportingPlayMethod
        Task {
            await EmbyAPI.reportPlaybackProgress(
                server: server, token: token,
                itemId: itemId, mediaSourceId: sourceId,
                playSessionId: sid, playMethod: method,
                positionTicks: ticks, isPaused: isPaused)
        }
    }

    private func reportStop() {
        guard let server = reportingServer,
              let token  = reportingToken,
              let itemId = reportingItemId else { return }
        let ticks    = currentPositionTicks
        let sid      = reportingSessionId
        let sourceId = reportingMediaSourceId
        let method   = reportingPlayMethod
        Task {
            await EmbyAPI.reportPlaybackStop(
                server: server, token: token,
                itemId: itemId, mediaSourceId: sourceId,
                playSessionId: sid, playMethod: method,
                positionTicks: ticks)
        }
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressReportTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reportProgress(isPaused: false)
            }
        }
    }

    private func stopProgressTimer() {
        progressReportTimer?.invalidate()
        progressReportTimer = nil
    }

    // MARK: - URL diagnostic helpers

    /// Extracts query-string parameters from a URL into a [key: value] dictionary.
    /// Used for logging VideoCodec / AudioCodec / AudioStreamIndex on failure.
    private func urlQueryParams(_ url: URL?) -> [String: String] {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return [:] }
        return Dictionary(items.compactMap { item in
            guard let value = item.value else { return nil }
            return (item.name, value)
        }, uniquingKeysWith: { first, _ in first })
    }
}
