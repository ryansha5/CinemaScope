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

    @Published private(set) var playbackState:    PlaybackState = .idle
    @Published private(set) var videoDimensions:  VideoDimensions? = nil
    @Published private(set) var aspectBucket:     AspectBucket = .unclassified
    @Published              var presentationMode: PresentationMode = .fitInsideScope
    @Published private(set) var currentTime:      Double = 0
    @Published private(set) var duration:         Double = 0

    private(set) var player: AVPlayer = AVPlayer()
    private var dimensionObserver: AnyCancellable?
    private var statusObserver:    AnyCancellable?
    private var timeObserver:      Any?
    private var pendingStartTicks: Int64 = 0

    // Reporting context — set before playback starts
    private var reportingServer:        EmbyServer? = nil
    private var reportingToken:         String?     = nil
    private var reportingItemId:        String?     = nil
    private var reportingUserId:        String?     = nil
    private var reportingSessionId:     String      = UUID().uuidString
    private var reportingMediaSourceId: String      = ""
    private var reportingPlayMethod:    String      = "Transcode"
    private var progressReportTimer:    Timer?      = nil
    private var hasReportedStart                    = false

    // Retry context — used for automatic fallback on failure
    private var retryHandler: (() async -> Void)? = nil

    // MARK: - Load

    func load(url: URL, startTicks: Int64 = 0) {
        stopProgressTimer()

        if let token = timeObserver {
            player.removeTimeObserver(token)
            timeObserver = nil
        }

        playbackState   = .loading
        videoDimensions = nil
        aspectBucket    = .unclassified
        currentTime     = 0
        duration        = 0
        hasReportedStart = false

        pendingStartTicks = startTicks
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        observeStatus(of: item)
        observeDimensions(of: item)
        observeTime()
    }

    /// Optional: provide a fallback handler called automatically on playback failure
    func setRetryHandler(_ handler: @escaping () async -> Void) {
        retryHandler = handler
    }

    /// Call this before load() to enable Emby progress reporting.
    /// Pass the PlaybackResult values so session/source IDs are correctly
    /// echoed back to Emby in all progress reports.
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
        stopProgressTimer()
        reportStop()
        player.pause()
        playbackState = .idle
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
                        let seconds = Double(self.pendingStartTicks) / 10_000_000.0
                        let seekTime = CMTime(seconds: seconds, preferredTimescale: 600)
                        self.player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
                        self.pendingStartTicks = 0
                    }
                    let asset = item.asset
                    Task {
                        if let dur = try? await asset.load(.duration),
                           dur.seconds.isFinite, dur.seconds > 0 {
                            await MainActor.run { self.duration = dur.seconds }
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

                    // If we have a retry handler, try it before showing error.
                    // Surface a .retrying state so the player shows feedback
                    // during the fallback window (typically 2–5 s).
                    if let retry = self.retryHandler {
                        print("[PlaybackEngine] 🔄 Retrying with fallback...")
                        self.retryHandler = nil   // clear to prevent infinite loop
                        self.playbackState = .retrying("Finding compatible format…")
                        Task { await retry() }
                        return
                    }

                    let friendly: String
                    switch code {
                    case -11800: friendly = "Cannot open this file. The server may be unreachable."
                    case -11850: friendly = "Unsupported format. Check your Emby server transcoding settings."
                    case -11819, -11828: friendly = "Cannot decode this video on Apple TV."
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
                let bucket = AspectRatioClassifier.classify(dims)
                self.aspectBucket     = bucket
                self.presentationMode = PresentationMode.automatic(for: bucket)
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
        // Report every 10 seconds during playback
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
}
