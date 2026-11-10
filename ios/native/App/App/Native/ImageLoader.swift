import CryptoKit
import ImageIO
import UIKit

/// An image view that remembers which picture it is waiting for (see ImageLoader.load).
class NetImageView: UIImageView {
    fileprivate var want: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFill
        clipsToBounds = true
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/**
 * Pictures for the native screens: the first of a card's addresses that loads (best first), decoded
 * at the size it is shown (a poster is a few hundred pixels, not the 2000px file), kept in memory
 * while there is room and on disk for later. Like Android's NativeImages: addresses that failed
 * lately and servers that are down are skipped for a while, and a picture already on its way is
 * waited for instead of fetched twice.
 */
final class ImageLoader {
    static let shared = ImageLoader()

    /// The page's own files: the web build inside the app (format badges, addon logos).
    static let appOrigin = "capacitor://localhost/"

    var userAgent = "HarborIOS"

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let diskDir: URL
    private let work = DispatchQueue(label: "harbor.images", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    /// Addresses that failed lately (when): tried again after two minutes.
    private var failed: [String: Date] = [:]
    /// Hosts that couldn't be reached lately (when): their pictures aren't waited for for a minute.
    private var deadHosts: [String: Date] = [:]
    /// Pictures on their way, and who waits for each.
    private var inflight: [String: [(UIImage?) -> Void]] = [:]

    private init() {
        memory.totalCostLimit = 96 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = nil // our own disk cache below keeps the files
        session = URLSession(configuration: config)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDir = caches.appendingPathComponent("harbor-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.memory.removeAllObjects()
        }
    }

    /// Shows the first of [urls] that loads in [view], decoded for about [size] points. [keep]: the
    /// picture shown now stays until the new one is in (no blank in between). [onResult]: whether
    /// one loaded.
    func load(_ view: NetImageView, urls: [String], size: CGSize, keep: Bool = false, onResult: ((Bool) -> Void)? = nil) {
        let candidates = urls.filter { u in
            u.hasPrefix("https://") || u.hasPrefix("http://") || u.hasPrefix("data:image/") || u.hasPrefix(Self.appOrigin)
        }
        let want = candidates.joined(separator: "|") + "@\(Int(size.width / 64))x\(Int(size.height / 64))"
        if view.want == want, view.image != nil {
            onResult?(true)
            return
        }
        view.want = want
        if !keep { view.image = nil }
        guard !candidates.isEmpty else {
            onResult?(false)
            return
        }
        let px = max(size.width, size.height) * UIScreen.main.scale
        attempt(candidates, index: 0, maxPixels: px) { [weak view] image in
            guard let view, view.want == want else { return }
            if let image {
                if view.image == nil {
                    view.alpha = 0
                    view.image = image
                    UIView.animate(withDuration: 0.18) { view.alpha = 1 }
                } else {
                    view.image = image
                }
            }
            onResult?(image != nil)
        }
    }

    /// Stops showing whatever [view] waited for (a cell reused for another card).
    func clear(_ view: NetImageView) {
        view.want = nil
        view.image = nil
    }

    /// The disk cache's size in bytes, and emptying it (Settings).
    func diskBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clearAll() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: diskDir)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    /// Free space on the phone.
    func freeBytes() -> Int64 {
        let v = try? diskDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? -1
    }

    /// How much the saved pictures may take: 250 MB with 5 GB or more free, 150 MB under 5 GB,
    /// 100 MB under 2 GB (as on Android).
    func limitBytes() -> Int64 {
        let free = freeBytes()
        let gb: Int64 = 1024 * 1024 * 1024
        let mb: Int64 = 1024 * 1024
        if free >= 0 && free < 2 * gb { return 100 * mb }
        if free >= 0 && free < 5 * gb { return 150 * mb }
        return 250 * mb
    }

    /// {"used","limit","free"} in bytes (Settings).
    func cacheInfo() -> [String: Int64] {
        ["used": diskBytes(), "limit": limitBytes(), "free": freeBytes()]
    }

    private var savesSinceTrim = 0

