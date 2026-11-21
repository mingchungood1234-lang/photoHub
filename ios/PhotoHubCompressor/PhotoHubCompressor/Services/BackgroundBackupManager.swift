import BackgroundTasks
import Foundation
import Photos
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

/// Bridges an active foreground/background upload batch to iOS 26+ `BGContinuedProcessingTask`
/// so uploads & proxy compression continue seamlessly when the user switches apps or locks screen.
final class ContinuedUploadSession: @unchecked Sendable {
    let identifier: String
    let totalCount: Int

    private let lock = NSLock()
    private var rawTask: AnyObject?
    private var isEnded = false
    private var finalSuccess = true
    private var onCancel: (@Sendable () -> Void)?

    init(identifier: String, totalCount: Int, onCancel: @escaping @Sendable () -> Void) {
        self.identifier = identifier
        self.totalCount = max(1, totalCount)
        self.onCancel = onCancel
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    func attach(task: BGContinuedProcessingTask) {
        task.progress.totalUnitCount = Int64(totalCount)
        task.progress.completedUnitCount = 0

        task.expirationHandler = { [weak self] in
            self?.cancelFromSystem()
        }

        lock.lock()
        let alreadyEnded = isEnded
        let endedSuccess = finalSuccess
        if !alreadyEnded {
            rawTask = task
        }
        lock.unlock()

        if alreadyEnded {
            task.setTaskCompleted(success: endedSuccess)
        }
    }
    #endif

    func update(completed: Int, total: Int, currentFilename: String) {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            lock.lock()
            let task = rawTask as? BGContinuedProcessingTask
            let ended = isEnded
            lock.unlock()

            guard !ended, let task else { return }
            let safeTotal = max(1, total)
            let safeCompleted = max(0, min(safeTotal, completed))
            task.progress.totalUnitCount = Int64(safeTotal)
            task.progress.completedUnitCount = Int64(safeCompleted)
            task.updateTitle(
                "photoHub Auto Backup",
                subtitle: "Backed up \(safeCompleted) of \(safeTotal) · \(currentFilename)"
            )
        }
        #endif
    }

    func finish(success: Bool) {
        lock.lock()
        guard !isEnded else {
            lock.unlock()
            return
        }
        isEnded = true
        finalSuccess = success
        onCancel = nil
        let taskObj = rawTask
        rawTask = nil
        lock.unlock()

        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            (taskObj as? BGContinuedProcessingTask)?.setTaskCompleted(success: success)
        }
        #endif
    }

    private func cancelFromSystem() {
        lock.lock()
        guard !isEnded else {
            lock.unlock()
            return
        }
        isEnded = true
        finalSuccess = false
        let cancelCallback = onCancel
        onCancel = nil
        let taskObj = rawTask
        rawTask = nil
        lock.unlock()

        cancelCallback?()

        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            (taskObj as? BGContinuedProcessingTask)?.setTaskCompleted(success: false)
        }
        #endif
    }
}

