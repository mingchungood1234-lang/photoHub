import Foundation
import Photos
import SwiftUI
import UIKit

@MainActor
final class CompressorViewModel: ObservableObject {
    @Published var candidates: [PhotoCandidate] = []
    @Published var pendingDeleteAssets: [PHAsset] = []
    @Published var isAwaitingDeleteConfirmation: Bool = false
    @Published var deleteErrorAlertMessage: String?
    @Published var isScanning: Bool = false
    @Published var isProcessing: Bool = false
    @Published var permissionStatus: PHAuthorizationStatus = .notDetermined
    @Published var statusBanner: String?
    @Published var totalSavedBytes: Int64 = 0
    @Published var completedCount: Int = 0
    @Published var totalToProcess: Int = 0
    @Published var overallProgressFraction: Double = 0
    @Published var sortMode: CandidateSortMode
    @Published var recentlyDeletedNoticeCount: Int = 0
    @Published var recentlyDeletedNoticeBytes: Int64 = 0

    let settings: AppSettings
    private let photoService = PhotoLibraryService()
    private let tracker = LocalProxyTracker.shared
    private var pendingAutoDeleteWhenActive: Bool = false
    private var activeBgTaskId: UIBackgroundTaskIdentifier = .invalid
    private var activeUploadTask: Task<Void, Never>?
    private var activeContinuedSession: ContinuedUploadSession?
    private var activeItemProgress: [String: Double] = [:]
    private var hasAutoStartedThisSession: Bool = false

    init(settings: AppSettings) {
        self.settings = settings
        self.sortMode = settings.candidateSortMode
        self.permissionStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    var selectedCount: Int {
        candidates.filter { $0.isSelected && !$0.state.isFinished }.count
    }

    var pendingVideoCandidates: [PhotoCandidate] {
        candidates.filter { $0.isVideo && !$0.state.isFinished }
    }

    var pendingVideoEstimatedBytes: Int64 {
        pendingVideoCandidates.reduce(0) { $0 + max(0, $1.estimatedBytes) }
    }

    var totalEligibleEstimatedBytes: Int64 {
        candidates
            .filter { !$0.state.isFinished }
            .reduce(0) { $0 + max(0, $1.estimatedBytes) }
    }

    func setSortMode(_ newMode: CandidateSortMode) {
        sortMode = newMode
        settings.candidateSortMode = newMode
        candidates = PhotoBackupPipeline.sortCandidates(candidates, by: newMode)
    }

    func scanLibrary() {
        guard !isScanning else { return }
        isScanning = true
        statusBanner = nil
        BackgroundBackupManager.shared.pruneMissingAssetsFromStaged()

        photoService.requestAuthorization { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.permissionStatus = status

                guard status == .authorized || status == .limited else {
                    self.isScanning = false
                    self.statusBanner = "Please allow Photos access in iOS Settings to scan your library."
                    return
                }

                let service = self.photoService
                let tracker = self.tracker
                let mode = self.sortMode
                let cachedServerPhotos = LocalProxyStore.shared.cachedPhotos(
                    baseURL: self.settings.normalizedBaseURL,
                    apiKey: self.settings.apiKey
                )
                Task.detached(priority: .userInitiated) { [weak self] in
                    let raw = service.scanCandidates(tracker: tracker, knownServerPhotos: cachedServerPhotos)
                    let sorted = PhotoBackupPipeline.sortCandidates(raw, by: mode)
                    await MainActor.run {
                        guard let self else { return }
                        self.applyScannedCandidates(sorted)
                        self.pendingDeleteAssets.removeAll()
                        self.pendingAutoDeleteWhenActive = false
                        self.isScanning = false
                        if sorted.isEmpty {
                            self.statusBanner = "No uncompressed photos or videos found."
                        }
                    }
                }
            }
        }
    }

