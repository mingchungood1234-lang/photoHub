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
                    NotificationCenter.default.post(name: .photoHubServerSyncCompleted, object: nil)
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
        let canReadPhotos = PhotoLibraryService.canWriteToPhotosLibrary()
        let canWritePhotos = saveToPhotosApp && canReadPhotos
        let existingProxyPrefixes = canReadPhotos
            ? PhotoLibraryService.scanExistingProxyPrefixesInPhotos()
            : [:]
        let existingOriginalsMap = canReadPhotos
            ? PhotoLibraryService.scanExistingOriginalMapInPhotos()
            : [:]

        var workItems: [LocalPrefetchWorkItem] = []

        for photo in photos {
            let hasServerImagePreview = (photo.hasPreview == true) || (photo.hasPreview == nil && photo.hasProxy == true && !photo.isVideo)
            let hasServerVideoProxy = photo.isVideo && photo.hasVideoProxy == true

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

            // Detect any matching original already sitting in Apple Photos (prevents duplicate downloads & saves!)
            var matchedOriginalAssetId: String? = nil
            if !existingOriginalsMap.isEmpty {
                let matchKeys = PhotoLibraryService.originalMatchKeys(
                    filename: photo.originalName,
                    creationDate: photo.parsedCreationDate,
                    sizeBytes: photo.size > 0 ? photo.size : nil,
                    isVideo: photo.isVideo
                )
                for key in matchKeys {
                    if let foundId = existingOriginalsMap[key] {
                        matchedOriginalAssetId = foundId
                        tracker.markUploadedOriginal(assetId: foundId, masterHash: photo.hash)
                        break
                    }
                }
            }

            let isActiveUpload = AssetUploadCoordinator.shared.isMasterHashActive(photo.hash)
                || BackgroundUploadTransport.shared.activeMasterHashes().contains(photo.hash.lowercased())
            let hasLiveNativeGalleryAsset = tracker.hasAnyLiveGalleryAsset(forMasterHash: photo.hash)
                || iCloudSyncedProxyAssetId != nil
                || matchedOriginalAssetId != nil
                || isActiveUpload

            let isRestoredProtected = (photo.keepOriginalOnDevice == true)
                || tracker.isRestoredMasterHash(photo.hash)

            // Skip downloading into LocalProxyStore whenever a live copy already exists in native Apple Photos
            // (Cloud tab reads thumbnails & plays videos straight from Apple Photos with zero duplication!).
            let needCachePreview = cachePreviewsLocally
                && !hasLiveNativeGalleryAsset
                && hasServerImagePreview
                && store.previewData(forHash: photo.hash) == nil
            let needCacheVideo = cacheVideosLocally
                && !hasLiveNativeGalleryAsset
                && hasServerVideoProxy
                && store.videoProxyURLIfExists(forHash: photo.hash) == nil

            let alreadyInPhotos: Bool
            if isRestoredProtected || hasLiveNativeGalleryAsset {
                alreadyInPhotos = true
            } else if forceAllMissingInPhotos {
                alreadyInPhotos = false
            } else {
                alreadyInPhotos = tracker.isMasterHandledForPhotos(photo.hash)
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
        if photosTargetsCount > 1 {
            // Insert oldest photos into Apple Photos first and newest photos LAST so
            // Apple Photos "Recents" and third-party share pickers (WhatsApp, Instagram, etc.)
            // show the newest photo first — matching the native Library timeline.
            workItems.sort {
                PhotoChronologicalOrder.areServerPhotosOldestFirst($0.photo, $1.photo)
            }
        }
        await MainActor.run {
            self.isSyncing = true
            self.completedCount = 0
            self.savedToPhotosCount = 0
            self.totalCount = workItems.count
            self.statusText = photosTargetsCount > 0
                ? "Downloading proxies to Apple Photos (0/\(workItems.count))..."
                : "Auto-downloading local proxies (0/\(workItems.count))..."
        }

        let indexedWork = workItems.enumerated().map { (index: $0.offset, item: $0.element) }
        let queue = AsyncWorkQueue(indexedWork)
        let commitGate = photosTargetsCount > 0 ? OrderedCommitGate() : nil
        let workerCount = min(4, workItems.count)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask { [weak self] in
                    while !Task.isCancelled, let work = await queue.next() {
                        let workIndex = work.index
                        let item = work.item
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
                            let canCommit: Bool
                            if let commitGate {
                                canCommit = await commitGate.waitForTurn(workIndex)
                            } else {
                                canCommit = true
                            }
                            if canCommit {
                                do {
                                    _ = try await PhotoLibraryService.saveServerProxyToPhotosAsync(
                                        photo: photo,
                                        imageData: imageData,
                                        videoURL: videoURL
                                    )
                                    savedPhotoNow = true
                                } catch {
                                    // Continue remaining items
                                }
                            }
                            if let commitGate {
                                await commitGate.completeTurn(workIndex)
                            }
                        } else if let commitGate {
                            await commitGate.completeTurn(workIndex)
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
                    if Task.isCancelled, let commitGate {
                        await commitGate.cancelAll()
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

enum DeviceStorageHelper {
    /// Safety buffer kept free on the phone so iOS never hits 0 MB while writing restored originals.
    static let minimumHeadroomBytes: Int64 = 512 * 1024 * 1024 // 512 MB

    static func availableBytes() -> Int64? {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? homeURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]) {
            if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
                return important
            }
            if let standard = values.volumeAvailableCapacity, standard > 0 {
                return Int64(standard)
            }
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeNum = attrs[.systemFreeSize] as? NSNumber {
            return freeNum.int64Value
        }
        return nil
    }
}

enum BatchRestoreOutcome: Sendable {
    case restored(ServerPhoto?, String, String)
    case failed(String)
    case lowStorage(String)

    var displayName: String {
        switch self {
        case .restored(_, _, let name): return name
        case .failed(let name): return name
        case .lowStorage(let name): return name
        }
    }
}

struct RestoreConfirmPrompt: Identifiable {
    let id = UUID()
    let title: String
    let allTargets: [ServerPhoto]
    let unrestoredTargets: [ServerPhoto]
    let skippedCount: Int
    let unrestoredBytes: Int64
    let allBytes: Int64
    let isRestoreAll: Bool
    let leftoverProxyHashes: Set<String>
    let leftoverProxyCount: Int
    let deviceAvailableBytes: Int64?
    let willDisableAutoBackup: Bool

    var hasEnoughStorageForUnrestored: Bool {
        guard let free = deviceAvailableBytes, unrestoredBytes > 0 else { return true }
        return free >= unrestoredBytes + DeviceStorageHelper.minimumHeadroomBytes
    }

    var hasEnoughStorageForAll: Bool {
        guard let free = deviceAvailableBytes, allBytes > 0 else { return true }
        return free >= allBytes + DeviceStorageHelper.minimumHeadroomBytes
    }

    var effectiveTitle: String {
        if !unrestoredTargets.isEmpty && !hasEnoughStorageForUnrestored {
            return "Low Phone Storage"
        }
        if unrestoredTargets.isEmpty && !(isRestoreAll && leftoverProxyCount > 0) && !hasEnoughStorageForAll {
            return "Low Phone Storage"
        }
        return title
    }

    var messageText: String {
        let freeText: String = deviceAvailableBytes.map {
            ByteCountFormatter.string(fromByteCount: max(0, $0), countStyle: .file)
        } ?? "Unknown"

        if unrestoredTargets.isEmpty {
            if isRestoreAll && leftoverProxyCount > 0 {
                return "All \(allTargets.count) already restored · \(leftoverProxyCount) compressed copy(s) left in Photos."
            }
            let allSizeStr = ByteCountFormatter.string(fromByteCount: max(0, allBytes), countStyle: .file)
            if !hasEnoughStorageForAll, let free = deviceAvailableBytes {
                let needExtra = ByteCountFormatter.string(
                    fromByteCount: max(0, (allBytes + DeviceStorageHelper.minimumHeadroomBytes) - free),
                    countStyle: .file
                )
                return "Need ~\(allSizeStr) · Phone free: \(freeText)\nFree up ~\(needExtra) before re-downloading."
            }
            return "All \(allTargets.count) already restored · Phone free: \(freeText)."
        }

        let sizeStr = ByteCountFormatter.string(fromByteCount: max(0, unrestoredBytes), countStyle: .file)
        if !hasEnoughStorageForUnrestored, let free = deviceAvailableBytes {
            let needExtra = ByteCountFormatter.string(
                fromByteCount: max(0, (unrestoredBytes + DeviceStorageHelper.minimumHeadroomBytes) - free),
                countStyle: .file
            )
            return "Need ~\(sizeStr) for \(unrestoredTargets.count) item(s) · Phone free: \(freeText)\nFree up ~\(needExtra) on your iPhone first."
        }

        let skipNote = skippedCount > 0 ? "\nSkipping \(skippedCount) already restored." : ""
        let proxyNote: String = {
            guard isRestoreAll else { return "" }
            return willDisableAutoBackup
                ? " · Removes proxies & turns off Auto Backup."
                : " · Removes compressed copies."
        }()
        return "Restore \(unrestoredTargets.count) (~\(sizeStr)) · Phone free: \(freeText)\(proxyNote)\(skipNote)"
    }

    static func build(
        title: String,
        targets: [ServerPhoto],
        locallyProtectedHashes: Set<String>,
        isRestoreAll: Bool,
        leftoverProxyHashes: Set<String> = [],
        leftoverProxyCount: Int = 0,
        deviceAvailableBytes: Int64? = DeviceStorageHelper.availableBytes(),
        willDisableAutoBackup: Bool = false
    ) -> RestoreConfirmPrompt {
        let normProtected = Set(
            locallyProtectedHashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        let unrestored = targets.filter { photo in
            let norm = photo.hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !photo.isProtectedOriginal && !normProtected.contains(norm)
        }
        return RestoreConfirmPrompt(
            title: title,
            allTargets: targets,
            unrestoredTargets: unrestored,
            skippedCount: max(0, targets.count - unrestored.count),
            unrestoredBytes: unrestored.reduce(into: Int64(0)) { $0 += max(0, $1.size) },
            allBytes: targets.reduce(into: Int64(0)) { $0 += max(0, $1.size) },
            isRestoreAll: isRestoreAll,
            leftoverProxyHashes: leftoverProxyHashes,
            leftoverProxyCount: max(0, leftoverProxyCount),
            deviceAvailableBytes: deviceAvailableBytes,
            willDisableAutoBackup: willDisableAutoBackup
        )
    }
}

private enum RestorePipelineSlot: Sendable {
    case downloaded(photo: ServerPhoto, fileURL: URL, fileSize: Int64, cleanupDir: URL?)
    case failed(photo: ServerPhoto)
    case lowStorage(photo: ServerPhoto)
}

/// Decouples 6 concurrent network downloaders from the ordered Apple Photos batch committer so
/// a slow 4K video at index 0 never stalls subsequent photo downloads, while bounding temporary
/// disk headroom to `maxBufferedAhead` items / `maxBufferedBytes`.
private actor RestorePipelineBuffer {
    private let totalCount: Int
    private let maxBufferedAhead: Int
    private let maxBufferedBytes: Int64

    private var nextCommitIndex: Int = 0
    private var slots: [Int: RestorePipelineSlot] = [:]
    private var bufferedBytes: Int64 = 0
    private var consumerWaiter: CheckedContinuation<[RestorePipelineSlot], Never>?
    private var producerWaiters: [(id: UUID, index: Int, cont: CheckedContinuation<Bool, Never>)] = []
    private var stopped: Bool = false

    init(
        totalCount: Int,
        maxBufferedAhead: Int = 18,
        maxBufferedBytes: Int64 = 320 * 1024 * 1024
    ) {
        self.totalCount = totalCount
        self.maxBufferedAhead = maxBufferedAhead
        self.maxBufferedBytes = maxBufferedBytes
    }

    private func canDownloadNow(index: Int) -> Bool {
        if index <= nextCommitIndex { return true }
        return (index - nextCommitIndex < maxBufferedAhead) && (bufferedBytes < maxBufferedBytes)
    }

    func waitForDownloadSlot(index: Int) async -> Bool {
        if stopped || Task.isCancelled { return false }
        if canDownloadNow(index: index) { return true }

        let waiterId = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if stopped || Task.isCancelled {
                    cont.resume(returning: false)
                    return
                }
                if canDownloadNow(index: index) {
                    cont.resume(returning: true)
                    return
                }
                producerWaiters.append((id: waiterId, index: index, cont: cont))
            }
        } onCancel: {
            Task { await self.cancelProducerWaiter(id: waiterId) }
        }
    }

    private func cancelProducerWaiter(id: UUID) {
        if let idx = producerWaiters.firstIndex(where: { $0.id == id }) {
            let entry = producerWaiters.remove(at: idx)
            entry.cont.resume(returning: false)
        }
    }

    func submit(index: Int, slot: RestorePipelineSlot) {
        if stopped {
            Self.cleanupTempDir(for: slot)
            return
        }
        slots[index] = slot
        if case .downloaded(_, _, let size, _) = slot {
            bufferedBytes += max(0, size)
        }
        if let waiter = consumerWaiter, slots[nextCommitIndex] != nil {
            consumerWaiter = nil
            let batch = drainContiguousBatch()
            waiter.resume(returning: batch)
        }
    }

    func takeNextContiguousBatch() async -> [RestorePipelineSlot] {
        if nextCommitIndex >= totalCount {
            return []
        }
        if slots[nextCommitIndex] != nil {
            return drainContiguousBatch()
        }
        if stopped || Task.isCancelled {
            return []
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if nextCommitIndex >= totalCount {
                    cont.resume(returning: [])
                    return
                }
                if slots[nextCommitIndex] != nil {
                    cont.resume(returning: drainContiguousBatch())
                    return
                }
                if stopped || Task.isCancelled {
                    cont.resume(returning: [])
                    return
                }
                consumerWaiter = cont
            }
        } onCancel: {
            Task { await self.stop() }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        for (_, slot) in slots {
            Self.cleanupTempDir(for: slot)
        }
        slots.removeAll()
        bufferedBytes = 0

        if let waiter = consumerWaiter {
            consumerWaiter = nil
            waiter.resume(returning: [])
        }
        let waitingProducers = producerWaiters
        producerWaiters.removeAll()
        for entry in waitingProducers {
            entry.cont.resume(returning: false)
        }
    }

    private func drainContiguousBatch(
        maxImages: Int = 12,
        maxBatchBytes: Int64 = 64 * 1024 * 1024
    ) -> [RestorePipelineSlot] {
        guard let first = slots.removeValue(forKey: nextCommitIndex) else {
            return []
        }
        nextCommitIndex += 1
        var batch: [RestorePipelineSlot] = [first]
        var batchBytes: Int64 = 0

        switch first {
        case .downloaded(let photo, _, let size, _):
            bufferedBytes = max(0, bufferedBytes - max(0, size))
            batchBytes = max(0, size)
            // Videos commit individually in their exact chronological slot; contiguous photos group up to 12 per performChanges!
            if !photo.isVideo {
                while batch.count < maxImages,
                      let nextSlot = slots[nextCommitIndex],
                      case .downloaded(let nextPhoto, _, let nextSize, _) = nextSlot,
                      !nextPhoto.isVideo,
                      batchBytes + max(0, nextSize) <= maxBatchBytes {
                    _ = slots.removeValue(forKey: nextCommitIndex)
                    nextCommitIndex += 1
                    bufferedBytes = max(0, bufferedBytes - max(0, nextSize))
                    batchBytes += max(0, nextSize)
                    batch.append(nextSlot)
                }
            }
        case .failed, .lowStorage:
            break
        }

        wakeEligibleProducers()
        return batch
    }

    private func wakeEligibleProducers() {
        guard !producerWaiters.isEmpty else { return }
        var remaining: [(id: UUID, index: Int, cont: CheckedContinuation<Bool, Never>)] = []
        for entry in producerWaiters {
            if stopped || canDownloadNow(index: entry.index) {
                entry.cont.resume(returning: !stopped)
            } else {
                remaining.append(entry)
            }
        }
        producerWaiters = remaining
    }

    static func cleanupTempDir(for slot: RestorePipelineSlot) {
        if case .downloaded(_, _, _, let cleanupDir) = slot, let cleanupDir {
            try? FileManager.default.removeItem(at: cleanupDir)
        }
    }
}

enum BatchRestoreRunner {
    struct Summary {
        let succeeded: Int
        let failed: Int
        let cancelled: Bool
        let deletedProxyCount: Int
        let message: String
    }

    static func run(
        targets: [ServerPhoto],
        client: PhotoHubAPIClient,
        deleteCompressedProxies: Bool = false,
        additionalProxyCleanupHashes: Set<String> = [],
        onPhaseChange: (@MainActor (_ stageText: String) -> Void)? = nil,
        onProgress: @MainActor @escaping (
            _ completed: Int,
            _ total: Int,
            _ displayName: String,
            _ updatedPhoto: ServerPhoto?
        ) -> Void
    ) async -> Summary {
        await MainActor.run { BackgroundBackupManager.shared.beginRestorePause() }
        // Insert restored originals chronologically (oldest first, newest LAST) so Apple Photos
        // "Recents" and share sheets show the newest photo first — matching the native Library tab.
        let orderedTargets = PhotoChronologicalOrder.sortServerPhotosOldestFirst(targets)
        let totalCount = orderedTargets.count

        // Warm network connection & build the Apple Photos duplicate-guard map ONCE upfront
        // (eliminates catastrophic O(N^2) per-photo full-library PhotoKit rescans!).
        await onPhaseChange?("Scanning library...")
        async let warmTask: Void = client.warmConnectionIfNeeded()
        let existingOriginalMap: [String: String] = await Task.detached(priority: .userInitiated) {
            PhotoLibraryService.scanExistingOriginalMapInPhotos()
        }.value
        _ = await warmTask

        var succeeded = 0
        var failed = 0
        var completed = 0
        var hitLowStorage = false
        var succeededMasterHashes: [String] = []
        var pendingProtectHashes: [String] = []
        var downloadTargets: [ServerPhoto] = []
        downloadTargets.reserveCapacity(orderedTargets.count)

        // Fast-path: instantly link any originals already sitting in Apple Photos (0 downloads, 0 Photos writes)
        for photo in orderedTargets {
            if Task.isCancelled { break }
            if let existingId = PhotoLibraryService.findExistingLiveOriginalAssetId(
                for: photo,
                precomputedOriginalMap: existingOriginalMap
            ) {
                LocalProxyTracker.shared.markRestoredOriginal(assetId: existingId, masterHash: photo.hash)
                succeeded += 1
                completed += 1
                succeededMasterHashes.append(photo.hash)
                pendingProtectHashes.append(photo.hash)
                await onProgress(completed, totalCount, photo.originalName, nil)
            } else {
                downloadTargets.append(photo)
            }
        }

        // Flush batch-protect in chunks of 50 so we do ~10 fast batch HTTP calls instead of 500 serial POSTs!
        func flushProtectChunkIfNeeded(force: Bool) async {
            let threshold = force ? 1 : 50
            guard pendingProtectHashes.count >= threshold else { return }
            let chunk = pendingProtectHashes
            pendingProtectHashes.removeAll(keepingCapacity: true)
            _ = try? await client.setOriginalsProtectedBatch(
                masterHashes: chunk,
                protected: true,
                notifyStore: false
            )
        }

        await flushProtectChunkIfNeeded(force: false)

        if !Task.isCancelled && !downloadTargets.isEmpty {
            let indexedDownloads = downloadTargets.enumerated().map { (index: $0.offset, photo: $0.element) }
            let queue = AsyncWorkQueue(indexedDownloads)
            let buffer = RestorePipelineBuffer(totalCount: downloadTargets.count)
            let workerCount = min(6, downloadTargets.count)

            let producerTask = Task {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<workerCount {
                        group.addTask {
                            while !Task.isCancelled {
                                guard let work = await queue.next() else { break }
                                let allowed = await buffer.waitForDownloadSlot(index: work.index)
                                if !allowed || Task.isCancelled { break }

                                let item = work.photo
                                if let freeBytes = DeviceStorageHelper.availableBytes() {
                                    let needed = max(Int64(250 * 1024 * 1024), max(0, item.size) + 150 * 1024 * 1024)
                                    if freeBytes < needed {
                                        await buffer.submit(index: work.index, slot: .lowStorage(photo: item))
                                        break
                                    }
                                }

                                let slot = await downloadForBatch(photo: item, client: client)
                                await buffer.submit(index: work.index, slot: slot)
                            }
                        }
                    }
                    await group.waitForAll()
                }
                await buffer.stop()
            }

            // Dedicated ordered batch committer: drains contiguous oldest-first items and commits
            // up to 12 photos inside a SINGLE `PHPhotoLibrary.performChanges` transaction!
            var committedIndices = 0
            while committedIndices < downloadTargets.count && !Task.isCancelled && !hitLowStorage {
                let batch = await buffer.takeNextContiguousBatch()
                if batch.isEmpty { break }
                committedIndices += batch.count

                if batch.count == 1 {
                    switch batch[0] {
                    case .lowStorage(let photo):
                        hitLowStorage = true
                        await buffer.stop()
                        producerTask.cancel()
                        completed += 1
                        await onProgress(completed, totalCount, photo.originalName, nil)
                        continue
                    case .failed(let photo):
                        failed += 1
                        completed += 1
                        await onProgress(completed, totalCount, photo.originalName, nil)
                        continue
                    case .downloaded:
                        break
                    }
                }

                // Extract downloaded items (preserving exact oldest-first chronological order)
                let readyItems: [(photo: ServerPhoto, fileURL: URL, fileSize: Int64, cleanupDir: URL?)] = batch.compactMap { slot in
                    if case .downloaded(let p, let u, let sz, let dir) = slot {
                        return (p, u, sz, dir)
                    }
                    return nil
                }
                guard !readyItems.isEmpty else { continue }

                // Pre-mark all master hashes in this chunk BEFORE committing so background backup never races
                var wasAlreadyRestoredFlags: [Bool] = []
                wasAlreadyRestoredFlags.reserveCapacity(readyItems.count)
                for item in readyItems {
                    wasAlreadyRestoredFlags.append(LocalProxyTracker.shared.isRestoredMasterHash(item.photo.hash))
                    LocalProxyTracker.shared.markRestoredOriginal(assetId: nil, masterHash: item.photo.hash)
                }

                do {
                    let createdIds = try await PhotoLibraryService.saveRestoredOriginalsBatchToPhotosAsync(
                        readyItems.map { ($0.photo, $0.fileURL) }
                    )
                    for (idx, item) in readyItems.enumerated() {
                        let createdId = idx < createdIds.count ? createdIds[idx] : ""
                        LocalProxyTracker.shared.markRestoredOriginal(
                            assetId: createdId.isEmpty ? nil : createdId,
                            masterHash: item.photo.hash
                        )
                        if let dir = item.cleanupDir {
                            try? FileManager.default.removeItem(at: dir)
                        }
                        succeeded += 1
                        completed += 1
                        succeededMasterHashes.append(item.photo.hash)
                        pendingProtectHashes.append(item.photo.hash)
                        await onProgress(completed, totalCount, item.photo.originalName, nil)
                    }
                } catch {
                    // Fallback: commit items one-by-one in exact chronological order so one bad file never breaks the chunk
                    for (idx, item) in readyItems.enumerated() {
                        defer {
                            if let dir = item.cleanupDir {
                                try? FileManager.default.removeItem(at: dir)
                            }
                        }
                        do {
                            let createdId = try await PhotoLibraryService.saveRestoredOriginalToPhotosAsync(
                                photo: item.photo,
                                fileURL: item.fileURL
                            )
                            LocalProxyTracker.shared.markRestoredOriginal(
                                assetId: createdId.isEmpty ? nil : createdId,
                                masterHash: item.photo.hash
                            )
                            succeeded += 1
                            succeededMasterHashes.append(item.photo.hash)
                            pendingProtectHashes.append(item.photo.hash)
                        } catch {
                            if !wasAlreadyRestoredFlags[idx] {
                                LocalProxyTracker.shared.clearRestoredProtection(masterHash: item.photo.hash)
                            }
                            failed += 1
                        }
                        completed += 1
                        await onProgress(completed, totalCount, item.photo.originalName, nil)
                    }
                }

                await flushProtectChunkIfNeeded(force: false)
            }

            await buffer.stop()
            producerTask.cancel()
            await producerTask.value
        }

        // Flush any remaining restored hashes in ONE batch protect call (runs even on cancel / low storage)
        if !pendingProtectHashes.isEmpty {
            let finalHashes = pendingProtectHashes
            pendingProtectHashes.removeAll()
            _ = await Task.detached(priority: .userInitiated) {
                try? await client.setOriginalsProtectedBatch(
                    masterHashes: finalHashes,
                    protected: true,
                    notifyStore: true
                )
            }.value
        }

        let cancelled = Task.isCancelled
        var deletedProxyCount = 0
        var proxyNote = ""

        if deleteCompressedProxies {
            var cleanupHashes = Set(succeededMasterHashes.map { $0.lowercased() })
            if !cancelled && !hitLowStorage {
                cleanupHashes.formUnion(additionalProxyCleanupHashes.map { $0.lowercased() })
            }
            if !cleanupHashes.isEmpty {
                await onPhaseChange?("Deleting compressed copies...")
                let deleteResult = await PhotoLibraryService.deleteCompressedProxyAssets(forMasterHashes: cleanupHashes)
                switch deleteResult {
                case .deleted(let count):
                    deletedProxyCount = count
                    if count > 0 {
                        proxyNote = " · Deleted \(count) proxies"
                    }
                case .cancelledByUser:
                    proxyNote = " · Proxies kept"
                case .noPermission:
                    proxyNote = " · Need Full Photos access"
                case .failed:
                    proxyNote = " · Proxy cleanup failed"
                }
            }
        }

        let message: String
        if hitLowStorage {
            message = "Stopped: low phone storage (restored \(succeeded)\(proxyNote))."
        } else if cancelled {
            message = "Stopped · Restored \(succeeded)\(proxyNote)."
        } else if failed > 0 && succeeded == 0 {
            message = "Restore failed (\(failed))."
        } else if failed > 0 {
            message = "Restored \(succeeded)\(proxyNote) · \(failed) failed."
        } else {
            message = "Restored \(succeeded)\(proxyNote)."
        }
        await MainActor.run { BackgroundBackupManager.shared.endRestorePause() }
        return Summary(
            succeeded: succeeded,
            failed: failed,
            cancelled: cancelled || hitLowStorage,
            deletedProxyCount: deletedProxyCount,
            message: message
        )
    }

    private static func downloadForBatch(
        photo: ServerPhoto,
        client: PhotoHubAPIClient
    ) async -> RestorePipelineSlot {
        let expectedSize: Int64? = photo.size > 0 ? photo.size : nil
        // Reuse existing OriginalDownloadCache hit immediately with zero network I/O
        if let cached = OriginalDownloadCache.shared.getCachedOriginal(
            hash: photo.hash,
            expectedSizeBytes: expectedSize
        ) {
            let sz = (try? cached.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? photo.size
            return .downloaded(photo: photo, fileURL: cached, fileSize: sz, cleanupDir: nil)
        }

        // Stream directly to a disposable temp folder (bypasses 400 MB LRU cache pruning & APFS extra copy).
        // When 6 batch workers run concurrently, single-stream keeps server disk reads sequential for photos;
        // parallel HTTP Ranges activate automatically for large >= 24 MB videos!
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photohub_restore_\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            let fileURL = try await client.downloadMasterToDirectory(
                hash: photo.hash,
                destinationDir: tempDir,
                preferredFilename: photo.originalName,
                expectedSizeBytes: expectedSize,
                isVideo: photo.isVideo,
                allowParallelRanges: photo.size >= 24 * 1024 * 1024
            )
            let sz = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? photo.size
            return .downloaded(photo: photo, fileURL: fileURL, fileSize: sz, cleanupDir: tempDir)
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            return .failed(photo: photo)
        }
    }
}

/// Manages bulk "Restore All Originals to Photos" from Settings so restore jobs
/// survive navigation across tabs and reflect live counts from server & local state.
@MainActor
final class OriginalRestoreManager: ObservableObject {
    static let shared = OriginalRestoreManager()

    @Published private(set) var isLoadingSummary: Bool = false
    @Published private(set) var hasLoadedSummary: Bool = false
    @Published private(set) var totalCount: Int = 0
    @Published private(set) var unrestoredCount: Int = 0
    @Published private(set) var unrestoredBytes: Int64 = 0
    @Published private(set) var deviceAvailableBytes: Int64? = DeviceStorageHelper.availableBytes()

    @Published private(set) var isRestoring: Bool = false
    @Published private(set) var completedCount: Int = 0
    @Published private(set) var batchTotalCount: Int = 0
    @Published private(set) var currentItemName: String = ""
    @Published var statusMessage: String?
    @Published var confirmPrompt: RestoreConfirmPrompt?

    private var cachedPhotos: [ServerPhoto] = []
    private var restoreTask: Task<Void, Never>?

    private init() {}

    func loadCachedSummary(settings: AppSettings) {
        let cached = LocalProxyStore.shared.cachedPhotos(
            baseURL: settings.normalizedBaseURL,
            apiKey: settings.apiKey
        )
        applySummary(photos: cached, markLoaded: !cached.isEmpty)
    }

    func refreshFromServer(settings: AppSettings) async {
        loadCachedSummary(settings: settings)
        guard settings.isSignedIn, let baseURL = settings.normalizedBaseURL else {
            return
        }
        if isLoadingSummary { return }
        isLoadingSummary = true
        defer { isLoadingSummary = false }

        do {
            let fetched = try await PhotoHubAPIClient(settings: settings).fetchAllServerPhotos(sync: true)
            LocalProxyStore.shared.savePhotos(fetched, baseURL: baseURL, apiKey: settings.apiKey)
            applySummary(photos: fetched, markLoaded: true)
        } catch {
            // Keep cached counts if offline
        }
    }

    func requestRestoreAll(settings: AppSettings) {
        guard !isRestoring, !isLoadingSummary,
              settings.isSignedIn,
              let baseURL = settings.normalizedBaseURL else {
            return
        }
        statusMessage = nil
        isLoadingSummary = true

        Task {
            defer { isLoadingSummary = false }
            var targets: [ServerPhoto] = []
            var fetchError: Error?

            do {
                let fetched = try await PhotoHubAPIClient(settings: settings).fetchAllServerPhotos(sync: true)
                LocalProxyStore.shared.savePhotos(fetched, baseURL: baseURL, apiKey: settings.apiKey)
                applySummary(photos: fetched, markLoaded: true)
                targets = fetched
            } catch {
                fetchError = error
                loadCachedSummary(settings: settings)
                targets = cachedPhotos
            }

            if targets.isEmpty {
                if let fetchError {
                    statusMessage = "Could not load server library: \(fetchError.localizedDescription)"
                } else {
                    statusMessage = "No photos or videos found on server yet."
                }
                return
            }

            let allHashes = targets.map { $0.hash.lowercased() }
            let (leftoverHashes, leftoverCount) = await Task.detached(priority: .userInitiated) {
                let verifiedLocal = Set(
                    allHashes.filter { LocalProxyTracker.shared.liveRestoredAssetId(forMasterHash: $0) != nil }
                )
                guard !verifiedLocal.isEmpty else {
                    return (Set<String>(), 0)
                }
                let count = PhotoLibraryService.findCompressedProxyAssets(forMasterHashes: verifiedLocal).count
                return (verifiedLocal, count)
            }.value

            confirmPrompt = RestoreConfirmPrompt.build(
                title: "Restore All Originals",
                targets: targets,
                locallyProtectedHashes: protectedHashes(for: targets),
                isRestoreAll: true,
                leftoverProxyHashes: leftoverHashes,
                leftoverProxyCount: leftoverCount,
                willDisableAutoBackup: settings.nightlyAutoBackupEnabled
            )
        }
    }

    func startRestore(
        targets: [ServerPhoto],
        settings: AppSettings,
        additionalProxyCleanupHashes: Set<String> = []
    ) {
        guard !isRestoring, !targets.isEmpty else { return }
        confirmPrompt = nil
        statusMessage = nil
        completedCount = 0
        batchTotalCount = targets.count
        currentItemName = "Preparing..."
        isRestoring = true

        let baseURL = settings.normalizedBaseURL
        let apiKey = settings.apiKey

        restoreTask?.cancel()
        restoreTask = Task {
            let readWriteGranted = await PhotoLibraryService.requestReadWriteAuthorizationAsync()
            let canWrite = readWriteGranted || PhotoLibraryService.canWriteToPhotosLibrary()
            guard canWrite else {
                isRestoring = false
                currentItemName = ""
                restoreTask = nil
                statusMessage = "Allow Photos permission in iOS Settings to save originals."
                return
            }

            // Turning off Auto Backup during Restore All prevents future photos from being silently offloaded
            // after the user has chosen to reclaim their full-resolution library on device.
            let turnedOffAutoBackup = BackgroundBackupManager.shared.disableAutoBackup(settings: settings)

            let client = PhotoHubAPIClient(settings: settings)
            let summary = await BatchRestoreRunner.run(
                targets: targets,
                client: client,
                deleteCompressedProxies: true,
                additionalProxyCleanupHashes: additionalProxyCleanupHashes,
                onPhaseChange: { [weak self] stage in
                    self?.currentItemName = stage
                }
            ) { [weak self] completed, total, displayName, updatedPhoto in
                guard let self else { return }
                self.completedCount = completed
                self.batchTotalCount = total
                self.currentItemName = displayName
                if let updatedPhoto {
                    LocalProxyStore.shared.updatePhoto(
                        updatedPhoto,
                        baseURL: baseURL,
                        apiKey: apiKey,
                        notify: false
                    )
                    if let idx = self.cachedPhotos.firstIndex(where: {
                        $0.hash.caseInsensitiveCompare(updatedPhoto.hash) == .orderedSame
                    }) {
                        self.cachedPhotos[idx] = updatedPhoto
                    }
                }
            }

            isRestoring = false
            currentItemName = ""
            restoreTask = nil
            let refreshedPhotos = LocalProxyStore.shared.cachedPhotos(baseURL: baseURL, apiKey: apiKey)
            if !refreshedPhotos.isEmpty {
                cachedPhotos = refreshedPhotos
            }
            applySummary(photos: cachedPhotos, markLoaded: hasLoadedSummary || !cachedPhotos.isEmpty)
            NotificationCenter.default.post(name: .localProxyStoreDidChange, object: nil)
            if turnedOffAutoBackup {
                let baseMsg = summary.message.hasSuffix(".") ? String(summary.message.dropLast()) : summary.message
                statusMessage = "\(baseMsg) · Auto Backup off."
            } else {
                statusMessage = summary.message
            }
        }
    }

    func deleteLeftoverCompressedProxies(hashes: Set<String>, settings: AppSettings) {
        guard !isRestoring, !hashes.isEmpty else { return }
        confirmPrompt = nil
        statusMessage = nil
        completedCount = 0
        batchTotalCount = 1
        currentItemName = "Deleting compressed copies from Photos..."
        isRestoring = true

        restoreTask?.cancel()
        restoreTask = Task {
            _ = await PhotoLibraryService.requestReadWriteAuthorizationAsync()
            let deleteResult = await PhotoLibraryService.deleteCompressedProxyAssets(forMasterHashes: hashes)
            isRestoring = false
            currentItemName = ""
            restoreTask = nil
            NotificationCenter.default.post(name: .localProxyStoreDidChange, object: nil)

            switch deleteResult {
            case .deleted(let count):
                statusMessage = count > 0
                    ? "Deleted \(count) compressed copy(s) from Photos."
                    : "No compressed copies found in Photos."
            case .cancelledByUser:
                statusMessage = "Kept compressed copies in Photos (delete cancelled)."
            case .noPermission:
                statusMessage = "Grant Full Access in iOS Settings -> photoHub -> Photos to delete compressed copies."
            case .failed(let detail):
                statusMessage = "Could not delete compressed copies: \(detail)"
            }
        }
    }

    func stopRestore() {
        restoreTask?.cancel()
    }

    func reset() {
        restoreTask?.cancel()
        restoreTask = nil
        cachedPhotos = []
        isLoadingSummary = false
        hasLoadedSummary = false
        totalCount = 0
        unrestoredCount = 0
        unrestoredBytes = 0
        isRestoring = false
        completedCount = 0
        batchTotalCount = 0
        currentItemName = ""
        statusMessage = nil
        confirmPrompt = nil
    }

    private func protectedHashes(for photos: [ServerPhoto]) -> Set<String> {
        Set(
            photos
                .map { $0.hash.lowercased() }
                .filter { LocalProxyTracker.shared.isRestoredMasterHash($0) }
        )
    }

    private func applySummary(photos: [ServerPhoto], markLoaded: Bool) {
        cachedPhotos = photos
        let prompt = RestoreConfirmPrompt.build(
            title: "Restore All Originals",
            targets: photos,
            locallyProtectedHashes: protectedHashes(for: photos),
            isRestoreAll: true
        )
        totalCount = photos.count
        unrestoredCount = prompt.unrestoredTargets.count
        unrestoredBytes = prompt.unrestoredBytes
        deviceAvailableBytes = prompt.deviceAvailableBytes
        hasLoadedSummary = markLoaded
    }
}