    /// Over the limit: the oldest pictures go first.
    private func trimIfNeeded() {
        savesSinceTrim += 1
        guard savesSinceTrim >= 40 else { return }
        savesSinceTrim = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { f -> (URL, Int64, Date)? in
            guard let v = try? f.resourceValues(forKeys: Set(keys)) else { return nil }
            return (f, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        let limit = limitBytes()
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for e in entries where total > limit * 9 / 10 {
            try? FileManager.default.removeItem(at: e.0)
            total -= e.1
        }
    }

    // MARK: - Loading

    private func attempt(_ urls: [String], index: Int, maxPixels: CGFloat, done: @escaping (UIImage?) -> Void) {
        guard index < urls.count else {
            DispatchQueue.main.async { done(nil) }
            return
        }
        let url = urls[index]
        let next = { [weak self] in self?.attempt(urls, index: index + 1, maxPixels: maxPixels, done: done) }
        if recentlyFailed(url) || hostDown(url) {
            next()
            return
        }
        let key = "\(url)@\(Int(maxPixels / 128))" as NSString
        if let hit = memory.object(forKey: key) {
            DispatchQueue.main.async { done(hit) }
            return
        }
        fetch(url, key: key as String, maxPixels: maxPixels) { image in
            if let image {
                DispatchQueue.main.async { done(image) }
            } else {
                next()
            }
        }
    }

    /// One address: memory, disk, else the network; callers asking for the same one wait together.
    private func fetch(_ url: String, key: String, maxPixels: CGFloat, done: @escaping (UIImage?) -> Void) {
        lock.lock()
        if inflight[key] != nil {
            inflight[key]?.append(done)
            lock.unlock()
            return
        }
        inflight[key] = [done]
        lock.unlock()

        let finish: (UIImage?) -> Void = { [weak self] image in
            guard let self else { return }
            if let image { self.memory.setObject(image, forKey: key as NSString, cost: Self.cost(image)) }
            self.lock.lock()
            let waiters = self.inflight.removeValue(forKey: key) ?? []
            self.lock.unlock()
            waiters.forEach { $0(image) }
        }

        work.async { [weak self] in
            guard let self else { return }
            if let data = self.localData(url) ?? self.diskData(url) {
                finish(Self.decode(data, maxPixels: maxPixels))
                return
            }
            guard let u = URL(string: url) else {
                self.markFailed(url)
                finish(nil)
                return
            }
            var request = URLRequest(url: u)
            request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
            self.session.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, let data, !data.isEmpty, (200..<300).contains(status) else {
                    if let e = error as? URLError, [.timedOut, .cannotFindHost, .cannotConnectToHost, .notConnectedToInternet, .networkConnectionLost].contains(e.code) {
                        self.markHostDown(url)
                    } else {
                        self.markFailed(url)
                    }
                    finish(nil)
                    return
                }
                self.work.async {
                    let image = Self.decode(data, maxPixels: maxPixels)
                    if image != nil { self.saveDisk(url, data) } else { self.markFailed(url) }
                    finish(image)
                }
            }.resume()
        }
    }

    /// A picture carried in its address, or one of the app's own files.
    private func localData(_ url: String) -> Data? {
        if url.hasPrefix("data:") {
            guard let comma = url.firstIndex(of: ",") else { return nil }
            let meta = url[..<comma]
            let payload = String(url[url.index(after: comma)...])
            if meta.contains(";base64") { return Data(base64Encoded: payload, options: .ignoreUnknownCharacters) }
            return payload.removingPercentEncoding?.data(using: .utf8)
        }
        if url.hasPrefix(Self.appOrigin) {
            var path = String(url.dropFirst(Self.appOrigin.count))
            if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<q]) }
            guard let base = Bundle.main.resourceURL?.appendingPathComponent("public") else { return nil }
            return try? Data(contentsOf: base.appendingPathComponent(path.removingPercentEncoding ?? path))
        }
        return nil
    }

    private func diskFile(_ url: String) -> URL {
        let digest = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(digest)
    }

    private func diskData(_ url: String) -> Data? {
        guard !url.hasPrefix("data:") else { return nil }
        return try? Data(contentsOf: diskFile(url))
    }

    private func saveDisk(_ url: String, _ data: Data) {
        guard !url.hasPrefix("data:"), !url.hasPrefix(Self.appOrigin) else { return }
        try? data.write(to: diskFile(url), options: .atomic)
        lock.lock()
        trimIfNeeded()
        lock.unlock()
    }

    /// Decoded at [maxPixels] on its longest side at most (SVGs aren't supported by ImageIO: nil).
    private static func decode(_ data: Data, maxPixels: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, Int(maxPixels)),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg, scale: UIScreen.main.scale, orientation: .up)
    }

    private static func cost(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }

    private func recentlyFailed(_ url: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let at = failed[url] else { return false }
        if Date().timeIntervalSince(at) < 120 { return true }
        failed[url] = nil
        return false
    }

    private func markFailed(_ url: String) {
        lock.lock()
        failed[url] = Date()
        lock.unlock()
    }

    private func host(_ url: String) -> String? { URL(string: url)?.host }

    private func hostDown(_ url: String) -> Bool {
        guard let h = host(url) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let at = deadHosts[h] else { return false }
        if Date().timeIntervalSince(at) < 60 { return true }
        deadHosts[h] = nil
        return false
    }

    private func markHostDown(_ url: String) {
        guard let h = host(url) else { return }
        lock.lock()
        deadHosts[h] = Date()
        lock.unlock()
    }
}