@MainActor
final class BackgroundBackupManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = BackgroundBackupManager()
    static let taskIdentifier = "com.photohub.compressor.nightlyBackup"
    static let refreshTaskIdentifier = "com.photohub.compressor.autoUploadRefresh"
    static let continuedTaskPrefix = "com.photohub.compressor.continued."
    static let morningNotificationIdentifier = "com.photohub.compressor.morningFreeUp"
    static let immediateNotificationIdentifier = "com.photohub.compressor.uploadFinishedDeleteOriginals"

    private let stagedStorageKey = "photohub.stagedOvernightCleanup.v1"
    private let lastRunSummaryKey = "photohub.lastOvernightSummary.v1"

    @Published private(set) var stagedItems: [StagedCleanupItem] = []
    @Published private(set) var lastRunSummary: String = ""
    @Published private(set) var notificationPermissionLabel: String = "Not Requested"
    @Published var pendingOpenCleanupFromNotification: Bool = false

    private var hasRegistered = false
    private weak var settingsRef: AppSettings?

    private override init() {
        super.init()
        loadPersistedState()
    }

    var stagedSavedBytes: Int64 {
        stagedItems.reduce(0) { $0 + max(0, $1.savedBytes) }
    }

    func register(settings: AppSettings) {
        self.settingsRef = settings
        UNUserNotificationCenter.current().delegate = self
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

    // MARK: - iOS 26+ Continued Background Upload Session

    /// Starts an iOS 26 `BGContinuedProcessingTask` for a user-initiated/auto-started upload batch so iOS keeps
    /// compressing & uploading in the background with Live Activity progress when switching apps or locking the screen.
    func beginContinuedUploadSession(
        totalCount: Int,
        onCancel: @escaping @Sendable () -> Void
    ) -> ContinuedUploadSession? {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let jobId = "\(Self.continuedTaskPrefix)\(UUID().uuidString)"
            let session = ContinuedUploadSession(
                identifier: jobId,
                totalCount: totalCount,
                onCancel: onCancel
            )

            _ = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: jobId,
                using: nil
            ) { task in
                guard let continuedTask = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                session.attach(task: continuedTask)
            }

            let request = BGContinuedProcessingTaskRequest(
                identifier: jobId,
                title: "photoHub Auto Backup",
                subtitle: "Uploading & compressing \(totalCount) photo(s)…"
            )
            request.strategy = .queue

            do {
                try BGTaskScheduler.shared.submit(request)
                return session
            } catch {
                session.finish(success: false)
                return nil
            }
        }
        #endif
        return nil
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
        guard settings.nightlyAutoBackupEnabled, settings.isSignedIn else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskIdentifier)
            return
        }

        let processingReq = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        processingReq.requiresNetworkConnectivity = true
        processingReq.requiresExternalPower = settings.nightlyRequiresCharging
        processingReq.earliestBeginDate = Self.nextNightlyBeginDate()

        let refreshReq = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        refreshReq.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)

        do {
            try BGTaskScheduler.shared.submit(processingReq)
            try? BGTaskScheduler.shared.submit(refreshReq)
            if lastRunSummary.isEmpty {
                updateSummary("Auto background upload active (iOS 26+ continued + Wi-Fi scheduler).")
            }
        } catch {
            updateSummary("Background schedule note: \(error.localizedDescription)")
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
                    content.title = "Upload & Compression Done — Delete \(count) Original\(count == 1 ? "" : "s")"
                    content.body = "\(count) original\(count == 1 ? " is" : "s are") backed up & SHA-256 verified on your server. Tap to delete the original photos from your iPhone (free ~\(sizeStr))."
                } else {
                    content.title = "Upload & Compression Done — Delete Original Photos"
                    content.body = "Your originals are backed up & SHA-256 verified on your server. Tap to confirm deleting the original photos from your iPhone."
                }
                content.sound = .default

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
                let req = UNNotificationRequest(
                    identifier: Self.morningNotificationIdentifier + ".test",
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
            if immediate {
                content.title = "Upload & Compression Done — Delete \(count) Original\(count == 1 ? "" : "s")"
                content.body = "\(count) original photo\(count == 1 ? " is" : "s are") backed up & SHA-256 verified on your server. Tap here to delete the original photos from your iPhone and free ~\(sizeStr)."
            } else {
                content.title = "Backed Up Overnight — Delete \(count) Original\(count == 1 ? "" : "s") (Free \(sizeStr))"
                content.body = "\(count) original\(count == 1 ? " is" : "s are") safely stored & SHA-256 verified on your server. Tap to delete the original photos from your iPhone."
            }
            content.sound = .default

            let now = Date()
            let cal = Calendar.current
            let currentHour = cal.component(.hour, from: now)
            let targetHour = min(22, max(6, morningHour))

            let trigger: UNNotificationTrigger
            let requestId: String
            if immediate || (currentHour >= targetHour && currentHour < 22) {
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                requestId = Self.immediateNotificationIdentifier
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
                Self.immediateNotificationIdentifier,
            ])
        }
    }

    func clearAllStagedItems() {
        stagedItems = []
        saveStagedItems()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
            Self.morningNotificationIdentifier,
            Self.immediateNotificationIdentifier,
        ])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [
            Self.morningNotificationIdentifier,
            Self.immediateNotificationIdentifier,
        ])
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

        // Re-enqueue the next automatic run per Apple best practices
        scheduleNightlyBackupIfEnabled(settings: settings)

        guard settings.nightlyAutoBackupEnabled,
              settings.isSignedIn,
              let baseURL = settings.normalizedBaseURL else {
            task.setTaskCompleted(success: true)
            return
        }

        let authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authStatus == .authorized || authStatus == .limited else {
            updateSummary("Skipped background upload: Full Photos permission needed.")
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

        let work = Task.detached(priority: .utility) { [weak self] in
            var processedNew = 0
            do {
                _ = try await apiClient.whoami()
            } catch {
                await MainActor.run {
                    self?.updateSummary("Background backup skipped: server unreachable.")
                }
                task.setTaskCompleted(success: false)
                return
            }

            let photoService = PhotoLibraryService()
            let tracker = LocalProxyTracker.shared
            let cachedServerPhotos = LocalProxyStore.shared.cachedPhotos(baseURL: baseURL, apiKey: cacheScope)
            let rawCandidates = photoService.scanCandidates(tracker: tracker, knownServerPhotos: cachedServerPhotos)
            let prioritized = PhotoBackupPipeline
                .sortCandidates(rawCandidates, by: .largestVideosFirst)
                .filter { !existingStagedIds.contains($0.id) }
                .prefix(maxItems)

            let videoSemaphore = AsyncSemaphore(value: 1)
            let photosSaveSemaphore = AsyncSemaphore(value: 1)

            for candidate in prioritized {
                if Task.isCancelled { break }
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
                        normalizedBaseURL: baseURL,
                        cacheScopeKey: cacheScope,
                        videoSemaphore: videoSemaphore,
                        photosSaveSemaphore: photosSaveSemaphore,
                        onStageChange: { _ in }
                    )

                    switch result {
                    case .backedUp(let outcome):
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
                    case .skippedExistingProxy, .skippedProtectedOriginal:
                        break
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
                    self.updateSummary("Uploaded & verified \(processedNew) new item(s); \(totalCount) original(s) ready to delete (free ~\(totalStr)).")
                    if processedNew > 0 || isOvernight {
                        self.sendDeleteOriginalsNotification(
                            count: totalCount,
                            savedBytes: totalBytes,
                            immediate: notifyImmediate && !isOvernight,
                            morningHour: morningHour
                        )
                    }
                } else {
                    self.updateSummary("Background check complete: all photos are already backed up.")
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

    private static func nextNightlyBeginDate() -> Date {
        let now = Date()
        let cal = Calendar.current
        // Aim for 01:00 AM local time so large overnight uploads trigger while charging
        if let nextNight = cal.nextDate(
            after: now,
            matching: DateComponents(hour: 1, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) {
            return nextNight
        }
        return now.addingTimeInterval(4 * 3600)
    }
}
