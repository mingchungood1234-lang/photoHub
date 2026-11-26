import BackgroundTasks
import Foundation
import Network
import Photos
import UIKit
import UserNotifications

extension Notification.Name {
    static let photoHubOpenCleanupPrompt = Notification.Name("photoHub.openCleanupPrompt")
}

struct StagedCleanupItem: Codable, Identifiable, Equatable, Sendable {
    let id: String // PHAsset.localIdentifier of verified original ready for 1-tap deletion
    let filename: String
    let masterSha256: String
    let savedBytes: Int64
    let verifiedAt: Date
}

@MainActor
final class BackgroundBackupManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate, PHPhotoLibraryChangeObserver {
    static let shared = BackgroundBackupManager()
    static let taskIdentifier = "com.photohub.compressor.nightlyBackup"
    static let refreshTaskIdentifier = "com.photohub.compressor.autoUploadRefresh"
    static let morningNotificationIdentifier = "com.photohub.compressor.morningFreeUp"
    static let deleteReadyNotificationIdentifier = "com.photohub.compressor.uploadFinishedDeleteOriginals"

    private let stagedStorageKey = "photohub.stagedOvernightCleanup.v1"
    private let lastRunSummaryKey = "photohub.lastOvernightSummary.v1"

    @Published private(set) var stagedItems: [StagedCleanupItem] = []
    @Published private(set) var lastRunSummary: String = ""
    @Published private(set) var notificationPermissionLabel: String = "Off"
    @Published var pendingOpenCleanupFromNotification: Bool = false
    @Published private(set) var activeBackgroundUploadCount: Int = 0
    @Published private(set) var liveBackgroundProgress: Double = 0

    private var hasRegistered = false
    private var hasRegisteredPhotoObserver = false
    private var isSilentUploadRunning = false
    private var pendingRescanAfterSilentRun = false
    private var activeRestorePauseCount: Int = 0
    private var recentFailureCooldownUntil: [String: Date] = [:]
    private var debouncedSilentTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var lastNetworkSatisfied: Bool = true
    private weak var settingsRef: AppSettings?

    var isPausedForRestore: Bool {
        activeRestorePauseCount > 0
    }

    func beginRestorePause() {
        activeRestorePauseCount += 1
        debouncedSilentTask?.cancel()
        debouncedSilentTask = nil
        pendingRescanAfterSilentRun = false
    }

    func endRestorePause() {
        activeRestorePauseCount = max(0, activeRestorePauseCount - 1)
    }

