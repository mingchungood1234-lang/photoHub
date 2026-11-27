import CryptoKit
import Foundation
import ImageIO
import UIKit

extension Notification.Name {
    static let localProxyStoreDidChange = Notification.Name("PhotoHubLocalProxyStoreDidChange")
}

/// Process-wide bounded LRU memory cache for decoded Cloud gallery grid thumbnails.
/// Automatically evicts entries under iOS memory pressure and keeps grid RAM under ~64 MB
/// even for multi-thousand-photo libraries.
final class ThumbnailMemoryCache {
    static let shared = ThumbnailMemoryCache()

    private let cache = NSCache<NSString, UIImage>()
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        cache.countLimit = 260
        cache.totalCostLimit = 64 * 1024 * 1024 // 64 MB
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.removeAll()
        }
    }

    func image(forHash hash: String) -> UIImage? {
        cache.object(forKey: hash.lowercased() as NSString)
    }

    func setImage(_ image: UIImage, forHash hash: String) {
        let pxW = Int(image.size.width * image.scale)
        let pxH = Int(image.size.height * image.scale)
        let cost = max(1, pxW * pxH * 4)
        cache.setObject(image, forKey: hash.lowercased() as NSString, cost: cost)
    }

    func remove(hashes: Set<String>) {
        for h in hashes {
            cache.removeObject(forKey: h.lowercased() as NSString)
        }
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    /// Decodes a compact display-ready thumbnail (default 360px) off the main thread using ImageIO
    /// without allocating a full-resolution backing bitmap in RAM.
    static func decodeGridThumbnail(from data: Data, maxPixelSize: Int = 360) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImg)
    }
}

/// Persistent local store for server gallery index, compressed image/poster previews, and compressed MP4 video proxies.
/// Stored under Application Support (excluded from iCloud backup) so compressed proxies load immediately without network fetches.
final class LocalProxyStore {
    static let shared = LocalProxyStore()

    private static let maxDiskCacheBytes: Int64 = 600 * 1024 * 1024 // 600 MB LRU cap
    private static let trimTargetDiskBytes: Int64 = 480 * 1024 * 1024

    private let lock = NSLock()
    private let fm = FileManager.default
    private let rootDir: URL
    private let previewsDir: URL
    private let videosDir: URL
    private let ioQueue = DispatchQueue(label: "photohub.localProxyStore.io", qos: .utility)

    private var indexMemoryCache: [String: [ServerPhoto]] = [:]
    private var pendingIndexFlushItems: [String: DispatchWorkItem] = [:]
    private var cacheWriteCounter: Int = 0
    private var isTrimmingDiskCache: Bool = false

    private init() {
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let root = appSupport.appendingPathComponent("PhotoHubLocalProxies", isDirectory: true)
        self.rootDir = root
        self.previewsDir = root.appendingPathComponent("previews", isDirectory: true)
        self.videosDir = root.appendingPathComponent("videos", isDirectory: true)
        ensureDirectoriesExistLocked()
    }

