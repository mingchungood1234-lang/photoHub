import Combine
import Foundation

private struct LocalPrefetchWorkItem: Sendable {
    let photo: ServerPhoto
    let cachePreviewLocally: Bool
    let cacheVideoLocally: Bool
    let saveToPhotosApp: Bool
}

/// Automatically downloads already-proxied server previews and compressed MP4 video proxies
/// into persistent `LocalProxyStore` app storage AND saves them to the iPhone Photos app.
final class LocalProxySyncManager: ObservableObject {
    static let shared = LocalProxySyncManager()

    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var completedCount: Int = 0
    @Published private(set) var totalCount: Int = 0
    @Published private(set) var savedToPhotosCount: Int = 0
    @Published private(set) var statusText: String = ""

    private let lock = NSLock()
    private var activeTask: Task<Void, Never>?

    private init() {}

    func cancel() {
        lock.lock()
        activeTask?.cancel()
        activeTask = nil
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.isSyncing = false
            self?.completedCount = 0
            self?.totalCount = 0
            self?.statusText = ""
        }
    }

    /// Fetches the server gallery index on launch and auto-caches / auto-saves proxied items.
    func syncFromServerOnLaunch(settings: AppSettings) {
        guard settings.isSignedIn,
              (settings.autoDownloadLocalProxies || settings.autoSaveProxiesToPhotosApp),
              settings.normalizedBaseURL != nil else {
            return
        }

        let client = PhotoHubAPIClient(settings: settings)
        let cachePreviews = settings.autoDownloadLocalProxies
        let cacheVideos = settings.autoDownloadLocalProxies && settings.autoDownloadLocalVideos
        let saveToPhotos = settings.autoSaveProxiesToPhotosApp
        let baseURL = settings.normalizedBaseURL
        let apiKey = settings.apiKey

        lock.lock()
        activeTask?.cancel()
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await client.fetchAllServerPhotos(sync: false)
                if Task.isCancelled { return }
                LocalProxyStore.shared.savePhotos(fetched, baseURL: baseURL, apiKey: apiKey)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .localProxyStoreDidChange, object: nil)
                }
                await self.prefetchMissingProxies(
                    photos: fetched,
                    client: client,
                    cachePreviewsLocally: cachePreviews,
                    cacheVideosLocally: cacheVideos,
                    saveToPhotosApp: saveToPhotos,
                    forceAllMissingInPhotos: false
                )
            } catch {
                // Silent on launch; errors surface interactively on the Server tab.
            }
        }
        activeTask = task
        lock.unlock()
    }

    /// Auto-downloads compressed proxies that exist on the server but are not yet cached / saved locally.
    func startPrefetchIfNeeded(for photos: [ServerPhoto], settings: AppSettings) {
        guard settings.autoDownloadLocalProxies || settings.autoSaveProxiesToPhotosApp else {
            cancel()
            return
        }

        let client = PhotoHubAPIClient(settings: settings)
        let cachePreviews = settings.autoDownloadLocalProxies
        let cacheVideos = settings.autoDownloadLocalProxies && settings.autoDownloadLocalVideos
        let saveToPhotos = settings.autoSaveProxiesToPhotosApp

        lock.lock()
        activeTask?.cancel()
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.prefetchMissingProxies(
                photos: photos,
                client: client,
                cachePreviewsLocally: cachePreviews,
                cacheVideosLocally: cacheVideos,
                saveToPhotosApp: saveToPhotos,
                forceAllMissingInPhotos: false
            )
        }
        activeTask = task
        lock.unlock()
    }

    /// Explicit user-triggered download of all proxied server photos/videos into the iPhone Photos app.
    func downloadAllMissingToPhotos(settings: AppSettings, knownPhotos: [ServerPhoto] = []) {
        guard settings.normalizedBaseURL != nil else { return }

        let client = PhotoHubAPIClient(settings: settings)
        let cachePreviews = settings.autoDownloadLocalProxies
        let cacheVideos = settings.autoDownloadLocalProxies && settings.autoDownloadLocalVideos
        let baseURL = settings.normalizedBaseURL
        let apiKey = settings.apiKey

        lock.lock()
        activeTask?.cancel()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let authorized = await PhotoLibraryService.requestWriteAuthorizationAsync()
            guard authorized else {
                await MainActor.run {
                    self.isSyncing = false
                    self.statusText = "Allow Photos permission in iOS Settings to save proxies to Apple Photos."
                }
                return
            }

            await MainActor.run {
                self.isSyncing = true
                self.completedCount = 0
                self.totalCount = 0
                self.savedToPhotosCount = 0
                self.statusText = "Checking server proxies..."
            }

            let targetPhotos: [ServerPhoto]
            if let fresh = try? await client.fetchAllServerPhotos(sync: true), !fresh.isEmpty {
                LocalProxyStore.shared.savePhotos(fresh, baseURL: baseURL, apiKey: apiKey)
                targetPhotos = fresh
            } else {
                targetPhotos = knownPhotos
            }

            await self.prefetchMissingProxies(
                photos: targetPhotos,
                client: client,
                cachePreviewsLocally: cachePreviews,
                cacheVideosLocally: cacheVideos,
                saveToPhotosApp: true,
                forceAllMissingInPhotos: true
            )
        }
        activeTask = task
        lock.unlock()
    }

    private func prefetchMissingProxies(
        photos: [ServerPhoto],
        client: PhotoHubAPIClient,
        cachePreviewsLocally: Bool,
        cacheVideosLocally: Bool,
        saveToPhotosApp: Bool,
        forceAllMissingInPhotos: Bool
    ) async {
        let store = LocalProxyStore.shared
        let tracker = LocalProxyTracker.shared
        let canWritePhotos = saveToPhotosApp && PhotoLibraryService.canWriteToPhotosLibrary()
        let existingProxyPrefixes = canWritePhotos
            ? PhotoLibraryService.scanExistingProxyPrefixesInPhotos()
            : [:]

        var workItems: [LocalPrefetchWorkItem] = []

        for photo in photos {
            let hasServerImagePreview = (photo.hasPreview == true) || (photo.hasPreview == nil && photo.hasProxy == true && !photo.isVideo)
            let hasServerVideoProxy = photo.isVideo && photo.hasVideoProxy == true

            let needCachePreview = cachePreviewsLocally
                && hasServerImagePreview
                && store.previewData(forHash: photo.hash) == nil
            let needCacheVideo = cacheVideosLocally
                && hasServerVideoProxy
                && store.videoProxyURLIfExists(forHash: photo.hash) == nil

            let prefixTag = ProxyGenerator.proxyPrefixTag(forMasterHash: photo.hash)
            let iCloudSyncedProxyAssetId = existingProxyPrefixes[prefixTag]
            if let iCloudSyncedProxyAssetId {
                tracker.markAsProxy(
                    assetId: iCloudSyncedProxyAssetId,
                    proxySha256: photo.proxyHash ?? "",
                    masterHash: photo.hash,
                    originalName: photo.originalName
                )
            }

            let isRestoredProtected = (photo.keepOriginalOnDevice == true)
                || tracker.isRestoredMasterHash(photo.hash)

            let alreadyInPhotos: Bool
            if isRestoredProtected {
                alreadyInPhotos = true
            } else if iCloudSyncedProxyAssetId != nil {
                alreadyInPhotos = true
            } else if forceAllMissingInPhotos {
                alreadyInPhotos = tracker.liveProxyAssetId(forMasterHash: photo.hash) != nil
            } else {
                alreadyInPhotos = tracker.isMasterHandledForPhotos(photo.hash)
                    || tracker.liveProxyAssetId(forMasterHash: photo.hash) != nil
            }

            let canSupplyMediaForPhotos: Bool = {
                if photo.isVideo {
                    return hasServerVideoProxy || store.videoProxyURLIfExists(forHash: photo.hash) != nil
                } else {
                    return hasServerImagePreview || store.previewData(forHash: photo.hash) != nil
                }
            }()

            let needPhotosSave = canWritePhotos
                && !photo.needsProxy
                && !alreadyInPhotos
                && canSupplyMediaForPhotos

            if needCachePreview || needCacheVideo || needPhotosSave {
                workItems.append(
                    LocalPrefetchWorkItem(
                        photo: photo,
                        cachePreviewLocally: needCachePreview || (!photo.isVideo && needPhotosSave && cachePreviewsLocally),
                        cacheVideoLocally: needCacheVideo || (photo.isVideo && needPhotosSave && cacheVideosLocally),
                        saveToPhotosApp: needPhotosSave
                    )
                )
            }
        }

        guard !workItems.isEmpty else {
            await MainActor.run {
                self.isSyncing = false
                self.completedCount = 0
                self.totalCount = 0
                if forceAllMissingInPhotos {
                    self.statusText = "All proxied items are already saved in Apple Photos."
                }
            }
            return
        }

        let photosTargetsCount = workItems.filter { $0.saveToPhotosApp }.count
        await MainActor.run {
            self.isSyncing = true
            self.completedCount = 0
            self.savedToPhotosCount = 0
            self.totalCount = workItems.count
            self.statusText = photosTargetsCount > 0
                ? "Downloading proxies to Apple Photos (0/\(workItems.count))..."
                : "Auto-downloading local proxies (0/\(workItems.count))..."
        }

        let queue = AsyncWorkQueue(workItems)
        let photosSemaphore = AsyncSemaphore(value: 1)
        let workerCount = min(4, workItems.count)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask { [weak self] in
                    while !Task.isCancelled, let item = await queue.next() {
                        let photo = item.photo

                        var imageData = LocalProxyStore.shared.previewData(forHash: photo.hash)
                        if imageData == nil && (item.cachePreviewLocally || (!photo.isVideo && item.saveToPhotosApp)) {
                            if let rawData = try? await client.downloadPhotoPreviewData(hash: photo.hash) {
                                if item.cachePreviewLocally {
                                    imageData = LocalProxyStore.shared.cacheDownloadedPreviewData(rawData, forHash: photo.hash)
                                } else {
                                    imageData = LocalProxyStore.makeSmallCompressedPreview(from: rawData)?.1 ?? rawData
                                }
                            }
                        }

                        var videoURL = LocalProxyStore.shared.videoProxyURLIfExists(forHash: photo.hash)
                        var tempVideoToCleanup: URL?
                        defer {
                            if let tempVideoToCleanup {
                                cleanupTempShareURL(tempVideoToCleanup)
                            }
                        }

                        if videoURL == nil && (item.cacheVideoLocally || (photo.isVideo && item.saveToPhotosApp)) {
                            if let tempVideo = try? await client.downloadVideoProxyToTempFile(hash: photo.hash) {
                                if item.cacheVideoLocally {
                                    videoURL = LocalProxyStore.shared.copyVideoProxy(from: tempVideo, forHash: photo.hash)
                                    cleanupTempShareURL(tempVideo)
                                } else {
                                    videoURL = tempVideo
                                    tempVideoToCleanup = tempVideo
                                }
                            }
                        }

                        var savedPhotoNow = false
                        if item.saveToPhotosApp {
                            await photosSemaphore.acquire()
                            do {
                                _ = try await PhotoLibraryService.saveServerProxyToPhotosAsync(
                                    photo: photo,
                                    imageData: imageData,
                                    videoURL: videoURL
                                )
                                await photosSemaphore.release()
                                savedPhotoNow = true
                            } catch {
                                await photosSemaphore.release()
                            }
                        }

                        await MainActor.run {
                            guard let self else { return }
                            self.completedCount += 1
                            if savedPhotoNow {
                                self.savedToPhotosCount += 1
                            }
                            if photosTargetsCount > 0 {
                                self.statusText = "Downloading proxies to Apple Photos (\(self.completedCount)/\(self.totalCount))..."
                            } else {
                                self.statusText = "Auto-downloading local proxies (\(self.completedCount)/\(self.totalCount))..."
                            }
                            if self.completedCount % 4 == 0 {
                                NotificationCenter.default.post(name: .localProxyStoreDidChange, object: nil)
                            }
                        }
                    }
                }
            }
        }

        if !Task.isCancelled {
            await MainActor.run {
                NotificationCenter.default.post(name: .localProxyStoreDidChange, object: nil)
                if forceAllMissingInPhotos {
                    self.statusText = "Saved \(self.savedToPhotosCount) proxy item(s) to Apple Photos."
                } else {
                    self.statusText = ""
                }
            }
        }
        await MainActor.run {
            self.isSyncing = false
        }
        lock.lock()
        activeTask = nil
        lock.unlock()
    }
}