    func scanAndAutoCompressIfEnabled(forceNow: Bool = false) {
        if !forceNow {
            guard !hasAutoStartedThisSession,
                  (settings.autoCompressOnOpen || settings.nightlyAutoBackupEnabled) else {
                return
            }
            hasAutoStartedThisSession = true
        }
        guard !isScanning && !isProcessing else { return }
        isScanning = true
        statusBanner = "Finding new photos & videos to back up…"
        BackgroundBackupManager.shared.pruneMissingAssetsFromStaged()

        photoService.requestAuthorization { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.permissionStatus = status
                guard status == .authorized || status == .limited else {
                    self.isScanning = false
                    self.statusBanner = "Allow Full Photos Access in iOS Settings to auto-upload and delete originals."
                    return
                }

                let service = self.photoService
                let tracker = self.tracker
                let mode = self.sortMode
                let cachedServerPhotos = LocalProxyStore.shared.cachedPhotos(
                    baseURL: self.settings.normalizedBaseURL,
                    apiKey: self.settings.apiKey
                )
                Task.detached(priority: .userInitiated) { [weak self] in
                    // Bounded fast scan so auto-upload & iOS 26 Home Screen progress start in under a second
                    let raw = service.scanCandidates(
                        tracker: tracker,
                        knownServerPhotos: cachedServerPhotos,
                        maxResults: 200,
                        maxInspect: 3000
                    )
                    let sorted = PhotoBackupPipeline.sortCandidates(raw, by: mode)
                    await MainActor.run {
                        guard let self else { return }
                        self.applyScannedCandidates(sorted)
                        self.isScanning = false
                        if !sorted.isEmpty && (forceNow || self.settings.autoCompressOnOpen || self.settings.nightlyAutoBackupEnabled) {
                            self.selectAllEligible(true)
                            self.startProcessingSelectedPhotos()
                        } else if sorted.isEmpty {
                            self.statusBanner = "All scanned photos & videos are already backed up."
                        }
                    }
                }
            }
        }
    }

    private func applyScannedCandidates(_ scanned: [PhotoCandidate]) {
        let stagedById = Dictionary(
            uniqueKeysWithValues: BackgroundBackupManager.shared.stagedItems.map { ($0.id, $0) }
        )
        candidates = scanned.map { item in
            var copy = item
            if let staged = stagedById[item.id] {
                copy.state = .readyToDelete(savedBytes: staged.savedBytes)
                copy.isSelected = false
            }
            return copy
        }
    }

    func loadThumbnailIfNeeded(for id: String) {
        guard let index = candidates.firstIndex(where: { $0.id == id }),
              candidates[index].thumbnail == nil else {
            return
        }
        let asset = candidates[index].asset
        photoService.loadThumbnail(for: asset) { [weak self] thumb in
            Task { @MainActor [weak self] in
                guard let self,
                      let thumb,
                      let currentIndex = self.candidates.firstIndex(where: { $0.id == id }) else {
                    return
                }
                if self.candidates[currentIndex].thumbnail == nil {
                    self.candidates[currentIndex].thumbnail = thumb
                }
            }
        }
    }

    func toggleSelection(for id: String) {
        guard let idx = candidates.firstIndex(where: { $0.id == id }) else { return }
        guard !candidates[idx].state.isFinished else { return }
        candidates[idx].isSelected.toggle()
    }

    func selectAllEligible(_ selected: Bool) {
        for idx in candidates.indices where !candidates[idx].state.isFinished {
            candidates[idx].isSelected = selected
        }
    }

    /// Selects the largest eligible videos first for immediate multi-GB space savings.
    func selectTopVideos(maxCount: Int = 25) {
        selectAllEligible(false)
        let sortedVideos = PhotoBackupPipeline.sortCandidates(
            candidates.filter { $0.isVideo && !$0.state.isFinished },
            by: .largestFirst
        ).prefix(maxCount)
        let targetIds = Set(sortedVideos.map { $0.id })
        for idx in candidates.indices where targetIds.contains(candidates[idx].id) {
            candidates[idx].isSelected = true
        }
    }

    func dismissRecentlyDeletedNotice() {
        recentlyDeletedNoticeCount = 0
        recentlyDeletedNoticeBytes = 0
    }

    func triggerStagedOvernightCleanupPrompt() {
        let staged = BackgroundBackupManager.shared.stagedItems
        guard !staged.isEmpty else { return }
        let ids = staged.map { $0.id }
        let liveAssets = PhotoLibraryService.fetchLiveAssets(forLocalIdentifiers: ids)
        guard !liveAssets.isEmpty else {
            BackgroundBackupManager.shared.clearAllStagedItems()
            return
        }
        pendingDeleteAssets = liveAssets
        if totalSavedBytes == 0 {
            totalSavedBytes = BackgroundBackupManager.shared.stagedSavedBytes
        }
        isAwaitingDeleteConfirmation = false
        pendingAutoDeleteWhenActive = false
        scheduleAutomaticDeletePrompt()
    }

    func startProcessingSelectedPhotos() {
        guard !isProcessing else { return }
        let targetIds = candidates
            .filter { $0.isSelected && !$0.state.isFinished }
            .map { $0.id }
        guard !targetIds.isEmpty else { return }

        isProcessing = true
        completedCount = 0
        totalToProcess = targetIds.count
        overallProgressFraction = 0
        activeItemProgress.removeAll()
        statusBanner = nil

        if settings.notifyWhenBackgroundUploadFinishes {
            BackgroundBackupManager.shared.requestNotificationPermissionIfNeeded()
        }

        beginAppBackgroundTask()
        activeUploadTask?.cancel()
        let notifyOnFinish = settings.notifyWhenBackgroundUploadFinishes
        let morningHour = settings.morningReminderHour

        let continuedSession = BackgroundBackupManager.shared.beginContinuedUploadSession(
            totalCount: targetIds.count
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.activeUploadTask?.cancel()
            }
        }
        activeContinuedSession = continuedSession

        let apiClient = PhotoHubAPIClient(settings: settings)
        let format = settings.proxyFormat
        let maxPx = settings.proxyMaxPixelSize
        let quality = settings.proxyQuality
        let uploadMode = settings.uploadMode
        let keepLocal = settings.keepLocalProxyInPhotos
        let normalizedBaseURL = settings.normalizedBaseURL
        let apiKey = settings.apiKey

        activeUploadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else {
                continuedSession?.finish(success: false)
                return
            }

            do {
                let info = try await apiClient.whoami()
                await MainActor.run {
                    self.settings.serverStorage = info.storage
                }
            } catch APIClientError.httpError(401, _) {
                continuedSession?.finish(success: false)
                await MainActor.run {
                    self.activeContinuedSession = nil
                    self.activeUploadTask = nil
                    self.isProcessing = false
                    self.endAppBackgroundTask()
                    self.statusBanner = "Session expired. Please sign in again."
                    LocalProxySyncManager.shared.cancel()
                    self.settings.signOut()
                }
                return
            } catch {
                continuedSession?.finish(success: false)
                await MainActor.run {
                    self.activeContinuedSession = nil
                    self.activeUploadTask = nil
                    self.isProcessing = false
                    self.endAppBackgroundTask()
                    let hostLabel = normalizedBaseURL?.host ?? "server"
                    self.statusBanner = "Server check failed (\(hostLabel)): \(error.localizedDescription)"
                }
                return
            }

            let queue = AsyncWorkQueue(targetIds)
            let videoSemaphore = AsyncSemaphore(value: 1)
            let photosSaveSemaphore = AsyncSemaphore(value: 1)
            let workerCount = min(3, targetIds.count)

            let failedCount = await withTaskGroup(of: Int.self) { group in
                for _ in 0..<workerCount {
                    group.addTask {
                        var workerFailures = 0
                        while !Task.isCancelled, let nextId = await queue.next() {
                            let ok = await self.processSingleCandidate(
                                id: nextId,
                                apiClient: apiClient,
                                format: format,
                                maxPx: maxPx,
                                quality: quality,
                                uploadMode: uploadMode,
                                keepLocal: keepLocal,
                                normalizedBaseURL: normalizedBaseURL,
                                apiKey: apiKey,
                                videoSemaphore: videoSemaphore,
                                photosSaveSemaphore: photosSaveSemaphore,
                                continuedSession: continuedSession,
                                totalCount: targetIds.count
                            )
                            if !ok {
                                workerFailures += 1
                            }
                        }
                        return workerFailures
                    }
                }

                var totalFailures = 0
                for await workerFailures in group {
                    totalFailures += workerFailures
                }
                return totalFailures
            }

            if let updatedInfo = try? await apiClient.whoami() {
                await MainActor.run {
                    self.settings.serverStorage = updatedInfo.storage
                }
            }

            let finishedCleanly = !Task.isCancelled && failedCount == 0

            await MainActor.run {
                self.activeContinuedSession = nil
                self.activeUploadTask = nil
                self.isProcessing = false
                self.overallProgressFraction = finishedCleanly ? 1.0 : self.overallProgressFraction
                self.endAppBackgroundTask()
                let savedStr = ByteCountFormatter.string(fromByteCount: self.totalSavedBytes, countStyle: .file)
                if !self.pendingDeleteAssets.isEmpty {
                    let readyCount = self.pendingDeleteAssets.count
                    continuedSession?.finish(
                        success: finishedCleanly,
                        completionNote: "Done · Tap notification to delete \(readyCount) original(s)"
                    )
                    if notifyOnFinish && UIApplication.shared.applicationState != .active {
                        BackgroundBackupManager.shared.sendDeleteOriginalsNotification(
                            count: readyCount,
                            savedBytes: self.totalSavedBytes,
                            immediate: true,
                            morningHour: morningHour
                        )
                    }
                    self.scheduleAutomaticDeletePrompt()
                } else {
                    continuedSession?.finish(success: finishedCleanly, completionNote: "All originals backed up")
                    if failedCount > 0 && self.statusBanner == nil {
                        self.statusBanner = "Finished with \(failedCount) error(s). Space saved: \(savedStr)."
                    } else if failedCount == 0 {
                        self.statusBanner = "Finished! All originals backed up & verified."
                    }
                }
            }
        }
    }

    private func beginAppBackgroundTask() {
        endAppBackgroundTask()
        activeBgTaskId = UIApplication.shared.beginBackgroundTask(withName: "PhotoHubCompression") { [weak self] in
            Task { @MainActor in
                self?.endAppBackgroundTask()
            }
        }
    }

    private func endAppBackgroundTask() {
        guard activeBgTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(activeBgTaskId)
        activeBgTaskId = .invalid
    }

    private func processSingleCandidate(
        id currentId: String,
        apiClient: PhotoHubAPIClient,
        format: ProxyFormat,
        maxPx: Int,
        quality: Double,
        uploadMode: UploadMode,
        keepLocal: Bool,
        normalizedBaseURL: URL?,
        apiKey: String,
        videoSemaphore: AsyncSemaphore,
        photosSaveSemaphore: AsyncSemaphore,
        continuedSession: ContinuedUploadSession?,
        totalCount: Int
    ) async -> Bool {
        let candidate: PhotoCandidate? = await MainActor.run {
            guard let index = self.candidates.firstIndex(where: { $0.id == currentId }) else {
                return nil
            }
            self.candidates[index].state = .hashing
            return self.candidates[index]
        }

        guard let candidate else {
            await MainActor.run {
                self.completedCount += 1
                self.recordItemProgress(
                    id: currentId,
                    fraction: 1.0,
                    totalCount: totalCount,
                    statusText: "",
                    continuedSession: continuedSession
                )
            }
            return true
        }

        do {
            let result = try await PhotoBackupPipeline.backupAndProxyAsset(
                candidate: candidate,
                photoService: photoService,
                apiClient: apiClient,
                tracker: tracker,
                format: format,
                maxPixelSize: maxPx,
                quality: quality,
                uploadMode: uploadMode,
                keepLocalProxy: keepLocal,
                normalizedBaseURL: normalizedBaseURL,
                cacheScopeKey: apiKey,
                videoSemaphore: videoSemaphore,
                photosSaveSemaphore: photosSaveSemaphore
            ) { [weak self] newState in
                Task { @MainActor in
                    guard let self else { return }
                    self.updateState(id: currentId, state: newState)
                    self.recordItemProgress(
                        id: currentId,
                        fraction: Self.stageFraction(for: newState),
                        totalCount: totalCount,
                        statusText: candidate.filename,
                        continuedSession: continuedSession
                    )
                }
            }

            await MainActor.run {
                switch result {
                case .backedUp(let outcome):
                    self.stageOriginalForDeletion(
                        id: currentId,
                        asset: candidate.asset,
                        savedBytes: outcome.savedBytes
                    )
                    BackgroundBackupManager.shared.appendStagedItems([
                        StagedCleanupItem(
                            id: currentId,
                            filename: outcome.filename,
                            masterSha256: outcome.masterSha256,
                            savedBytes: outcome.savedBytes,
                            verifiedAt: Date()
                        ),
                    ])
                case .skippedExistingProxy:
                    if let idx = self.candidates.firstIndex(where: { $0.id == currentId }) {
                        self.candidates[idx].state = .alreadyProxy
                        self.candidates[idx].isSelected = false
                    }
                case .skippedProtectedOriginal:
                    if let idx = self.candidates.firstIndex(where: { $0.id == currentId }) {
                        self.candidates[idx].state = .skipped("Restored Original Protected")
                        self.candidates[idx].isSelected = false
                    }
                }
                self.completedCount += 1
                self.recordItemProgress(
                    id: currentId,
                    fraction: 1.0,
                    totalCount: totalCount,
                    statusText: candidate.filename,
                    continuedSession: continuedSession
                )
            }
            return true
        } catch {
            await MainActor.run {
                self.updateState(id: currentId, state: .failed(error.localizedDescription))
                self.statusBanner = error.localizedDescription
                self.completedCount += 1
                self.recordItemProgress(
                    id: currentId,
                    fraction: 1.0,
                    totalCount: totalCount,
                    statusText: candidate.filename,
                    continuedSession: continuedSession
                )
            }
            return false
        }
    }

    private func recordItemProgress(
        id: String,
        fraction: Double,
        totalCount: Int,
        statusText: String,
        continuedSession: ContinuedUploadSession?
    ) {
        let existing = activeItemProgress[id] ?? 0.0
        activeItemProgress[id] = max(existing, min(1.0, max(0.0, fraction)))
        let totalSum = activeItemProgress.values.reduce(0.0, +)
        let overall = min(1.0, max(0.0, totalSum / Double(max(1, totalCount))))
        overallProgressFraction = overall
        continuedSession?.update(
            fraction: overall,
            completed: completedCount,
            total: totalCount,
            statusText: statusText
        )
    }

    private static func stageFraction(for state: PhotoCompressionState) -> Double {
        switch state {
        case .pending: return 0.0
        case .hashing: return 0.06
        case .uploading(let p): return 0.12 + min(1.0, max(0.0, p)) * 0.62
        case .verifyingChecksum: return 0.78
        case .creatingProxy: return 0.86
        case .replacingInPhotos: return 0.94
        case .alreadyProxy, .readyToDelete, .completed, .skipped, .failed: return 1.0
        }
    }

    private func stageOriginalForDeletion(id: String, asset: PHAsset, savedBytes: Int64) {
        if let idx = candidates.firstIndex(where: { $0.id == id }) {
            candidates[idx].state = .readyToDelete(savedBytes: savedBytes)
            candidates[idx].isSelected = false
        }
        if !pendingDeleteAssets.contains(where: { $0.localIdentifier == asset.localIdentifier }) {
            pendingDeleteAssets.append(asset)
        }
        totalSavedBytes += savedBytes
    }

    /// Automatically pops up the native iOS delete confirmation dialog shortly after upload + proxy save completes.
    func scheduleAutomaticDeletePrompt() {
        guard !pendingDeleteAssets.isEmpty, !isAwaitingDeleteConfirmation else { return }

        isAwaitingDeleteConfirmation = true
        let readyCount = pendingDeleteAssets.count
        let savedStr = ByteCountFormatter.string(fromByteCount: max(0, totalSavedBytes), countStyle: .file)
        statusBanner = "Backed up & SHA-256 verified! Tap 'Delete' on Apple's popup to remove \(readyCount) original photo\(readyCount == 1 ? "" : "s") from iPhone (saves ~\(savedStr))."

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self,
                  self.isAwaitingDeleteConfirmation,
                  !self.pendingDeleteAssets.isEmpty else {
                return
            }

            guard UIApplication.shared.applicationState == .active else {
                self.isAwaitingDeleteConfirmation = false
                self.pendingAutoDeleteWhenActive = true
                self.statusBanner = "Upload & compression finished! Tap here to delete \(self.pendingDeleteAssets.count) original photo(s) from your iPhone (free ~\(savedStr))."
                return
            }

            self.performDelete(assets: self.pendingDeleteAssets)
        }
    }

    func onAppBecameActive() {
        BackgroundBackupManager.shared.pruneMissingAssetsFromStaged()
        guard pendingAutoDeleteWhenActive,
              !pendingDeleteAssets.isEmpty,
              !isAwaitingDeleteConfirmation,
              !isProcessing else {
            return
        }
        pendingAutoDeleteWhenActive = false
        scheduleAutomaticDeletePrompt()
    }

    func handleNotificationOpenCleanup() {
        BackgroundBackupManager.shared.pendingOpenCleanupFromNotification = false
        guard !isProcessing else { return }
        if !pendingDeleteAssets.isEmpty {
            pendingAutoDeleteWhenActive = false
            retryPendingDeleteAlert()
        } else if !BackgroundBackupManager.shared.stagedItems.isEmpty {
            triggerStagedOvernightCleanupPrompt()
        }
    }

    func retryPendingDeleteAlert() {
        guard !pendingDeleteAssets.isEmpty, !isAwaitingDeleteConfirmation else { return }
        pendingAutoDeleteWhenActive = false
        isAwaitingDeleteConfirmation = true
        performDelete(assets: pendingDeleteAssets)
    }

    func dismissPendingDeleteAfterError() {
        let pendingIds = Set(pendingDeleteAssets.map { $0.localIdentifier })
        for idx in candidates.indices where pendingIds.contains(candidates[idx].id) {
            candidates[idx].state = .skipped("Backed up (SHA-256) • Original kept")
            candidates[idx].isSelected = false
        }
        BackgroundBackupManager.shared.removeStagedItems(ids: pendingIds)
        pendingDeleteAssets.removeAll()
        pendingAutoDeleteWhenActive = false
        deleteErrorAlertMessage = nil
    }

    private func performDelete(assets: [PHAsset]) {
        let targetIds = Set(assets.map { $0.localIdentifier })
        photoService.deleteOriginalAssets(assets) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isAwaitingDeleteConfirmation = false

                switch result {
                case .success(.deleted(let deletedIds)):
                    let deletedSet = Set(deletedIds)
                    let stagedSaved = BackgroundBackupManager.shared.stagedItems
                        .filter { deletedSet.contains($0.id) }
                        .reduce(Int64(0)) { $0 + max(0, $1.savedBytes) }
                    let freedBytes = self.totalSavedBytes > 0 ? self.totalSavedBytes : stagedSaved

                    self.candidates.removeAll { deletedSet.contains($0.id) }
                    self.pendingDeleteAssets.removeAll { deletedSet.contains($0.localIdentifier) }
                    BackgroundBackupManager.shared.removeStagedItems(ids: deletedSet)

                    self.recentlyDeletedNoticeCount += deletedSet.count
                    self.recentlyDeletedNoticeBytes += max(0, freedBytes)

                    let savedStr = ByteCountFormatter.string(fromByteCount: max(0, freedBytes), countStyle: .file)
                    if self.pendingDeleteAssets.isEmpty {
                        self.statusBanner = "Verified & moved \(deletedSet.count) original(s) (\(savedStr)) to Apple Photos → Recently Deleted."
                    } else {
                        self.statusBanner = "Deleted \(deletedSet.count) original(s). \(self.pendingDeleteAssets.count) item(s) still remain."
                    }

                case .success(.cancelledByUser):
                    for idx in self.candidates.indices where targetIds.contains(self.candidates[idx].id) {
                        self.candidates[idx].state = .skipped("Backed up (SHA-256) • Kept on iPhone")
                        self.candidates[idx].isSelected = false
                    }
                    self.pendingDeleteAssets.removeAll { targetIds.contains($0.localIdentifier) }
                    BackgroundBackupManager.shared.removeStagedItems(ids: targetIds)
                    self.statusBanner = "Originals kept on iPhone (safely backed up on server)."

                case .failure(let error):
                    self.statusBanner = error.localizedDescription
                    self.deleteErrorAlertMessage = error.localizedDescription
                }
            }
        }
    }

    private func updateState(id: String, state: PhotoCompressionState) {
        if let idx = candidates.firstIndex(where: { $0.id == id }) {
            candidates[idx].state = state
        }
    }
}