    private func ensureDirectoriesExistLocked() {
        try? fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: previewsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: videosDir, withIntermediateDirectories: true)

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableRoot = rootDir
        try? mutableRoot.setResourceValues(resourceValues)
    }

    private func safeHash(_ hash: String) -> String {
        let filtered = hash.lowercased().filter { $0.isHexDigit || $0 == "-" || $0 == "_" }
        return filtered.isEmpty ? "unknown" : filtered
    }

    private func indexFileURL(baseURL: URL?, apiKey: String) -> URL {
        let rawKey = "\(baseURL?.absoluteString ?? "none")|\(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))"
        let digest = SHA256.hash(data: Data(rawKey.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return rootDir.appendingPathComponent("index_\(String(hex.prefix(24))).json")
    }

    private func previewFileURL(forHash hash: String) -> URL {
        previewsDir.appendingPathComponent("\(safeHash(hash)).dat")
    }

    private func videoFileURL(forHash hash: String) -> URL {
        videosDir.appendingPathComponent("\(safeHash(hash)).mp4")
    }

    // MARK: - Server Photo Index (In-Memory Cached + Debounced Atomic Disk Persistence)

    private func loadIndexLocked(url: URL) -> [ServerPhoto] {
        let key = url.path
        if let cached = indexMemoryCache[key] {
            return cached
        }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ServerPhoto].self, from: data) else {
            return []
        }
        indexMemoryCache[key] = decoded
        return decoded
    }

    private func scheduleIndexFlushLocked(url: URL, immediate: Bool = false) {
        let key = url.path
        pendingIndexFlushItems[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let snapshot = self.indexMemoryCache[key]
            self.pendingIndexFlushItems.removeValue(forKey: key)
            self.ensureDirectoriesExistLocked()
            self.lock.unlock()
            guard let snapshot, let encoded = try? JSONEncoder().encode(snapshot) else { return }
            try? encoded.write(to: url, options: .atomic)
        }
        pendingIndexFlushItems[key] = work
        if immediate {
            ioQueue.async(execute: work)
        } else {
            ioQueue.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    func cachedPhotos(baseURL: URL?, apiKey: String) -> [ServerPhoto] {
        lock.lock()
        defer { lock.unlock() }
        let url = indexFileURL(baseURL: baseURL, apiKey: apiKey)
        return loadIndexLocked(url: url)
    }

    func savePhotos(_ photos: [ServerPhoto], baseURL: URL?, apiKey: String) {
        lock.lock()
        ensureDirectoriesExistLocked()
        let url = indexFileURL(baseURL: baseURL, apiKey: apiKey)
        indexMemoryCache[url.path] = photos
        scheduleIndexFlushLocked(url: url, immediate: true)
        lock.unlock()
    }

    func upsertPhoto(_ photo: ServerPhoto, baseURL: URL?, apiKey: String) {
        mutateIndex(baseURL: baseURL, apiKey: apiKey, notify: true) { current in
            current.removeAll { $0.hash.lowercased() == photo.hash.lowercased() }
            current.insert(photo, at: 0)
        }
    }

    func updatePhoto(_ photo: ServerPhoto, baseURL: URL?, apiKey: String, notify: Bool = false) {
        updatePhotos([photo], baseURL: baseURL, apiKey: apiKey, notify: notify)
    }

    func updatePhotos(_ photos: [ServerPhoto], baseURL: URL?, apiKey: String, notify: Bool = false) {
        guard !photos.isEmpty else { return }
        mutateIndex(baseURL: baseURL, apiKey: apiKey, notify: notify) { current in
            var indexByHash: [String: Int] = [:]
            indexByHash.reserveCapacity(current.count)
            for (idx, item) in current.enumerated() {
                indexByHash[item.hash.lowercased()] = idx
            }
            var toPrepend: [ServerPhoto] = []
            for photo in photos {
                let key = photo.hash.lowercased()
                if let idx = indexByHash[key] {
                    current[idx] = photo
                } else {
                    toPrepend.append(photo)
                }
            }
            if !toPrepend.isEmpty {
                current.insert(contentsOf: toPrepend, at: 0)
            }
        }
    }

    func removePhoto(hash: String, baseURL: URL?, apiKey: String, notify: Bool = true) {
        removePhotos(hashes: [hash], baseURL: baseURL, apiKey: apiKey, notify: notify)
    }

    func removePhotos(hashes: [String], baseURL: URL?, apiKey: String, notify: Bool = true) {
        let targetSet = Set(
            hashes
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !targetSet.isEmpty else { return }

        ThumbnailMemoryCache.shared.remove(hashes: targetSet)

        lock.lock()
        ensureDirectoriesExistLocked()
        let url = indexFileURL(baseURL: baseURL, apiKey: apiKey)
        var decoded = loadIndexLocked(url: url)
        if !decoded.isEmpty {
            decoded.removeAll { targetSet.contains($0.hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            indexMemoryCache[url.path] = decoded
            scheduleIndexFlushLocked(url: url, immediate: true)
        }
        for hash in targetSet {
            try? fm.removeItem(at: previewFileURL(forHash: hash))
            try? fm.removeItem(at: videoFileURL(forHash: hash))
        }
        lock.unlock()

        if notify {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .localProxyStoreDidChange, object: nil)
            }
        }
    }

    private func mutateIndex(
        baseURL: URL?,
        apiKey: String,
        notify: Bool,
        _ transform: (inout [ServerPhoto]) -> Void
    ) {
        lock.lock()
        ensureDirectoriesExistLocked()
        let url = indexFileURL(baseURL: baseURL, apiKey: apiKey)
        var current = loadIndexLocked(url: url)
        transform(&current)
        indexMemoryCache[url.path] = current
        scheduleIndexFlushLocked(url: url, immediate: false)
        lock.unlock()

        if notify {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .localProxyStoreDidChange, object: nil)
            }
        }
    }

    // MARK: - Image / Poster Previews

    func previewData(forHash hash: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try? Data(contentsOf: previewFileURL(forHash: hash))
    }

    func previewImage(forHash hash: String) -> UIImage? {
        guard let data = previewData(forHash: hash) else { return nil }
        return UIImage(data: data)
    }

    func savePreviewData(_ data: Data, forHash hash: String) {
        guard !data.isEmpty else { return }
        lock.lock()
        ensureDirectoriesExistLocked()
        let dest = previewFileURL(forHash: hash)
        try? data.write(to: dest, options: .atomic)
        cacheWriteCounter += 1
        let shouldTrim = (cacheWriteCounter % 32 == 0) && !isTrimmingDiskCache
        if shouldTrim { isTrimmingDiskCache = true }
        lock.unlock()
        if shouldTrim {
            scheduleDiskCacheTrim()
        }
    }

    func copyPreviewFile(from sourceURL: URL, forHash hash: String) {
        guard let data = try? Data(contentsOf: sourceURL), !data.isEmpty else { return }
        savePreviewData(data, forHash: hash)
    }

    @discardableResult
    func cacheDownloadedPreviewData(
        _ rawData: Data,
        forHash hash: String,
        maxPixelSize: Int = 800,
        quality: CGFloat = 0.65
    ) -> Data? {
        cacheDownloadedPreview(rawData, forHash: hash, maxPixelSize: maxPixelSize, quality: quality)?.1
    }

    @discardableResult
    func cacheDownloadedPreview(
        _ rawData: Data,
        forHash hash: String,
        maxPixelSize: Int = 800,
        quality: CGFloat = 0.65
    ) -> (UIImage, Data)? {
        guard let (smallImg, smallData) = Self.makeSmallCompressedPreview(
            from: rawData,
            maxPixelSize: maxPixelSize,
            quality: quality
        ) else {
            return nil
        }
        savePreviewData(smallData, forHash: hash)
        return (smallImg, smallData)
    }

    static func makeSmallCompressedPreview(
        from data: Data,
        maxPixelSize: Int = 800,
        quality: CGFloat = 0.65
    ) -> (UIImage, Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            guard let img = UIImage(data: data),
                  let jpg = img.jpegData(compressionQuality: quality) else { return nil }
            return (UIImage(data: jpg) ?? img, jpg)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let uiImg = UIImage(cgImage: cgImg)
        guard let smallJpg = uiImg.jpegData(compressionQuality: quality),
              let decodedSmall = UIImage(data: smallJpg) else {
            return nil
        }
        return (decodedSmall, smallJpg)
    }

    // MARK: - Compressed Video Proxies (.mp4)

    func videoProxyURLIfExists(forHash hash: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let url = videoFileURL(forHash: hash)
        guard fm.fileExists(atPath: url.path),
              let attrs = try? fm.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? NSNumber,
              fileSize.int64Value > 0 else {
            return nil
        }
        return url
    }

    @discardableResult
    func copyVideoProxy(from sourceURL: URL, forHash hash: String) -> URL? {
        lock.lock()
        ensureDirectoriesExistLocked()
        let dest = videoFileURL(forHash: hash)
        try? fm.removeItem(at: dest)
        var shouldTrim = false
        do {
            try fm.copyItem(at: sourceURL, to: dest)
            cacheWriteCounter += 1
            if !isTrimmingDiskCache {
                isTrimmingDiskCache = true
                shouldTrim = true
            }
            lock.unlock()
            if shouldTrim { scheduleDiskCacheTrim() }
            return dest
        } catch {
            lock.unlock()
            return nil
        }
    }

    private func scheduleDiskCacheTrim() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.isTrimmingDiskCache = false
                self.lock.unlock()
            }
            var entries: [(url: URL, size: Int64, mtime: Date)] = []
            var totalBytes: Int64 = 0
            for dir in [self.previewsDir, self.videosDir] {
                guard let urls = try? self.fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for url in urls {
                    guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                          vals.isRegularFile == true,
                          let size = vals.fileSize else { continue }
                    let sz = Int64(size)
                    totalBytes += sz
                    entries.append((url, sz, vals.contentModificationDate ?? .distantPast))
                }
            }
            guard totalBytes > Self.maxDiskCacheBytes else { return }
            entries.sort { $0.mtime < $1.mtime }
            for entry in entries where totalBytes > Self.trimTargetDiskBytes {
                if (try? self.fm.removeItem(at: entry.url)) != nil {
                    totalBytes -= entry.size
                }
            }
        }
    }

    @discardableResult
    func saveVideoProxyData(_ data: Data, forHash hash: String) -> URL? {
        guard !data.isEmpty else { return nil }
        lock.lock()
        ensureDirectoriesExistLocked()
        let dest = videoFileURL(forHash: hash)
        do {
            try data.write(to: dest, options: .atomic)
            lock.unlock()
            return dest
        } catch {
            lock.unlock()
            return nil
        }
    }

    // MARK: - Storage Management

    func totalStorageBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let enumerator = fm.enumerator(
            at: rootDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true,
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    func clearAll() {
        ThumbnailMemoryCache.shared.removeAll()
        lock.lock()
        for item in pendingIndexFlushItems.values { item.cancel() }
        pendingIndexFlushItems.removeAll()
        indexMemoryCache.removeAll()
        try? fm.removeItem(at: rootDir)
        ensureDirectoriesExistLocked()
        lock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .localProxyStoreDidChange, object: nil)
        }
    }
}
