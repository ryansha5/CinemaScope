import AVFoundation
import Combine

// MARK: - Playback State

enum PlaybackState: Equatable {
    case idle
    case loading
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

    // MARK: - Load

    func load(url: URL) {
        if let token = timeObserver {
            player.removeTimeObserver(token)
            timeObserver = nil
        }

        playbackState   = .loading
        videoDimensions = nil
        aspectBucket    = .unclassified
        currentTime     = 0
        duration        = 0

        print("[PlaybackEngine] Loading URL: \(url.absoluteString)")

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        observeStatus(of: item)
        observeDimensions(of: item)
        observeTime()
    }

    // MARK: - Transport

    func play()  { player.play();  playbackState = .playing }
    func pause() { player.pause(); playbackState = .paused  }

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

    // MARK: - Private: observation

    private func observeStatus(of item: AVPlayerItem) {
        statusObserver = item.publisher(for: \.status)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    print("[PlaybackEngine] ✅ readyToPlay")
                    // Read duration
                    let asset = item.asset
                    Task {
                        do {
                            let dur = try await asset.load(.duration)
                            let secs = dur.seconds
                            if secs.isFinite && secs > 0 {
                                await MainActor.run { self.duration = secs }
                                print("[PlaybackEngine] ⏱ Duration: \(secs)s")
                            } else {
                                print("[PlaybackEngine] ⚠️ Duration unavailable: \(dur)")
                            }
                        } catch {
                            print("[PlaybackEngine] ⚠️ Duration load error: \(error)")
                        }
                    }
                    self.play()

                case .failed:
                    let msg = item.error?.localizedDescription ?? "Unknown error"
                    let underlying = (item.error as NSError?)?.userInfo[NSUnderlyingErrorKey] as? NSError
                    print("[PlaybackEngine] ❌ Failed: \(msg)")
                    print("[PlaybackEngine] ❌ Underlying: \(underlying?.localizedDescription ?? "none")")
                    print("[PlaybackEngine] ❌ Full error: \(String(describing: item.error))")
                    self.playbackState = .failed(msg)

                case .unknown:
                    print("[PlaybackEngine] ⏳ Status unknown")
                default:
                    break
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
                print("[PlaybackEngine] 📐 \(dims.debugDescription)")
                print("[PlaybackEngine] 🎬 \(bucket.label) → \(self.presentationMode.label)")
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
}
