import SwiftUI
import UIKit

// MARK: - ImageCache
//
// NSCache-backed in-memory image store shared across the app session.
// Avoids redundant network fetches when the same poster/backdrop URL
// is visited while scrolling or navigating back to a viewed item.

@MainActor
final class ImageCache {

    static let shared = ImageCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit      = 300              // max images
        cache.totalCostLimit  = 150 * 1024 * 1024  // 150 MB
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        // Approximate byte cost: width × height × scale² × 4 channels
        let cost = Int(image.size.width * image.size.height
                       * image.scale * image.scale * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }

    func purge() { cache.removeAllObjects() }
}

// MARK: - CachedAsyncImage
//
// Drop-in replacement for AsyncImage that checks ImageCache before hitting
// the network. Images are stored on successful download so subsequent
// presentations render from memory without any flash or reload.
//
// Usage exactly mirrors AsyncImage:
//
//   CachedAsyncImage(url: someURL) { image in
//       image.resizable().scaledToFill()
//   } placeholder: {
//       Color.gray.opacity(0.2)
//   }

struct CachedAsyncImage<Content: View, Placeholder: View>: View {

    let url:         URL?
    @ViewBuilder let content:     (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var loadedImage: UIImage? = nil
    @State private var task:        Task<Void, Never>? = nil

    var body: some View {
        Group {
            if let img = loadedImage {
                content(Image(uiImage: img))
            } else {
                placeholder()
            }
        }
        .onAppear  { startLoadIfNeeded() }
        .onChange(of: url) { _, _ in startLoadIfNeeded() }
        .onDisappear { /* keep task running — image warms the cache */ }
    }

    // MARK: - Private

    private func startLoadIfNeeded() {
        guard let url else { loadedImage = nil; return }

        // Fast path: already in memory cache
        if let cached = ImageCache.shared.image(for: url) {
            loadedImage = cached
            return
        }

        // Cancel any prior in-flight task for a previous URL
        task?.cancel()
        task = Task { @MainActor in
            await fetch(url: url)
        }
    }

    @MainActor
    private func fetch(url: URL) async {
        // Re-check cache inside the async context (may have been filled
        // by another concurrent load for the same URL)
        if let cached = ImageCache.shared.image(for: url) {
            loadedImage = cached
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            if let img = UIImage(data: data) {
                ImageCache.shared.store(img, for: url)
                loadedImage = img
            }
        } catch {
            // Network errors or cancellation — stay on placeholder
        }
    }
}

// MARK: - Convenience overloads

extension CachedAsyncImage where Placeholder == Color {
    /// Minimal init: just `content` closure, `.clear` placeholder.
    init(url: URL?, @ViewBuilder content: @escaping (Image) -> Content) {
        self.init(url: url, content: content) { Color.clear }
    }
}
