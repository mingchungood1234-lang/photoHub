import CryptoKit
import Foundation
import ImageIO
import UIKit

extension Notification.Name {
    static let localProxyStoreDidChange = Notification.Name("PhotoHubLocalProxyStoreDidChange")
}

/// Persistent local store for server gallery index, compressed image/poster previews, and compressed MP4 video proxies.
/// Stored under Application Support (excluded from iCloud backup) so compressed proxies load immediately without network fetches.
final class LocalProxyStore {
    static let shared = LocalProxyStore()

    private let lock = NSLock()
    private let fm = FileManager.default
    private let rootDir: URL
    private let previewsDir: URL
    private let videosDir: URL

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

    // MARK: - Server Photo Index

    func cachedPhotos(baseURL: URL?, apiKey: String) -> [ServerPhoto] {
        lock.lock()
        defer { lock.unlock() }
        let url = indexFileURL(baseURL: baseURL, apiKey: apiKey)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ServerPhoto].self, from: data)) ?? []
    }

    func savePhotos(_ photos: [ServerPhoto], baseURL: URL?, apiKey: String) {
        lock.lock()
        ensureDirectoriesExistLocked()
        let url = indexFileURL(baseURL: baseURL, apiKey: apiKey)
        if let encoded = try? JSONEncoder().encode(photos) {
            try? encoded.write(to: url, options: .atomic)
        }
        lock.unlock()
    }

    func upsertPhoto(_ photo: ServerPhoto, baseURL: URL?, apiKey: String) {
        mutateIndex(baseURL: baseURL, apiKey: apiKey, notify: true) { current in
            current.removeAll { $0.hash.lowercased() == photo.hash.lowercased() }
            current.insert(photo, at: 0)
        }
    }

    func updatePhoto(_ photo: ServerPhoto, baseURL: URL?, apiKey: String, notify: Bool = false) {
        mutateIndex(baseURL: baseURL, apiKey: apiKey, notify: notify) { current in
            if let idx = current.firstIndex(where: { $0.hash.lowercased() == photo.hash.lowercased() }) {
                current[idx] = photo
            } else {
                current.insert(photo, at: 0)
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
        var current: [ServerPhoto] = []
        if let existingData = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([ServerPhoto].self, from: existingData) {
            current = decoded
        }
        transform(&current)
        if let encoded = try? JSONEncoder().encode(current) {
            try? encoded.write(to: url, options: .atomic)
        }
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
        lock.unlock()
    }

    func copyPreviewFile(from sourceURL: URL, forHash hash: String) {
        guard let data = try? Data(contentsOf: sourceURL), !data.isEmpty else { return }
        savePreviewData(data, forHash: hash)
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
        do {
            try fm.copyItem(at: sourceURL, to: dest)
            lock.unlock()
            return dest
        } catch {
            lock.unlock()
            return nil
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
        lock.lock()
        try? fm.removeItem(at: rootDir)
        ensureDirectoriesExistLocked()
        lock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .localProxyStoreDidChange, object: nil)
        }
    }
}
