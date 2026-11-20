import BackgroundTasks
import Foundation
import Photos
import UserNotifications

struct StagedCleanupItem: Codable, Identifiable, Equatable, Sendable {
    let id: String // PHAsset.localIdentifier of verified original ready for 1-tap deletion
    let filename: String
    let masterSha256: String
    let savedBytes: Int64
    let verifiedAt: Date
}

@MainActor
final class BackgroundBackupManager: ObservableObject {
    static let shared = BackgroundBackupManager()
    static let taskIdentifier = "com.photohub.compressor.nightlyBackup"
    static let morningNotificationIdentifier = "com.photohub.compressor.morningFreeUp"

    private let stagedStorageKey = "photohub.stagedOvernightCleanup.v1"
    private let lastRunSummaryKey = "photohub.lastOvernightSummary.v1"

    @Published private(set) var stagedItems: [StagedCleanupItem] = []
    @Published private(set) var lastRunSummary: String = ""
    @Published private(set) var notificationPermissionLabel: String = "Not Requested"

    private var hasRegistered = false
    private weak var settingsRef: AppSettings?

    private init() {
        loadPersistedState()
    }

    var stagedSavedBytes: Int64 {
        stagedItems.reduce(0) { $0 + max(0, $1.savedBytes) }
    }

    func register(settings: AppSettings) {
        self.settingsRef = settings
        guard !hasRegistered else { return }
        hasRegistered = true

        BGTaskScheduler.shared.register(
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
    }

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

    func scheduleNightlyBackupIfEnabled(settings: AppSettings) {
        guard settings.nightlyAutoBackupEnabled, settings.isSignedIn else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            return
        }

        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = settings.nightlyRequiresCharging
        request.earliestBeginDate = Self.nextNightlyBeginDate()

        do {
            try BGTaskScheduler.shared.submit(request)
            if lastRunSummary.isEmpty {
                updateSummary("Scheduled for overnight Wi-Fi backup.")
            }
        } catch {
            updateSummary("Schedule note: \(error.localizedDescription)")
        }
    }

    func sendTestMorningAlert(settings: AppSettings) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.notificationPermissionLabel = granted ? "Allowed" : "Denied (Enable in iOS Settings)"
                guard granted else { return }

                let content = UNMutableNotificationContent()
                content.title = "Ready to Free iPhone Space"
                let count = self?.stagedItems.count ?? 0
                if count > 0, let bytes = self?.stagedSavedBytes {
                    let sizeStr = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    content.body = "\(count) verified item(s) (\(sizeStr)) are backed up safely on your server. Tap to reclaim iPhone storage."
                } else {
                    content.body = "Overnight backup finished! Open photoHub to confirm deleting backed-up originals in 1 tap."
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
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.morningNotificationIdentifier])
        }
    }

    func clearAllStagedItems() {
        stagedItems = []
        saveStagedItems()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.morningNotificationIdentifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.morningNotificationIdentifier])
    }

    private func handleBackgroundProcessingTask(_ task: BGProcessingTask) {
        guard let settings = settingsRef else {
            task.setTaskCompleted(success: false)
            return
        }

        // Re-enqueue tomorrow's nightly run immediately per Apple best practices
        scheduleNightlyBackupIfEnabled(settings: settings)

        guard settings.nightlyAutoBackupEnabled,
              settings.isSignedIn,
              let baseURL = settings.normalizedBaseURL else {
            task.setTaskCompleted(success: true)
            return
        }

        let authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authStatus == .authorized || authStatus == .limited else {
            updateSummary("Skipped overnight backup: Full Photos permission needed.")
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
        let existingStagedIds = Set(stagedItems.map { $0.id })

        let work = Task.detached(priority: .utility) { [weak self] in
            var processedNew = 0
            do {
                _ = try await apiClient.whoami()
            } catch {
                await MainActor.run {
                    self?.updateSummary("Overnight backup skipped: server unreachable.")
                }
                task.setTaskCompleted(success: false)
                return
            }

            let photoService = PhotoLibraryService()
            let tracker = LocalProxyTracker.shared
            let rawCandidates = photoService.scanCandidates(tracker: tracker)
            let prioritized = PhotoBackupPipeline
                .sortCandidates(rawCandidates, by: .largestVideosFirst)
                .filter { !existingStagedIds.contains($0.id) }
                .prefix(40)

            let videoSemaphore = AsyncSemaphore(value: 1)
            let photosSaveSemaphore = AsyncSemaphore(value: 1)

            for candidate in prioritized {
                if Task.isCancelled { break }
                do {
                    let outcome = try await PhotoBackupPipeline.backupAndProxyAsset(
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
                } catch APIClientError.httpError(507, _) {
                    await MainActor.run {
                        self?.updateSummary("Overnight backup stopped: server storage limit reached.")
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
                    self.updateSummary("Verified \(processedNew) new item(s); \(totalCount) item(s) (~\(totalStr)) ready for 1-tap cleanup.")
                    self.scheduleMorningNotification(
                        count: totalCount,
                        savedBytes: totalBytes,
                        morningHour: morningHour
                    )
                } else {
                    self.updateSummary("Overnight check complete: library is already up to date.")
                }
            }

            task.setTaskCompleted(success: !Task.isCancelled)
        }

        task.expirationHandler = {
            work.cancel()
        }
    }

    private func scheduleMorningNotification(count: Int, savedBytes: Int64, morningHour: Int) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional else {
                return
            }

            let sizeStr = ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file)
            let content = UNMutableNotificationContent()
            content.title = "Free Up \(sizeStr) on Your iPhone"
            content.body = "\(count) backed-up item(s) passed SHA-256 verification overnight. Tap to delete originals safely."
            content.sound = .default

            let now = Date()
            let cal = Calendar.current
            let currentHour = cal.component(.hour, from: now)
            let targetHour = min(22, max(6, morningHour))

            let trigger: UNNotificationTrigger
            if currentHour >= targetHour && currentHour < 21 {
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
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
            }

            let req = UNNotificationRequest(
                identifier: Self.morningNotificationIdentifier,
                content: content,
                trigger: trigger
            )
            UNUserNotificationCenter.current().add(req)
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
        // Aim for 01:00 AM local time so it triggers when plugged in overnight
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
