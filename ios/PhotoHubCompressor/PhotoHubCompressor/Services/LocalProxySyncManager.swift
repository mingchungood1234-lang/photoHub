import Foundation

private struct LocalPrefetchWorkItem: Sendable {
    let hash: String
    let downloadPreview: Bool
    let downloadVideo: Bool
}

/// Automatically downloads already-proxied server previews and compressed MP4 video proxies
/// into persistent `LocalProxyStore` app storage in the background.
final class LocalProxySyncManager: ObservableObject {
    static let shared = LocalProxySyncManager()

    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var completedCount: Int = 0
    @Published private(set) var totalCount: Int = 0

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
        }
    }

    /// Fetches the server gallery index on launch and auto-caches missing compressed proxies locally.
    func syncFromServerOnLaunch(settings: AppSettings) {
        guard settings.autoDownloadLocalProxies,
              settings.normalizedBaseURL != nil else {
            return
        }

        let client = PhotoHubAPIClient(settings: settings)
        let includeVideos = settings.autoDownloadLocalVideos
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
                    includeVideos: includeVideos
                )
            } catch {
                // Silent on launch; errors surface interactively on the Server tab.
            }
        }
        activeTask = task
        lock.unlock()
    }

    /// Auto-downloads compressed proxies that exist on the server but are not yet stored locally.
    func startPrefetchIfNeeded(for photos: [ServerPhoto], settings: AppSettings) {
        guard settings.autoDownloadLocalProxies else {
            cancel()
            return
        }

        let client = PhotoHubAPIClient(settings: settings)
        let includeVideos = settings.autoDownloadLocalVideos

        lock.lock()
        activeTask?.cancel()
        let task = Task.detached(priority: .utility) { [weak self] in
            await self?.prefetchMissingProxies(
                photos: photos,
                client: client,
                includeVideos: includeVideos
            )
        }
        activeTask = task
        lock.unlock()
    }

    private func prefetchMissingProxies(
        photos: [ServerPhoto],
        client: PhotoHubAPIClient,
        includeVideos: Bool
    ) async {
        let store = LocalProxyStore.shared
        var workItems: [LocalPrefetchWorkItem] = []

        for photo in photos {
            let hasServerImagePreview = (photo.hasPreview == true) || (photo.hasPreview == nil && photo.hasProxy == true && !photo.isVideo)
            let needPreview = hasServerImagePreview && store.previewData(forHash: photo.hash) == nil
            let needVideo = includeVideos
                && photo.isVideo
                && photo.hasVideoProxy == true
                && store.videoProxyURLIfExists(forHash: photo.hash) == nil

            if needPreview || needVideo {
                workItems.append(
                    LocalPrefetchWorkItem(
                        hash: photo.hash,
                        downloadPreview: needPreview,
                        downloadVideo: needVideo
                    )
                )
            }
        }

        guard !workItems.isEmpty else {
            await MainActor.run {
                self.isSyncing = false
                self.completedCount = 0
                self.totalCount = 0
            }
            return
        }

        await MainActor.run {
            self.isSyncing = true
            self.completedCount = 0
            self.totalCount = workItems.count
        }

        let queue = AsyncWorkQueue(workItems)
        let workerCount = min(4, workItems.count)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask { [weak self] in
                    while !Task.isCancelled, let item = await queue.next() {
                        if item.downloadPreview,
                           let rawData = try? await client.downloadPhotoPreviewData(hash: item.hash) {
                            _ = LocalProxyStore.shared.cacheDownloadedPreview(rawData, forHash: item.hash)
                        }

                        if item.downloadVideo,
                           let tempVideo = try? await client.downloadVideoProxyToTempFile(hash: item.hash) {
                            _ = LocalProxyStore.shared.copyVideoProxy(from: tempVideo, forHash: item.hash)
                            cleanupTempShareURL(tempVideo)
                        }

                        await MainActor.run {
                            guard let self else { return }
                            self.completedCount += 1
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
