import AppKit

/// An extension's artwork. See docs/features/extensions.md for why it draws smaller than an app icon.
enum ExtensionIconCache {
    /// Below `IconCache.appIconExtent` on purpose; change it only against a rendered strip of icons.
    static let extent: CGFloat = 0.76

    /// `NSCache` is thread-safe but not `Sendable`, so assert the guarantee once here.
    private final class Cache: NSCache<NSString, NSImage>, @unchecked Sendable {}

    /// Its own budget, not the launcher's: Detail markdown caches images far larger than a row icon.
    private static let cache: Cache = {
        let cache = Cache()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    /// A freshly-decoded, thereafter-immutable `NSImage` is safe to move across the actor boundary.
    private struct Decoded: @unchecked Sendable {
        let image: NSImage?
        let cost: Int

        init(image: NSImage?, cost: Int = 0) {
            self.image = image
            self.cost = cost
        }
    }

    // MARK: - Shipped with the extension

    /// Cache-only, so a warm row paints on the same frame.
    static func cached(atPath path: String) -> NSImage? {
        IconCache.cachedArtwork(atPath: path, extent: extent)
    }

    /// Read from the file: `NSWorkspace` would answer a PNG with the generic document icon.
    static func icon(atPath path: String) -> NSImage {
        guard FileManager.default.fileExists(atPath: path) else {
            return IconCache.symbolIcon(named: "puzzlepiece.extension")
        }
        return IconCache.artwork(atPath: path, extent: extent)
    }

    static func loadAsync(atPath path: String) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: path) else {
            return IconCache.symbolIcon(named: "puzzlepiece.extension")
        }
        return await IconCache.loadArtworkAsync(atPath: path, extent: extent)
    }

    /// Never rasterized: fitting flattens a GIF to its first frame, and a playing tile needs them all.
    static func loadOriginalAsync(atPath path: String) async -> NSImage? {
        let key = originalKey(path)
        if let cached = cache.object(forKey: key) { return cached }
        let decoded = await Task.detached(priority: .userInitiated) {
            Decoded(image: NSImage(contentsOfFile: path))
        }.value
        guard let image = decoded.image else { return nil }
        cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
        return image
    }

    // MARK: - Named by the extension as a URL

    /// A failure caches nothing, so a transient error retries; `asIcon` is off for markdown images.
    static func loadAsync(_ url: URL, asIcon: Bool = true) async -> NSImage? {
        let key = urlKey(url, asIcon: asIcon)
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = await bytes(of: url) else { return nil }
        let decoded = await Task.detached(priority: .userInitiated) { () -> Decoded in
            guard let source = NSImage(data: data) else { return Decoded(image: nil) }
            guard asIcon else {
                return Decoded(
                    image: source, cost: Int(source.size.width * source.size.height * 4))
            }
            let (icon, cost) = IconCache.fitted(source, to: extent)
            return Decoded(image: icon, cost: cost)
        }.value
        guard let image = decoded.image else { return nil }
        cache.setObject(image, forKey: key, cost: decoded.cost)
        return image
    }

    private static func bytes(of url: URL) async -> Data? {
        // A `data:` URL carries its own bytes, so a session fetch would add a hop per grid tile.
        if url.scheme == "data" {
            return await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        }
        return try? await session.data(from: url).0
    }

    /// Cacheless, never `URLSession.shared`: an extension names these URLs, so none reach a disk cache.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private static func originalKey(_ path: String) -> NSString { ("raw:" + path) as NSString }
    private static func urlKey(_ url: URL, asIcon: Bool) -> NSString {
        ((asIcon ? "icon:" : "full:") + url.absoluteString) as NSString
    }
}
