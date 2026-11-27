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
    @Published var isCheckingServerProxies: Bool = false
    @Published var isInspectingGalleryPicks: Bool = false
    @Published var galleryInspectionItems: [GalleryProxyInspectionItem]? = nil
    @Published var inspectionBusyId: String? = nil
    @Published var inspectorActionMessage: String? = nil
    @Published var inspectorShareItem: ShareSheetItem? = nil
    @Published var recentlyDeletedNoticeCount: Int = 0
    @Published var recentlyDeletedNoticeBytes: Int64 = 0
    @Published private(set) var backgroundActiveCount: Int = 0

    let settings: AppSettings
    private let photoService = PhotoLibraryService()
    private let tracker = LocalProxyTracker.shared
    private var pendingAutoDeleteWhenActive: Bool = false
    private var activeBgTaskId: UIBackgroundTaskIdentifier = .invalid
    private var activeUploadTask: Task<Void, Never>?
    private var deepProxyScanTask: Task<Void, Never>?
    private var activeItemProgress: [String: Double] = [:]
    private var hasAutoStartedThisSession: Bool = false

    init(settings: AppSettings) {
        self.settings = settings
        self.sortMode = settings.candidateSortMode
        self.permissionStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        self.backgroundActiveCount = AssetUploadCoordinator.shared.backgroundActiveAssetIds().count
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
        deepProxyScanTask?.cancel()
        isScanning = true
        isCheckingServerProxies = false
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
                BackgroundBackupManager.shared.ensurePhotoObserverIfAuthorized()

                let service = self.photoService
                let tracker = self.tracker
                let mode = self.sortMode
                let backupOnly = self.settings.isBackupOnlyMode
                let isSignedIn = self.settings.isSignedIn
                let cachedServerPhotos = LocalProxyStore.shared.cachedPhotos(
                    baseURL: self.settings.normalizedBaseURL,
                    apiKey: self.settings.apiKey
                )
                Task.detached(priority: .userInitiated) { [weak self] in
                    let raw = service.scanCandidates(
                        tracker: tracker,
                        knownServerPhotos: cachedServerPhotos,
                        skipBackedUpOriginals: backupOnly
                    )
                    let sorted = PhotoBackupPipeline.sortCandidates(raw, by: mode)
                    let eligibleCount = sorted.filter { !$0.state.isFinished }.count
                    await MainActor.run {
                        guard let self else { return }
                        self.applyScannedCandidates(sorted)
                        self.pendingDeleteAssets.removeAll()
                        self.pendingAutoDeleteWhenActive = false
                        self.isScanning = false
                        if sorted.isEmpty {
                            self.statusBanner = backupOnly
                                ? "All photos & videos are safely backed up · Originals kept on iPhone."
                                : "No uncompressed photos or videos found to compress."
                        }
                        if eligibleCount > 0 && isSignedIn {
                            self.launchDeepProxyDetection(cachedServerPhotos: cachedServerPhotos)
                        }
                    }
                }
            }
        }
    }

    func scanAndAutoCompressIfEnabled(forceNow: Bool = false) {
        if !forceNow {
            guard !hasAutoStartedThisSession, settings.autoCompressOnOpen else {
                return
            }
            hasAutoStartedThisSession = true
        }
        guard !isScanning && !isProcessing else { return }
        deepProxyScanTask?.cancel()
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
                BackgroundBackupManager.shared.ensurePhotoObserverIfAuthorized()

                let service = self.photoService
                let tracker = self.tracker
                let mode = self.sortMode
                let backupOnly = self.settings.isBackupOnlyMode
                let isSignedIn = self.settings.isSignedIn
                let apiClient = PhotoHubAPIClient(settings: self.settings)
                let cachedServerPhotos = LocalProxyStore.shared.cachedPhotos(
                    baseURL: self.settings.normalizedBaseURL,
                    apiKey: self.settings.apiKey
                )
                Task.detached(priority: .userInitiated) { [weak self] in
                    let raw = service.scanCandidates(
                        tracker: tracker,
                        knownServerPhotos: cachedServerPhotos,
                        maxResults: 200,
                        maxInspect: 3000,
                        skipBackedUpOriginals: backupOnly
                    )
                    var sorted = PhotoBackupPipeline.sortCandidates(raw, by: mode)
                    if isSignedIn && sorted.contains(where: { $0.state == .pending }) {
                        await MainActor.run {
                            self?.statusBanner = "Checking Photos items for compressed proxies…"
                        }
                        let matches = await GalleryProxyDetector.enrichCandidatesWithServer(
                            candidates: sorted,
                            tracker: tracker,
                            client: apiClient,
                            cachedServerPhotos: cachedServerPhotos
                        )
                        if !matches.isEmpty {
                            sorted = Self.applyDeepMatches(sorted, matches: matches, backupOnly: backupOnly, tracker: tracker)
                        }
                    }
                    let eligibleCount = sorted.filter { !$0.state.isFinished }.count
                    await MainActor.run {
                        guard let self else { return }
                        self.applyScannedCandidates(sorted)
                        self.isScanning = false
                        if eligibleCount > 0 && (forceNow || self.settings.autoCompressOnOpen) {
                            self.selectAllEligible(true)
                            self.startProcessingSelectedPhotos()
                        } else if eligibleCount == 0 {
                            self.statusBanner = "All scanned photos & videos are already backed up."
                        }
                    }
                }
            }
        }
    }

    private func launchDeepProxyDetection(cachedServerPhotos: [ServerPhoto]) {
        deepProxyScanTask?.cancel()
        let snapshot = candidates
        guard snapshot.contains(where: { $0.state == .pending && !$0.isVideo }) else { return }

        isCheckingServerProxies = true
        let client = PhotoHubAPIClient(settings: self.settings)
        let tracker = self.tracker
        let backupOnly = self.settings.isBackupOnlyMode

        deepProxyScanTask = Task.detached(priority: .utility) { [weak self] in
            let matches = await GalleryProxyDetector.enrichCandidatesWithServer(
                candidates: snapshot,
                tracker: tracker,
                client: client,
                cachedServerPhotos: cachedServerPhotos
            )
            await MainActor.run {
                guard let self else { return }
                if !matches.isEmpty {
                    self.candidates = Self.applyDeepMatches(self.candidates, matches: matches, backupOnly: backupOnly, tracker: tracker)
                    if self.candidates.isEmpty {
                        self.statusBanner = "All scanned photos & videos are already backed up."
                    }
                }
                self.isCheckingServerProxies = false
            }
        }
    }

    private nonisolated static func applyDeepMatches(
        _ items: [PhotoCandidate],
        matches: [String: CandidateDeepCheckMatch],
        backupOnly: Bool = false,
        tracker: LocalProxyTracker = .shared
    ) -> [PhotoCandidate] {
        items.compactMap { item in
            guard let m = matches[item.id] else { return item }
            if m.isProxy || (m.isMaster && m.isProtectedOriginal) {
                // Already recorded in LocalProxyTracker; remove cleanly so Compress stays focused on uncompressed items.
                return nil
            }
            if backupOnly && m.isMaster {
                if let hash = m.masterHash, !hash.isEmpty {
                    tracker.markUploadedOriginal(assetId: item.id, masterHash: hash)
                }
                return nil
            }
            var copy = item
            if m.isMaster {
                copy.masterHash = m.masterHash ?? item.masterHash
                copy.detectionSource = m.signal
                copy.linkedOriginalName = m.originalName ?? item.linkedOriginalName
                copy.linkedOriginalBytes = m.originalSizeBytes ?? item.linkedOriginalBytes
                copy.isBackedUpOnServer = true
            }
            return copy
        }
    }

    private func applyScannedCandidates(_ scanned: [PhotoCandidate]) {
        let stagedById = Dictionary(
            uniqueKeysWithValues: BackgroundBackupManager.shared.stagedItems.map { ($0.id, $0) }
        )
        let bgActiveIds = AssetUploadCoordinator.shared.backgroundActiveAssetIds()
        backgroundActiveCount = bgActiveIds.count
        candidates = scanned.map { item in
            var copy = item
            if let staged = stagedById[item.id] {
                copy.state = .readyToDelete(savedBytes: staged.savedBytes)
                copy.isSelected = false
            } else if bgActiveIds.contains(item.id) {
                copy.state = .uploadingInBackground
                copy.isSelected = false
            }
            return copy
        }
    }

    func syncBackgroundStateToCandidates() {
        let bgActiveIds = AssetUploadCoordinator.shared.backgroundActiveAssetIds()
        backgroundActiveCount = bgActiveIds.count
        let stagedById = Dictionary(
            uniqueKeysWithValues: BackgroundBackupManager.shared.stagedItems.map { ($0.id, $0) }
        )
        for idx in candidates.indices {
            let id = candidates[idx].id
            if let staged = stagedById[id] {
                candidates[idx].state = .readyToDelete(savedBytes: staged.savedBytes)
                candidates[idx].isSelected = false
            } else if bgActiveIds.contains(id) {
                candidates[idx].state = .uploadingInBackground
                candidates[idx].isSelected = false
            } else if candidates[idx].state == .uploadingInBackground {
                candidates[idx].state = .pending
            }
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
        let selectedCandidates = candidates.filter { $0.isSelected && !$0.state.isFinished }
        guard !selectedCandidates.isEmpty else { return }
        let backupOnly = settings.isBackupOnlyMode
        let effectiveKeepLocal = !backupOnly && settings.keepLocalProxyInPhotos
        // When keeping lightweight proxies in Apple Photos, process & save chronologically
        // oldest-first so the newest photo is inserted LAST and shows FIRST in Recents / Share pickers.
        let orderedCandidates = (effectiveKeepLocal && selectedCandidates.count > 1)
            ? PhotoChronologicalOrder.sortCandidatesOldestFirst(selectedCandidates)
            : selectedCandidates
        let targetIds = orderedCandidates.map { $0.id }

        isProcessing = true
        completedCount = 0
        totalToProcess = targetIds.count
        overallProgressFraction = 0
        activeItemProgress.removeAll()
        statusBanner = nil

        if !backupOnly && settings.notifyWhenBackgroundUploadFinishes {
            BackgroundBackupManager.shared.requestNotificationPermissionIfNeeded()
        }

        beginAppBackgroundTask()
        activeUploadTask?.cancel()
        let notifyOnFinish = !backupOnly && settings.notifyWhenBackgroundUploadFinishes
        let morningHour = settings.morningReminderHour

        let apiClient = PhotoHubAPIClient(settings: settings)
        let format = settings.proxyFormat
        let maxPx = settings.proxyMaxPixelSize
        let quality = settings.proxyQuality
        let uploadMode = settings.uploadMode
        let keepLocal = effectiveKeepLocal
        let normalizedBaseURL = settings.normalizedBaseURL
        let apiKey = settings.apiKey

        activeUploadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            do {
                let info = try await apiClient.whoami()
                await MainActor.run {
                    self.settings.serverStorage = info.storage
                }
            } catch APIClientError.httpError(401, _) {
                await MainActor.run {
                    self.activeUploadTask = nil
                    self.isProcessing = false
                    self.endAppBackgroundTask()
                    self.statusBanner = "Session expired. Please sign in again."
                    LocalProxySyncManager.shared.cancel()
                    self.settings.signOut()
                }
                return
            } catch {
                await MainActor.run {
                    self.activeUploadTask = nil
                    self.isProcessing = false
                    self.endAppBackgroundTask()
                    let hostLabel = normalizedBaseURL?.host ?? "server"
                    self.statusBanner = "Server check failed (\(hostLabel)): \(error.localizedDescription)"
                }
                return
            }

            let indexedTargets = targetIds.enumerated().map { (index: $0.offset, id: $0.element) }
            let queue = AsyncWorkQueue(indexedTargets)
            let videoSemaphore = AsyncSemaphore(value: 1)
            let photosSaveSemaphore = AsyncSemaphore(value: 1)
            let commitGate = keepLocal ? OrderedCommitGate() : nil
            let workerCount = min(3, targetIds.count)

            let failedCount = await withTaskGroup(of: Int.self) { group in
                for _ in 0..<workerCount {
                    group.addTask {
                        var workerFailures = 0
                        while !Task.isCancelled, let work = await queue.next() {
                            let ok = await self.processSingleCandidate(
                                id: work.id,
                                apiClient: apiClient,
                                format: format,
                                maxPx: maxPx,
                                quality: quality,
                                uploadMode: uploadMode,
                                keepLocal: keepLocal,
                                backupOnly: backupOnly,
                                normalizedBaseURL: normalizedBaseURL,
                                apiKey: apiKey,
                                videoSemaphore: videoSemaphore,
                                photosSaveSemaphore: photosSaveSemaphore,
                                commitGate: commitGate,
                                commitIndex: work.index,
                                totalCount: targetIds.count
                            )
                            if !ok {
                                workerFailures += 1
                            }
                        }
                        if Task.isCancelled, let commitGate {
                            await commitGate.cancelAll()
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
            if let commitGate {
                await commitGate.cancelAll()
            }

            if let updatedInfo = try? await apiClient.whoami() {
                await MainActor.run {
                    self.settings.serverStorage = updatedInfo.storage
                }
            }

            let finishedCleanly = !Task.isCancelled && failedCount == 0

            await MainActor.run {
                self.activeUploadTask = nil
                self.isProcessing = false
                self.overallProgressFraction = finishedCleanly ? 1.0 : self.overallProgressFraction
                self.endAppBackgroundTask()
                let savedStr = ByteCountFormatter.string(fromByteCount: self.totalSavedBytes, countStyle: .file)
                if !backupOnly && !self.pendingDeleteAssets.isEmpty {
                    let readyCount = self.pendingDeleteAssets.count
                    if notifyOnFinish && UIApplication.shared.applicationState != .active {
                        BackgroundBackupManager.shared.sendDeleteOriginalsNotification(
                            count: readyCount,
                            savedBytes: self.totalSavedBytes,
                            immediate: true,
                            morningHour: morningHour
                        )
                    }
                    self.scheduleAutomaticDeletePrompt()
                } else if failedCount > 0 && self.statusBanner == nil {
                    self.statusBanner = backupOnly
                        ? "Finished with \(failedCount) error(s). Backed-up originals kept on iPhone."
                        : "Finished with \(failedCount) error(s). Space saved: \(savedStr)."
                } else if failedCount == 0 {
                    self.statusBanner = backupOnly
                        ? "Backed up \(targetIds.count) item(s) safely · Originals kept on iPhone."
                        : "Finished! All originals backed up & verified."
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
        backupOnly: Bool = false,
        normalizedBaseURL: URL?,
        apiKey: String,
        videoSemaphore: AsyncSemaphore,
        photosSaveSemaphore: AsyncSemaphore,
        commitGate: OrderedCommitGate? = nil,
        commitIndex: Int? = nil,
        totalCount: Int
    ) async -> Bool {
        let releaseTurnIfNeeded: () async -> Void = {
            if let commitGate, let commitIndex {
                await commitGate.completeTurn(commitIndex)
            }
        }

        let candidate: PhotoCandidate? = await MainActor.run {
            guard let index = self.candidates.firstIndex(where: { $0.id == currentId }) else {
                return nil
            }
            return self.candidates[index]
        }

        guard let candidate else {
            await releaseTurnIfNeeded()
            await MainActor.run {
                self.completedCount += 1
                self.recordItemProgress(id: currentId, fraction: 1.0, totalCount: totalCount)
            }
            return true
        }

        let canProcess: Bool = await MainActor.run {
            if let staged = BackgroundBackupManager.shared.stagedItems.first(where: { $0.id == currentId }) {
                self.stageOriginalForDeletion(id: currentId, asset: candidate.asset, savedBytes: staged.savedBytes)
                self.completedCount += 1
                self.recordItemProgress(id: currentId, fraction: 1.0, totalCount: totalCount)
                return false
            }
            if AssetUploadCoordinator.shared.isClaimedByBackground(currentId) ||
                !AssetUploadCoordinator.shared.tryClaimAsset(currentId, owner: .manual) {
                self.updateState(id: currentId, state: .uploadingInBackground)
                if let idx = self.candidates.firstIndex(where: { $0.id == currentId }) {
                    self.candidates[idx].isSelected = false
                }
                self.completedCount += 1
                self.recordItemProgress(id: currentId, fraction: 1.0, totalCount: totalCount)
                return false
            }
            self.updateState(id: currentId, state: .hashing)
            return true
        }

        guard canProcess else {
            await releaseTurnIfNeeded()
            return true
        }
        defer { AssetUploadCoordinator.shared.releaseAsset(currentId, owner: .manual) }

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
                photosSaveSemaphore: photosSaveSemaphore,
                commitGate: commitGate,
                commitIndex: commitIndex
            ) { [weak self] newState in
                Task { @MainActor in
                    guard let self else { return }
                    self.updateState(id: currentId, state: newState)
                    self.recordItemProgress(
                        id: currentId,
                        fraction: Self.stageFraction(for: newState),
                        totalCount: totalCount
                    )
                }
            }

            await MainActor.run {
                switch result {
                case .backedUp(let outcome):
                    if backupOnly {
                        self.updateState(id: currentId, state: .completed(savedBytes: 0))
                        if let idx = self.candidates.firstIndex(where: { $0.id == currentId }) {
                            self.candidates[idx].isSelected = false
                        }
                    } else {
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
                    }
                case .skippedExistingProxy, .skippedProtectedOriginal:
                    self.candidates.removeAll { $0.id == currentId }
                case .skippedInFlight:
                    if let staged = BackgroundBackupManager.shared.stagedItems.first(where: { $0.id == currentId }) {
                        self.stageOriginalForDeletion(id: currentId, asset: candidate.asset, savedBytes: staged.savedBytes)
                    } else if let idx = self.candidates.firstIndex(where: { $0.id == currentId }) {
                        self.candidates[idx].state = AssetUploadCoordinator.shared.isClaimedByBackground(currentId)
                            ? .uploadingInBackground
                            : .skipped("Already Uploading")
                        self.candidates[idx].isSelected = false
                    }
                }
                self.completedCount += 1
                self.recordItemProgress(id: currentId, fraction: 1.0, totalCount: totalCount)
            }
            return true
        } catch {
            await MainActor.run {
                self.updateState(id: currentId, state: .failed(error.localizedDescription))
                self.statusBanner = error.localizedDescription
                self.completedCount += 1
                self.recordItemProgress(id: currentId, fraction: 1.0, totalCount: totalCount)
            }
            return false
        }
    }

    private func recordItemProgress(
        id: String,
        fraction: Double,
        totalCount: Int
    ) {
        let existing = activeItemProgress[id] ?? 0.0
        activeItemProgress[id] = max(existing, min(1.0, max(0.0, fraction)))
        let totalSum = activeItemProgress.values.reduce(0.0, +)
        overallProgressFraction = min(1.0, max(0.0, totalSum / Double(max(1, totalCount))))
    }

    private static func stageFraction(for state: PhotoCompressionState) -> Double {
        switch state {
        case .pending: return 0.0
        case .hashing: return 0.06
        case .uploading(let p): return 0.12 + min(1.0, max(0.0, p)) * 0.62
        case .verifyingChecksum: return 0.78
        case .creatingProxy: return 0.86
        case .replacingInPhotos: return 0.94
        case .alreadyProxy, .uploadingInBackground, .readyToDelete, .completed, .skipped, .failed: return 1.0
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

    // MARK: - Native Gallery Proxy Detection & Inspector

    func inspectPickedGalleryItems(_ picked: [PickedMediaResult]) {
        guard !picked.isEmpty else { return }
        isInspectingGalleryPicks = true
        inspectorActionMessage = nil

        let apiClient = PhotoHubAPIClient(settings: self.settings)
        let tracker = self.tracker
        let isSignedIn = self.settings.isSignedIn
        let cachedPhotos = LocalProxyStore.shared.cachedPhotos(
            baseURL: settings.normalizedBaseURL,
            apiKey: settings.apiKey
        )

        Task.detached(priority: .userInitiated) { [weak self] in
            let results = await GalleryProxyDetector.inspectPickedItems(
                picked,
                client: apiClient,
                tracker: tracker,
                cachedServerPhotos: cachedPhotos,
                isSignedIn: isSignedIn
            )
            await MainActor.run {
                guard let self else { return }
                self.isInspectingGalleryPicks = false
                self.galleryInspectionItems = results

                // Remove any confirmed proxies / protected restored originals from the active Compress queue
                self.candidates.removeAll { cand in
                    results.contains {
                        ($0.kind == .proxy || $0.isProtectedOriginal) &&
                            ($0.assetId == cand.id || (cand.masterHash != nil && cand.masterHash == $0.masterHash))
                    }
                }
            }
        }
    }

    func dismissGalleryInspection() {
        galleryInspectionItems = nil
        inspectionBusyId = nil
        inspectorActionMessage = nil
    }

    func restoreOriginalFromDetectedProxy(
        itemId: String,
        rawMasterHash: String?,
        originalFilename: String?,
        isVideo: Bool
    ) {
        guard let rawMasterHash, !rawMasterHash.isEmpty else {
            inspectorActionMessage = "Master hash unavailable while offline."
            statusBanner = inspectorActionMessage
            return
        }
        inspectionBusyId = itemId
        inspectorActionMessage = "Restoring full-resolution original..."

        let settings = self.settings
        Task { [weak self] in
            guard let self else { return }
            let authorized = await PhotoLibraryService.requestWriteAuthorizationAsync()
            guard authorized else {
                self.inspectionBusyId = nil
                self.inspectorActionMessage = "Photos permission is required to save originals."
                return
            }

            do {
                let client = PhotoHubAPIClient(settings: settings)
                let serverPhoto = try await self.resolveServerPhotoForHashOrPrefix(
                    rawMasterHash,
                    fallbackFilename: originalFilename,
                    isVideo: isVideo,
                    client: client
                )
                let (_, savedBytes) = try await PhotoLibraryService.restoreMasterToPhotos(
                    photo: serverPhoto,
                    client: client
                )
                let sizeStr = ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file)
                let msg = "Restored \(serverPhoto.originalName) (\(sizeStr)) to Photos & protected it."
                self.inspectionBusyId = nil
                self.inspectorActionMessage = msg
                self.statusBanner = msg
                if var list = self.galleryInspectionItems,
                   let idx = list.firstIndex(where: { $0.id == itemId }) {
                    let old = list[idx]
                    list[idx] = GalleryProxyInspectionItem(
                        id: old.id,
                        assetId: old.assetId,
                        displayName: old.displayName,
                        isVideo: old.isVideo,
                        localSizeBytes: old.localSizeBytes,
                        kind: old.kind,
                        signals: old.signals,
                        masterHash: serverPhoto.hash,
                        proxySha256: old.proxySha256,
                        originalName: serverPhoto.originalName,
                        originalSizeBytes: serverPhoto.size,
                        isProtectedOriginal: true,
                        hasServerProxy: old.hasServerProxy
                    )
                    self.galleryInspectionItems = list
                }
            } catch {
                self.inspectionBusyId = nil
                let msg = "Restore failed: \(error.localizedDescription)"
                self.inspectorActionMessage = msg
                self.statusBanner = msg
            }
        }
    }

    func shareOriginalFromDetectedProxy(
        itemId: String,
        rawMasterHash: String?,
        originalFilename: String?,
        isVideo: Bool = false
    ) {
        guard let rawMasterHash, !rawMasterHash.isEmpty else {
            inspectorActionMessage = "Master hash unavailable while offline."
            statusBanner = inspectorActionMessage
            return
        }
        inspectionBusyId = itemId
        inspectorActionMessage = "Downloading original for Share..."

        let settings = self.settings
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = PhotoHubAPIClient(settings: settings)
                await client.warmConnectionIfNeeded()
                let serverPhoto = try await self.resolveServerPhotoForHashOrPrefix(
                    rawMasterHash,
                    fallbackFilename: originalFilename,
                    isVideo: isVideo,
                    client: client
                )
                let tempURL = try await OriginalDownloadCache.shared.getOrFetchShareCopy(
                    hash: serverPhoto.hash,
                    preferredFilename: serverPhoto.originalName,
                    expectedSizeBytes: serverPhoto.size > 0 ? serverPhoto.size : nil,
                    isVideo: isVideo || serverPhoto.isVideo,
                    client: client
                )
                self.inspectionBusyId = nil
                self.inspectorActionMessage = nil
                self.inspectorShareItem = ShareSheetItem(fileURL: tempURL)
            } catch {
                self.inspectionBusyId = nil
                let msg = "Share failed: \(error.localizedDescription)"
                self.inspectorActionMessage = msg
                self.statusBanner = msg
            }
        }
    }

    private func resolveServerPhotoForHashOrPrefix(
        _ rawHashOrPrefix: String,
        fallbackFilename: String?,
        isVideo: Bool,
        client: PhotoHubAPIClient
    ) async throws -> ServerPhoto {
        let clean = rawHashOrPrefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cached = LocalProxyStore.shared.cachedPhotos(
            baseURL: settings.normalizedBaseURL,
            apiKey: settings.apiKey
        )
        if let found = cached.first(where: {
            $0.hash.lowercased() == clean || ProxyGenerator.proxyPrefixTag(forMasterHash: $0.hash) == clean
        }) {
            return found
        }

        if let fresh = try? await client.fetchAllServerPhotos(sync: false) {
            LocalProxyStore.shared.savePhotos(
                fresh,
                baseURL: settings.normalizedBaseURL,
                apiKey: settings.apiKey
            )
            if let found = fresh.first(where: {
                $0.hash.lowercased() == clean || ProxyGenerator.proxyPrefixTag(forMasterHash: $0.hash) == clean
            }) {
                return found
            }
        }

        guard clean.count == 64 else {
            throw PhotoLibraryError.proxyReplacementFailed("Original photo hash could not be resolved on server.")
        }
        return ServerPhoto(
            hash: clean,
            originalName: fallbackFilename ?? (isVideo ? "RESTORED_\(clean.prefix(8)).mp4" : "RESTORED_\(clean.prefix(8)).jpg"),
            size: 0,
            photoDate: "",
            takenAt: nil,
            uploadedAt: "",
            savedPath: fallbackFilename ?? "",
            hasProxy: true,
            hasPreview: true,
            proxyHash: nil,
            proxySize: nil,
            hasVideoProxy: nil,
            videoProxySize: nil,
            keepOriginalOnDevice: true
        )
    }
}