    /// Turns off Auto Backup and cancels scheduled background upload tasks (used by Restore All Originals).
    @discardableResult
    func disableAutoBackup(settings: AppSettings) -> Bool {
        guard settings.nightlyAutoBackupEnabled else { return false }
        settings.nightlyAutoBackupEnabled = false
        debouncedSilentTask?.cancel()
        debouncedSilentTask = nil
        pendingRescanAfterSilentRun = false
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskIdentifier)
        updateSummary("Auto backup off")
        return true
    }

    private override init() {
        super.init()
        loadPersistedState()
        setupNotificationObservers()
        startNetworkRecoveryMonitor()
    }

    func updateLiveBackgroundTransport(activeCount: Int, progress: Double) {
        activeBackgroundUploadCount = max(activeCount, AssetUploadCoordinator.shared.backgroundActiveAssetIds().count)
        liveBackgroundProgress = activeCount > 0 ? progress : 0
    }

    private func startNetworkRecoveryMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isOnline = (path.status == .satisfied)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let recovered = isOnline && !self.lastNetworkSatisfied
                self.lastNetworkSatisfied = isOnline
                if recovered {
                    self.recentFailureCooldownUntil.removeAll()
                    self.scheduleDebouncedSilentCheck(delayNanoseconds: 2_000_000_000)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "photohub.bg.netmonitor", qos: .utility))
        pathMonitor = monitor
    }

    private func setupNotificationObservers() {
        _ = NotificationCenter.default.addObserver(
            forName: .photoHubServerSyncCompleted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDebouncedSilentCheck(delayNanoseconds: 1_500_000_000)
            }
        }
        _ = NotificationCenter.default.addObserver(
            forName: .photoHubCheckRemainingSilentUploads,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDebouncedSilentCheck(delayNanoseconds: 1_500_000_000)
            }
        }
    }

    var stagedSavedBytes: Int64 {
        stagedItems.reduce(0) { $0 + max(0, $1.savedBytes) }
    }

    func register(settings: AppSettings) {
        self.settingsRef = settings
        UNUserNotificationCenter.current().delegate = self
        _ = BackgroundUploadTransport.shared
        ensurePhotoObserverIfAuthorized()

        guard !hasRegistered else { return }
        hasRegistered = true

        _ = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                self?.handleBackgroundProcessingTask(processingTask)
            }
        }

        _ = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                self?.handleBackgroundRefreshTask(refreshTask)
            }
        }
    }

    func ensurePhotoObserverIfAuthorized() {
        guard !hasRegisteredPhotoObserver else { return }
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard auth == .authorized || auth == .limited else { return }
        hasRegisteredPhotoObserver = true
        PHPhotoLibrary.shared().register(self)
    }

    // MARK: - PHPhotoLibraryChangeObserver (Google Photos-style silent detection of new photos)

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            guard let self, !self.isPausedForRestore else { return }
            self.scheduleDebouncedSilentCheck(delayNanoseconds: 2_500_000_000)
        }
    }

    private func scheduleDebouncedSilentCheck(delayNanoseconds: UInt64) {
        guard !isPausedForRestore,
              let settings = settingsRef,
              settings.nightlyAutoBackupEnabled,
              settings.isSignedIn else {
            return
        }
        debouncedSilentTask?.cancel()
        debouncedSilentTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  let currentSettings = self.settingsRef else {
                return
            }
            self.triggerSilentAutoUpload(settings: currentSettings, isMovingToBackground: false)
        }
    }

    // MARK: - Notifications

    func refreshNotificationPermissionLabel() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let label: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                label = "Allowed"
            case .denied:
                label = "Denied (Enable in iOS Settings)"
            case .notDetermined:
                label = "Not Requested"
            @unknown default:
                label = "Unknown"
            }
            DispatchQueue.main.async {
                self?.notificationPermissionLabel = label
            }
        }
    }

    func requestNotificationPermissionAndSchedule(settings: AppSettings) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.notificationPermissionLabel = granted ? "Allowed" : "Denied (Enable in iOS Settings)"
                if settings.nightlyAutoBackupEnabled {
                    self?.scheduleNightlyBackupIfEnabled(settings: settings)
                }
            }
        }
    }

    func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] notifSettings in
            guard notifSettings.authorizationStatus == .notDetermined else {
                DispatchQueue.main.async {
                    self?.refreshNotificationPermissionLabel()
                }
                return
            }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.notificationPermissionLabel = granted ? "Allowed" : "Denied (Enable in iOS Settings)"
                }
            }
        }
    }

    func scheduleNightlyBackupIfEnabled(settings: AppSettings) {
        ensurePhotoObserverIfAuthorized()
        guard settings.nightlyAutoBackupEnabled, settings.isSignedIn else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskIdentifier)
            return
        }

        let processingReq = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        processingReq.requiresNetworkConnectivity = true
        processingReq.requiresExternalPower = settings.nightlyRequiresCharging
        processingReq.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        let refreshReq = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        refreshReq.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60)

        do {
            try BGTaskScheduler.shared.submit(processingReq)
            try? BGTaskScheduler.shared.submit(refreshReq)
            if lastRunSummary.isEmpty {
                updateSummary("Auto backup active")
            }
        } catch {
            updateSummary("Schedule: \(error.localizedDescription)")
        }
    }

    func sendTestMorningAlert(settings: AppSettings) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.notificationPermissionLabel = granted ? "Allowed" : "Denied (Enable in iOS Settings)"
                guard granted else { return }

                let content = UNMutableNotificationContent()
                let count = self?.stagedItems.count ?? 0
                if count > 0, let bytes = self?.stagedSavedBytes {
                    let sizeStr = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    content.title = "Delete \(count) Backed-Up Original Photo\(count == 1 ? "" : "s")?"
                    content.body = "photoHub uploaded & verified \(count) item\(count == 1 ? "" : "s") silently in the background. Tap to delete the original photos from your iPhone (free ~\(sizeStr))."
                } else {
                    content.title = "Delete Backed-Up Original Photos?"
                    content.body = "Your originals are backed up & SHA-256 verified on your server. Tap to confirm deleting the original photos from your iPhone."
                }
                content.sound = .default

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
                let req = UNNotificationRequest(
                    identifier: Self.deleteReadyNotificationIdentifier + ".test",
                    content: content,
                    trigger: trigger
                )
                UNUserNotificationCenter.current().add(req)
            }
        }
    }

    func sendDeleteOriginalsNotification(
        count: Int,
        savedBytes: Int64,
        immediate: Bool,
        morningHour: Int
    ) {
        guard count > 0 else { return }
        UNUserNotificationCenter.current().getNotificationSettings { notifSettings in
            guard notifSettings.authorizationStatus == .authorized ||
                  notifSettings.authorizationStatus == .provisional else {
                return
            }

            let sizeStr = ByteCountFormatter.string(fromByteCount: max(0, savedBytes), countStyle: .file)
            let content = UNMutableNotificationContent()
            content.title = "Delete \(count) Original Photo\(count == 1 ? "" : "s") to Free ~\(sizeStr)"
            content.body = "\(count) original\(count == 1 ? " is" : "s are") uploaded & SHA-256 verified on your server. Tap to delete the original files from your iPhone."
            content.sound = .default

            let now = Date()
            let cal = Calendar.current
            let currentHour = cal.component(.hour, from: now)
            let targetHour = min(22, max(6, morningHour))

            let trigger: UNNotificationTrigger
            let requestId: String
            if immediate || (currentHour >= targetHour && currentHour < 23) {
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                requestId = Self.deleteReadyNotificationIdentifier
            } else {
                var target = cal.nextDate(
                    after: now,
                    matching: DateComponents(hour: targetHour, minute: 0, second: 0),
                    matchingPolicy: .nextTime
                ) ?? now.addingTimeInterval(3600)
                if target <= now {
                    target = now.addingTimeInterval(3600)
                }
                let fireComps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: target)
                trigger = UNCalendarNotificationTrigger(dateMatching: fireComps, repeats: false)
                requestId = Self.morningNotificationIdentifier
            }

            let req = UNNotificationRequest(
                identifier: requestId,
                content: content,
                trigger: trigger
            )
            UNUserNotificationCenter.current().add(req)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            BackgroundBackupManager.shared.pendingOpenCleanupFromNotification = true
            NotificationCenter.default.post(name: .photoHubOpenCleanupPrompt, object: nil)
        }
        completionHandler()
    }

    // MARK: - Staged Cleanup Persistence

    func appendStagedItems(_ newItems: [StagedCleanupItem]) {
        guard !newItems.isEmpty else { return }
        var changed = false
        for item in newItems where !stagedItems.contains(where: { $0.id == item.id }) {
            stagedItems.append(item)
            changed = true
        }
        if changed {
            saveStagedItems()
        }
    }

    func pruneMissingAssetsFromStaged() {
        guard !stagedItems.isEmpty else { return }
        let ids = stagedItems.map { $0.id }
        let liveIds = Set(PhotoLibraryService.fetchLiveAssets(forLocalIdentifiers: ids).map { $0.localIdentifier })
        let filtered = stagedItems.filter { liveIds.contains($0.id) }
        if filtered.count != stagedItems.count {
            stagedItems = filtered
            saveStagedItems()
        }
    }

    func removeStagedItems(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let filtered = stagedItems.filter { !ids.contains($0.id) }
        if filtered.count != stagedItems.count {
            stagedItems = filtered
            saveStagedItems()
        }
        if stagedItems.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [
                Self.morningNotificationIdentifier,
                Self.deleteReadyNotificationIdentifier,
            ])
        }
    }

    func clearAllStagedItems() {
        stagedItems = []
        saveStagedItems()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
            Self.morningNotificationIdentifier,
            Self.deleteReadyNotificationIdentifier,
        ])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [
            Self.morningNotificationIdentifier,
            Self.deleteReadyNotificationIdentifier,
        ])
    }

    // MARK: - Silent Auto Background Upload (Google Photos-style, Zero Screen Notices Until Ready to Delete)

    func triggerSilentAutoUpload(settings: AppSettings, isMovingToBackground: Bool) {
        ensurePhotoObserverIfAuthorized()
        guard !isPausedForRestore,
              settings.nightlyAutoBackupEnabled,
              settings.isSignedIn,
              let baseURL = settings.normalizedBaseURL,
              let uploadConfig = BackgroundUploadConfig(settings: settings) else {
            return
        }

        if isSilentUploadRunning {
            pendingRescanAfterSilentRun = true
            return
        }

        let authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authStatus == .authorized || authStatus == .limited else {
            return
        }

        if settings.notifyWhenBackgroundUploadFinishes {
            requestNotificationPermissionIfNeeded()
        }

        isSilentUploadRunning = true

        let apiClient = PhotoHubAPIClient(settings: settings)
        let format = settings.proxyFormat
        let maxPx = settings.proxyMaxPixelSize
        let quality = settings.proxyQuality
        let uploadMode = settings.uploadMode
        let keepLocal = settings.keepLocalProxyInPhotos
        let cacheScope = settings.apiKey
        let morningHour = settings.morningReminderHour
        let notifyOnFinish = settings.notifyWhenBackgroundUploadFinishes
        let existingStagedIds = Set(stagedItems.map { $0.id })
        let now = Date()
        recentFailureCooldownUntil = recentFailureCooldownUntil.filter { $0.value > now }
        let cooldownIds = Set(recentFailureCooldownUntil.keys)

        let taskHolder = SilentTaskBox()
        let bgId = UIApplication.shared.beginBackgroundTask(withName: "PhotoHubSilentAutoBackup") {
            taskHolder.cancelAndEndBackgroundTask()
        }
        taskHolder.setBackgroundTaskId(bgId)

        let work = Task.detached(priority: .utility) { [weak self] in
            var hasMoreEligible = false
            var failedIds: [String] = []
            defer {
                taskHolder.endBackgroundTask()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let retryAt = Date().addingTimeInterval(180)
                    for id in failedIds {
                        self.recentFailureCooldownUntil[id] = retryAt
                    }
                    self.isSilentUploadRunning = false
                    let shouldFollowUp = self.pendingRescanAfterSilentRun || (hasMoreEligible && !isMovingToBackground)
                    self.pendingRescanAfterSilentRun = false
                    if shouldFollowUp {
                        self.scheduleDebouncedSilentCheck(delayNanoseconds: 1_000_000_000)
                    }
                }
            }

            guard let whoami = try? await apiClient.whoami() else { return }
            let effectiveUploadMode: UploadMode = (whoami.s3Enabled == true) ? .s3Presigned : .directVPS
            await MainActor.run {
                self?.settingsRef?.applyServerCapabilities(storage: whoami.storage, s3Enabled: whoami.s3Enabled)
            }

            let photoService = PhotoLibraryService()
            let tracker = LocalProxyTracker.shared
            let cachedServerPhotos = LocalProxyStore.shared.cachedPhotos(baseURL: baseURL, apiKey: cacheScope)
            let rawCandidates = photoService.scanCandidates(
                tracker: tracker,
                knownServerPhotos: cachedServerPhotos,
                maxResults: 30,
                maxInspect: 400
            )
            let activeIds = AssetUploadCoordinator.shared.activeAssetIds()
            let eligible = PhotoBackupPipeline
                .sortCandidates(rawCandidates, by: .largestVideosFirst)
                .filter {
                    !existingStagedIds.contains($0.id) &&
                    !activeIds.contains($0.id) &&
                    !cooldownIds.contains($0.id)
                }
            let batchLimit = isMovingToBackground ? 6 : 12
            hasMoreEligible = eligible.count > batchLimit
            let prioritized = eligible.prefix(batchLimit)

            let videoSemaphore = AsyncSemaphore(value: 1)
            let photosSaveSemaphore = AsyncSemaphore(value: 1)
            var uploadedNewCount = 0

            for candidate in prioritized {
                if Task.isCancelled { break }
                guard AssetUploadCoordinator.shared.tryClaimAsset(candidate.id, owner: .background) else {
                    continue
                }

                // Hand off large direct-VPS uploads (or when app just backgrounded) straight to URLSession.background
                // so the OS daemon uploads silently with zero app time limit & zero screen banners.
                let useOSBackgroundSession = (effectiveUploadMode == .directVPS)
                    && (isMovingToBackground || candidate.isVideo || candidate.estimatedBytes > 8_000_000)
                if useOSBackgroundSession {
                    let outcome = await BackgroundUploadTransport.shared.enqueueSilentUpload(
                        candidate: candidate,
                        photoService: photoService,
                        apiClient: apiClient,
                        config: uploadConfig
                    )
                    switch outcome {
                    case .queuedBackgroundUpload:
                        break
                    case .finalizedLocally:
                        AssetUploadCoordinator.shared.releaseAsset(candidate.id, owner: .background)
                        uploadedNewCount += 1
                    case .skippedAlreadyHandled:
                        AssetUploadCoordinator.shared.releaseAsset(candidate.id, owner: .background)
                    case .failed:
                        AssetUploadCoordinator.shared.releaseAsset(candidate.id, owner: .background)
                        failedIds.append(candidate.id)
                    }
                    continue
                }

                defer { AssetUploadCoordinator.shared.releaseAsset(candidate.id, owner: .background) }

                do {
                    let result = try await PhotoBackupPipeline.backupAndProxyAsset(
                        candidate: candidate,
                        photoService: photoService,
                        apiClient: apiClient,
                        tracker: tracker,
                        format: format,
                        maxPixelSize: maxPx,
                        quality: quality,
                        uploadMode: effectiveUploadMode,
                        keepLocalProxy: keepLocal,
                        normalizedBaseURL: baseURL,
                        cacheScopeKey: cacheScope,
                        videoSemaphore: videoSemaphore,
                        photosSaveSemaphore: photosSaveSemaphore,
                        onStageChange: { _ in }
                    )

                    if case .backedUp(let outcome) = result {
                        let entry = StagedCleanupItem(
                            id: candidate.id,
                            filename: outcome.filename,
                            masterSha256: outcome.masterSha256,
                            savedBytes: outcome.savedBytes,
                            verifiedAt: Date()
                        )
                        await MainActor.run {
                            self?.appendStagedItem(entry)
                        }
                        uploadedNewCount += 1
                    }
                } catch APIClientError.httpError(507, _) {
                    break
                } catch {
                    failedIds.append(candidate.id)
                    continue
                }
            }

            if uploadedNewCount > 0 {
                await MainActor.run {
                    guard let self else { return }
                    self.pruneMissingAssetsFromStaged()
                    let totalCount = self.stagedItems.count
                    let totalBytes = self.stagedSavedBytes
                    let totalStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                    self.updateSummary("Backed up \(uploadedNewCount) · \(totalCount) ready (~\(totalStr))")
                    if notifyOnFinish && totalCount > 0 {
                        self.sendDeleteOriginalsNotification(
                            count: totalCount,
                            savedBytes: totalBytes,
                            immediate: true,
                            morningHour: morningHour
                        )
                    }
                }
            }
        }

        taskHolder.set(work)
    }

    // MARK: - Scheduled Background Tasks (BGProcessingTask + BGAppRefreshTask)

    private func handleBackgroundProcessingTask(_ task: BGProcessingTask) {
        runScheduledTask(task: task, maxItems: 40, isOvernight: true)
    }

    private func handleBackgroundRefreshTask(_ task: BGAppRefreshTask) {
        runScheduledTask(task: task, maxItems: 6, isOvernight: false)
    }

    private func runScheduledTask(task: BGTask, maxItems: Int, isOvernight: Bool) {
        guard let settings = settingsRef else {
            task.setTaskCompleted(success: false)
            return
        }

        scheduleNightlyBackupIfEnabled(settings: settings)

        guard !isPausedForRestore,
              settings.nightlyAutoBackupEnabled,
              settings.isSignedIn,
              let baseURL = settings.normalizedBaseURL else {
            task.setTaskCompleted(success: true)
            return
        }

        let authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authStatus == .authorized || authStatus == .limited else {
            task.setTaskCompleted(success: false)
            return
        }

        let apiClient = PhotoHubAPIClient(settings: settings)
        let format = settings.proxyFormat
        let maxPx = settings.proxyMaxPixelSize
        let quality = settings.proxyQuality
        let uploadMode = settings.uploadMode
        let keepLocal = settings.keepLocalProxyInPhotos
        let cacheScope = settings.apiKey
        let morningHour = settings.morningReminderHour
        let notifyImmediate = settings.notifyWhenBackgroundUploadFinishes
        let existingStagedIds = Set(stagedItems.map { $0.id })
        let activeBgIds = BackgroundUploadTransport.shared.activeAssetIds()
        let uploadConfig = BackgroundUploadConfig(settings: settings)

        let work = Task.detached(priority: .utility) { [weak self] in
            var processedNew = 0
            var effectiveUploadMode: UploadMode = uploadMode
            do {
                let whoami = try await apiClient.whoami()
                effectiveUploadMode = (whoami.s3Enabled == true) ? .s3Presigned : .directVPS
                await MainActor.run {
                    self?.settingsRef?.applyServerCapabilities(storage: whoami.storage, s3Enabled: whoami.s3Enabled)
                }
            } catch {
                task.setTaskCompleted(success: false)
                return
            }

            let photoService = PhotoLibraryService()
            let tracker = LocalProxyTracker.shared
            let cachedServerPhotos = LocalProxyStore.shared.cachedPhotos(baseURL: baseURL, apiKey: cacheScope)
            let scanCap = isOvernight ? 250 : 40
            let inspectCap = isOvernight ? 2500 : 300
            let rawCandidates = photoService.scanCandidates(
                tracker: tracker,
                knownServerPhotos: cachedServerPhotos,
                maxResults: scanCap,
                maxInspect: inspectCap
            )
            let activeIds = AssetUploadCoordinator.shared.activeAssetIds()
            let prioritized = PhotoBackupPipeline
                .sortCandidates(rawCandidates, by: .largestVideosFirst)
                .filter { !existingStagedIds.contains($0.id) && !activeIds.contains($0.id) }
                .prefix(maxItems)

            let videoSemaphore = AsyncSemaphore(value: 1)
            let photosSaveSemaphore = AsyncSemaphore(value: 1)

            for candidate in prioritized {
                if Task.isCancelled { break }
                guard AssetUploadCoordinator.shared.tryClaimAsset(candidate.id, owner: .background) else {
                    continue
                }

                if effectiveUploadMode == .directVPS,
                   (candidate.isVideo || candidate.estimatedBytes > 8_000_000),
                   let uploadConfig {
                    let outcome = await BackgroundUploadTransport.shared.enqueueSilentUpload(
                        candidate: candidate,
                        photoService: photoService,
                        apiClient: apiClient,
                        config: uploadConfig
                    )
                    switch outcome {
                    case .queuedBackgroundUpload:
                        break
                    case .finalizedLocally:
                        AssetUploadCoordinator.shared.releaseAsset(candidate.id, owner: .background)
                        processedNew += 1
                    case .skippedAlreadyHandled, .failed:
                        AssetUploadCoordinator.shared.releaseAsset(candidate.id, owner: .background)
                    }
                    continue
                }

                defer { AssetUploadCoordinator.shared.releaseAsset(candidate.id, owner: .background) }

                do {
                    let result = try await PhotoBackupPipeline.backupAndProxyAsset(
                        candidate: candidate,
                        photoService: photoService,
                        apiClient: apiClient,
                        tracker: tracker,
                        format: format,
                        maxPixelSize: maxPx,
                        quality: quality,
                        uploadMode: effectiveUploadMode,
                        keepLocalProxy: keepLocal,
                        normalizedBaseURL: baseURL,
                        cacheScopeKey: cacheScope,
                        videoSemaphore: videoSemaphore,
                        photosSaveSemaphore: photosSaveSemaphore,
                        onStageChange: { _ in }
                    )

                    if case .backedUp(let outcome) = result {
                        let entry = StagedCleanupItem(
                            id: candidate.id,
                            filename: outcome.filename,
                            masterSha256: outcome.masterSha256,
                            savedBytes: outcome.savedBytes,
                            verifiedAt: Date()
                        )
                        await MainActor.run {
                            self?.appendStagedItem(entry)
                        }
                        processedNew += 1
                    }
                } catch APIClientError.httpError(507, _) {
                    await MainActor.run {
                        self?.updateSummary("Background backup stopped: server storage limit reached.")
                    }
                    break
                } catch {
                    continue
                }
            }

            if !Task.isCancelled {
                LocalProxySyncManager.shared.syncFromServerOnLaunch(settings: settings)
            }

            await MainActor.run {
                guard let self else { return }
                self.pruneMissingAssetsFromStaged()
                let totalCount = self.stagedItems.count
                let totalBytes = self.stagedSavedBytes
                let totalStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)

                if totalCount > 0 {
                    self.updateSummary("\(totalCount) ready to delete (~\(totalStr))")
                    if (processedNew > 0 || isOvernight) && notifyImmediate {
                        self.sendDeleteOriginalsNotification(
                            count: totalCount,
                            savedBytes: totalBytes,
                            immediate: !isOvernight,
                            morningHour: morningHour
                        )
                    }
                } else {
                    self.updateSummary("All synced")
                }
            }

            task.setTaskCompleted(success: !Task.isCancelled)
        }

        task.expirationHandler = {
            work.cancel()
        }
    }

    private func appendStagedItem(_ item: StagedCleanupItem) {
        if !stagedItems.contains(where: { $0.id == item.id }) {
            stagedItems.append(item)
            saveStagedItems()
        }
    }

    private func updateSummary(_ message: String) {
        lastRunSummary = message
        UserDefaults.standard.set(message, forKey: lastRunSummaryKey)
    }

    private func loadPersistedState() {
        lastRunSummary = UserDefaults.standard.string(forKey: lastRunSummaryKey) ?? ""
        if let data = UserDefaults.standard.data(forKey: stagedStorageKey),
           let decoded = try? JSONDecoder().decode([StagedCleanupItem].self, from: data) {
            stagedItems = decoded
        }
    }

    private func saveStagedItems() {
        if let data = try? JSONEncoder().encode(stagedItems) {
            UserDefaults.standard.set(data, forKey: stagedStorageKey)
        }
    }
}

private final class SilentTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid
    private var cancelled = false

    func set(_ t: Task<Void, Never>) {
        lock.lock()
        let alreadyCancelled = cancelled
        task = t
        lock.unlock()
        if alreadyCancelled {
            t.cancel()
        }
    }

    func setBackgroundTaskId(_ id: UIBackgroundTaskIdentifier) {
        lock.lock()
        let alreadyCancelled = cancelled
        bgTaskId = id
        lock.unlock()
        if alreadyCancelled {
            endBackgroundTask()
        }
    }

    func endBackgroundTask() {
        lock.lock()
        let id = bgTaskId
        bgTaskId = .invalid
        lock.unlock()
        if id != .invalid {
            Task { @MainActor in
                UIApplication.shared.endBackgroundTask(id)
            }
        }
    }

    func cancelAndEndBackgroundTask() {
        lock.lock()
        cancelled = true
        let current = task
        let id = bgTaskId
        bgTaskId = .invalid
        lock.unlock()
        current?.cancel()
        if id != .invalid {
            Task { @MainActor in
                UIApplication.shared.endBackgroundTask(id)
            }
        }
    }
}
