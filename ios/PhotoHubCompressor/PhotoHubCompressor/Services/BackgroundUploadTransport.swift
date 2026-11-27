import Foundation
import Photos

extension Notification.Name {
    static let photoHubCheckRemainingSilentUploads = Notification.Name("photoHub.checkRemainingSilentUploads")
}

enum BackgroundEnqueueOutcome: Sendable {
    case queuedBackgroundUpload
    case finalizedLocally
    case skippedAlreadyHandled
    case failed
}

struct PendingBackgroundUploadJob: Codable, Sendable {
    let jobId: String
    let assetId: String
    let masterSha256: String
    let masterBytes: Int64
    let filename: String
    let mimeType: String
    let creationDate: Date?
    let stagedFilePath: String
    let isVideo: Bool
    let proxyFormatRaw: String
    let proxyMaxPixelSize: Int
    let proxyQuality: Double
    let keepLocalProxyInPhotos: Bool
    let backupOnly: Bool
    let serverBaseURLString: String
    let cacheScopeKey: String
    let notifyOnComplete: Bool
    let morningHour: Int

    init(
        jobId: String,
        assetId: String,
        masterSha256: String,
        masterBytes: Int64,
        filename: String,
        mimeType: String,
        creationDate: Date?,
        stagedFilePath: String,
        isVideo: Bool,
        proxyFormatRaw: String,
        proxyMaxPixelSize: Int,
        proxyQuality: Double,
        keepLocalProxyInPhotos: Bool,
        backupOnly: Bool = false,
        serverBaseURLString: String,
        cacheScopeKey: String,
        notifyOnComplete: Bool,
        morningHour: Int
    ) {
        self.jobId = jobId
        self.assetId = assetId
        self.masterSha256 = masterSha256
        self.masterBytes = masterBytes
        self.filename = filename
        self.mimeType = mimeType
        self.creationDate = creationDate
        self.stagedFilePath = stagedFilePath
        self.isVideo = isVideo
        self.proxyFormatRaw = proxyFormatRaw
        self.proxyMaxPixelSize = proxyMaxPixelSize
        self.proxyQuality = proxyQuality
        self.keepLocalProxyInPhotos = keepLocalProxyInPhotos
        self.backupOnly = backupOnly
        self.serverBaseURLString = serverBaseURLString
        self.cacheScopeKey = cacheScopeKey
        self.notifyOnComplete = notifyOnComplete
        self.morningHour = morningHour
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decode(String.self, forKey: .jobId)
        assetId = try c.decode(String.self, forKey: .assetId)
        masterSha256 = try c.decode(String.self, forKey: .masterSha256)
        masterBytes = try c.decode(Int64.self, forKey: .masterBytes)
        filename = try c.decode(String.self, forKey: .filename)
        mimeType = try c.decode(String.self, forKey: .mimeType)
        creationDate = try c.decodeIfPresent(Date.self, forKey: .creationDate)
        stagedFilePath = try c.decode(String.self, forKey: .stagedFilePath)
        isVideo = try c.decode(Bool.self, forKey: .isVideo)
        proxyFormatRaw = try c.decode(String.self, forKey: .proxyFormatRaw)
        proxyMaxPixelSize = try c.decode(Int.self, forKey: .proxyMaxPixelSize)
        proxyQuality = try c.decode(Double.self, forKey: .proxyQuality)
        keepLocalProxyInPhotos = try c.decode(Bool.self, forKey: .keepLocalProxyInPhotos)
        backupOnly = try c.decodeIfPresent(Bool.self, forKey: .backupOnly) ?? false
        serverBaseURLString = try c.decode(String.self, forKey: .serverBaseURLString)
        cacheScopeKey = try c.decode(String.self, forKey: .cacheScopeKey)
        notifyOnComplete = try c.decode(Bool.self, forKey: .notifyOnComplete)
        morningHour = try c.decode(Int.self, forKey: .morningHour)
    }
}

struct BackgroundUploadConfig: Sendable {
    let authToken: String
    let baseURL: URL
    let proxyFormatRaw: String
    let proxyMaxPixelSize: Int
    let proxyQuality: Double
    let keepLocalProxyInPhotos: Bool
    let backupOnly: Bool
    let cacheScopeKey: String
    let notifyOnComplete: Bool
    let morningHour: Int
    let wifiOnlyBackup: Bool

    @MainActor
    init?(settings: AppSettings) {
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let url = settings.normalizedBaseURL else {
            return nil
        }
        let isBackupOnly = settings.isBackupOnlyMode
        self.authToken = token
        self.baseURL = url
        self.proxyFormatRaw = settings.proxyFormat.rawValue
        self.proxyMaxPixelSize = settings.proxyMaxPixelSize
        self.proxyQuality = settings.proxyQuality
        self.keepLocalProxyInPhotos = !isBackupOnly && settings.keepLocalProxyInPhotos
        self.backupOnly = isBackupOnly
        self.cacheScopeKey = settings.apiKey
        self.notifyOnComplete = !isBackupOnly && settings.notifyWhenBackgroundUploadFinishes
        self.morningHour = settings.morningReminderHour
        self.wifiOnlyBackup = settings.wifiOnlyBackup
    }
}

/// Manages true silent OS-managed background uploads (`URLSession.background`) so large photos
/// and videos continue uploading in the background with zero Home Screen/Lock Screen notice,
/// waking the app on completion to verify SHA-256, create the proxy, and notify the user to delete originals.
final class BackgroundUploadTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundUploadTransport()
    static let sessionIdentifier = "com.photohub.compressor.silentBgUpload"

    private let lock = NSLock()
    private let jobsDefaultsKey = "photohub.pendingBgUploadJobs.v1"
    private let defaults = UserDefaults.standard
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private var jobsByTaskId: [Int: PendingBackgroundUploadJob] = [:]
    private var responseDataByTaskId: [Int: Data] = [:]
    private var progressByTaskId: [Int: (sent: Int64, expected: Int64)] = [:]
    private var lastProgressEmitTime: CFAbsoluteTime = 0
    private var pendingFinalizationCount: Int = 0
    private var didReceiveFinishEvents: Bool = false
    private var sessionCompletionHandler: (() -> Void)?

    private lazy var backgroundSession: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.allowsExpensiveNetworkAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        loadJobs()
        let restoredIds = Set(jobsByTaskId.values.map { $0.assetId })
        AssetUploadCoordinator.shared.syncPersistedBackgroundAssetIds(restoredIds)
        _ = backgroundSession
        reconcileOrphanedTasks()
    }

    /// Prunes any persisted jobs whose URLSessionTask is no longer alive (e.g. OS purged or app reinstalled)
    /// so assets never remain stuck in `AssetUploadCoordinator`.
    func reconcileOrphanedTasks() {
        backgroundSession.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let liveTaskIds = Set(tasks.map { $0.taskIdentifier })
            var orphanedJobs: [PendingBackgroundUploadJob] = []

            self.lock.lock()
            let staleKeys = self.jobsByTaskId.keys.filter { !liveTaskIds.contains($0) }
            for key in staleKeys {
                if let removed = self.jobsByTaskId.removeValue(forKey: key) {
                    orphanedJobs.append(removed)
                }
                self.responseDataByTaskId.removeValue(forKey: key)
                self.progressByTaskId.removeValue(forKey: key)
            }
            if !staleKeys.isEmpty {
                self.saveJobsLocked()
            }
            let remainingCount = self.jobsByTaskId.count
            self.lock.unlock()

            for job in orphanedJobs {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: job.stagedFilePath))
                AssetUploadCoordinator.shared.releaseAsset(job.assetId, owner: .background)
            }
            self.emitProgressSnapshot(force: true, overrideCount: remainingCount)
        }
    }

    func activeAssetIds() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(jobsByTaskId.values.map { $0.assetId })
    }

    func activeMasterHashes() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(jobsByTaskId.values.map { $0.masterSha256.lowercased() })
    }

    func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }
        lock.lock()
        sessionCompletionHandler = completionHandler
        didReceiveFinishEvents = false
        lock.unlock()
        _ = backgroundSession
    }

    /// Exports/stages `candidate` to Caches and starts an OS-managed background upload task.
    /// Caller must hold a `.background` claim on `candidate.id` (which transfers to this transport
    /// only when `.queuedBackgroundUpload` is returned).
    func enqueueSilentUpload(
        candidate: PhotoCandidate,
        photoService: PhotoLibraryService,
        apiClient: PhotoHubAPIClient,
        config: BackgroundUploadConfig
    ) async -> BackgroundEnqueueOutcome {
        let assetId = candidate.id
        if activeAssetIds().contains(assetId) {
            return .queuedBackgroundUpload
        }

        do {
            let master = try await photoService.exportOriginalMasterAsync(for: candidate.asset)

            // Ensure we never re-upload an iCloud-synced proxy
            if let embeddedMasterHash = await ProxyGenerator.extractEmbeddedProxyMasterHash(
                fromFileURL: master.fileURL,
                isVideo: candidate.mediaType == .video
            ) {
                try? FileManager.default.removeItem(at: master.fileURL)
                LocalProxyTracker.shared.markAsProxy(
                    assetId: assetId,
                    proxySha256: master.sha256,
                    masterHash: embeddedMasterHash,
                    originalName: master.filename
                )
                return .skippedAlreadyHandled
            }

            let check = try await apiClient.checkHash(master.sha256)
            if check.isProxy == true {
                try? FileManager.default.removeItem(at: master.fileURL)
                LocalProxyTracker.shared.markAsProxy(
                    assetId: assetId,
                    proxySha256: master.sha256,
                    masterHash: check.masterHash,
                    originalName: master.filename
                )
                return .skippedAlreadyHandled
            }

            let resolvedMasterHash = check.masterHash ?? master.sha256
            if activeMasterHashes().contains(resolvedMasterHash.lowercased()) {
                try? FileManager.default.removeItem(at: master.fileURL)
                return .skippedAlreadyHandled
            }
            guard AssetUploadCoordinator.shared.tryClaimMasterHash(resolvedMasterHash) else {
                try? FileManager.default.removeItem(at: master.fileURL)
                return .skippedAlreadyHandled
            }
            defer { AssetUploadCoordinator.shared.releaseMasterHash(resolvedMasterHash) }

            let tracker = LocalProxyTracker.shared
            let isProtected = (check.keepOriginalOnDevice == true)
                || (check.isProtectedOriginal == true)
                || tracker.isRestoredMasterHash(master.sha256)
                || tracker.isRestoredMasterHash(resolvedMasterHash)
            if isProtected {
                try? FileManager.default.removeItem(at: master.fileURL)
                tracker.markRestoredOriginal(assetId: assetId, masterHash: resolvedMasterHash)
                return .skippedAlreadyHandled
            }

            let job = PendingBackgroundUploadJob(
                jobId: UUID().uuidString,
                assetId: assetId,
                masterSha256: master.sha256,
                masterBytes: master.sizeBytes,
                filename: master.filename,
                mimeType: master.mimeType,
                creationDate: candidate.creationDate,
                stagedFilePath: master.fileURL.path,
                isVideo: candidate.mediaType == .video,
                proxyFormatRaw: config.proxyFormatRaw,
                proxyMaxPixelSize: config.proxyMaxPixelSize,
                proxyQuality: config.proxyQuality,
                keepLocalProxyInPhotos: config.keepLocalProxyInPhotos,
                backupOnly: config.backupOnly,
                serverBaseURLString: config.baseURL.absoluteString,
                cacheScopeKey: config.cacheScopeKey,
                notifyOnComplete: config.notifyOnComplete,
                morningHour: config.morningHour
            )

            // If this master is already verified on server (e.g. another upload completed),
            // never re-upload the full original — finalize local proxy/staging right here.
            if check.exists && check.isMaster == true && check.canReplaceWithProxy == true {
                tracker.markUploadedOriginal(assetId: assetId, masterHash: resolvedMasterHash)
                let serverHasProxy = (check.hasProxy == true)
                let localProxyPresent = tracker.liveProxyAssetId(forMasterHash: resolvedMasterHash) != nil
                    || tracker.isMasterHandledForPhotos(resolvedMasterHash)
                if serverHasProxy && (config.backupOnly || !config.keepLocalProxyInPhotos || localProxyPresent) {
                    try? FileManager.default.removeItem(at: master.fileURL)
                    if config.backupOnly {
                        tracker.markMasterHandledForPhotos(resolvedMasterHash)
                        return .finalizedLocally
                    }
                    let knownProxyBytes = check.proxySize ?? 0
                    let savedBytes = config.keepLocalProxyInPhotos
                        ? max(0, master.sizeBytes - knownProxyBytes)
                        : master.sizeBytes
                    let item = StagedCleanupItem(
                        id: assetId,
                        filename: master.filename,
                        masterSha256: master.sha256,
                        savedBytes: savedBytes,
                        verifiedAt: Date()
                    )
                    await MainActor.run {
                        let mgr = BackgroundBackupManager.shared
                        mgr.appendStagedItems([item])
                        mgr.pruneMissingAssetsFromStaged()
                    }
                    return .finalizedLocally
                }

                await finalizeCompletedBackgroundUpload(
                    job: job,
                    stagedURL: master.fileURL,
                    notifyNow: false,
                    releaseCoordinatorAsset: false
                )
                return .finalizedLocally
            }

            // Move master file into persistent Caches folder so iOS doesn't purge /tmp mid-upload
            let stagedURL = try moveMasterToPersistentStaging(from: master.fileURL, sha256: master.sha256, filename: master.filename)

            let uploadURL = config.baseURL.appendingPathComponent("api/upload")
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "POST"
            request.allowsCellularAccess = !config.wifiOnlyBackup
            request.allowsExpensiveNetworkAccess = !config.wifiOnlyBackup
            request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
            request.setValue(master.mimeType, forHTTPHeaderField: "Content-Type")
            request.setValue(
                master.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? master.filename,
                forHTTPHeaderField: "X-File-Name"
            )
            request.setValue(master.sha256, forHTTPHeaderField: "X-File-Sha256")
            request.setValue("strict", forHTTPHeaderField: "X-Verify-Checksum")
            if let creationDate = candidate.creationDate {
                request.setValue(isoFormatter.string(from: creationDate), forHTTPHeaderField: "X-Photo-Date")
            }

            let persistedJob = PendingBackgroundUploadJob(
                jobId: job.jobId,
                assetId: job.assetId,
                masterSha256: job.masterSha256,
                masterBytes: job.masterBytes,
                filename: job.filename,
                mimeType: job.mimeType,
                creationDate: job.creationDate,
                stagedFilePath: stagedURL.path,
                isVideo: job.isVideo,
                proxyFormatRaw: job.proxyFormatRaw,
                proxyMaxPixelSize: job.proxyMaxPixelSize,
                proxyQuality: job.proxyQuality,
                keepLocalProxyInPhotos: job.keepLocalProxyInPhotos,
                backupOnly: job.backupOnly,
                serverBaseURLString: job.serverBaseURLString,
                cacheScopeKey: job.cacheScopeKey,
                notifyOnComplete: job.notifyOnComplete,
                morningHour: job.morningHour
            )

            let task = backgroundSession.uploadTask(with: request, fromFile: stagedURL)
            task.taskDescription = persistedJob.jobId

            lock.lock()
            jobsByTaskId[task.taskIdentifier] = persistedJob
            progressByTaskId[task.taskIdentifier] = (0, max(1, persistedJob.masterBytes))
            saveJobsLocked()
            lock.unlock()

            task.resume()
            emitProgressSnapshot(force: true)
            return .queuedBackgroundUpload
        } catch {
            return .failed
        }
    }

    // MARK: - URLSession Delegates

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        TrustPinningHelper.evaluate(
            challenge: challenge,
            allowSelfSignedHTTPS: false,
            pinnedHashes: AppSettings.buildPinnedCertHashes,
            completionHandler: completionHandler
        )
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var existing = responseDataByTaskId[dataTask.taskIdentifier] ?? Data()
        existing.append(data)
        responseDataByTaskId[dataTask.taskIdentifier] = existing
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        lock.lock()
        let fallbackExpected = jobsByTaskId[task.taskIdentifier]?.masterBytes ?? totalBytesSent
        let expected = totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : max(1, fallbackExpected)
        progressByTaskId[task.taskIdentifier] = (max(0, totalBytesSent), max(1, expected))
        lock.unlock()
        emitProgressSnapshot(force: false)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let job = jobsByTaskId.removeValue(forKey: task.taskIdentifier)
        let responseData = responseDataByTaskId.removeValue(forKey: task.taskIdentifier)
        progressByTaskId.removeValue(forKey: task.taskIdentifier)
        if job != nil {
            saveJobsLocked()
        }
        lock.unlock()

        emitProgressSnapshot(force: true)

        guard let job else { return }
        let stagedURL = URL(fileURLWithPath: job.stagedFilePath)

        guard error == nil,
              let http = task.response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let responseData,
              let confirm = try? JSONDecoder().decode(UploadConfirmResponse.self, from: responseData) else {
            try? FileManager.default.removeItem(at: stagedURL)
            AssetUploadCoordinator.shared.releaseAsset(job.assetId, owner: .background)
            return
        }

        let confirmedHash = (confirm.serverSha256 ?? confirm.hash)?.lowercased()
        let verifiedFlag = (confirm.checksumVerified == true) || (confirm.canDelete == true)
        guard confirm.success, verifiedFlag, confirmedHash == job.masterSha256.lowercased() else {
            try? FileManager.default.removeItem(at: stagedURL)
            AssetUploadCoordinator.shared.releaseAsset(job.assetId, owner: .background)
            return
        }

        // Hold background session completion handler until proxy creation & notification finish.
        lock.lock()
        pendingFinalizationCount += 1
        lock.unlock()

        Task {
            defer {
                self.finishOnePendingFinalization()
            }
            await finalizeCompletedBackgroundUpload(
                job: job,
                stagedURL: stagedURL,
                notifyNow: true,
                releaseCoordinatorAsset: true
            )
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        didReceiveFinishEvents = true
        let handler = (pendingFinalizationCount == 0) ? sessionCompletionHandler : nil
        if handler != nil {
            sessionCompletionHandler = nil
            didReceiveFinishEvents = false
        }
        lock.unlock()

        if let handler {
            DispatchQueue.main.async {
                handler()
            }
        }
    }

    private func finishOnePendingFinalization() {
        lock.lock()
        pendingFinalizationCount = max(0, pendingFinalizationCount - 1)
        let handler = (pendingFinalizationCount == 0 && didReceiveFinishEvents) ? sessionCompletionHandler : nil
        if handler != nil {
            sessionCompletionHandler = nil
            didReceiveFinishEvents = false
        }
        lock.unlock()

        if let handler {
            DispatchQueue.main.async {
                handler()
            }
        }
    }

    private func emitProgressSnapshot(force: Bool, overrideCount: Int? = nil) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if !force && (now - lastProgressEmitTime) < 0.35 {
            lock.unlock()
            return
        }
        lastProgressEmitTime = now
        let count = overrideCount ?? jobsByTaskId.count
        var sentSum: Int64 = 0
        var expectedSum: Int64 = 0
        for item in progressByTaskId.values {
            sentSum += item.sent
            expectedSum += item.expected
        }
        lock.unlock()

        let fraction: Double
        if count == 0 {
            fraction = 0
        } else if expectedSum > 0 {
            fraction = min(1.0, max(0.0, Double(sentSum) / Double(expectedSum)))
        } else {
            fraction = 0
        }
        Task { @MainActor in
            BackgroundBackupManager.shared.updateLiveBackgroundTransport(activeCount: count, progress: fraction)
        }
    }

    // MARK: - Finalize Proxy & Notify for Deletion

    private func finalizeCompletedBackgroundUpload(
        job: PendingBackgroundUploadJob,
        stagedURL: URL,
        notifyNow: Bool,
        releaseCoordinatorAsset: Bool
    ) async {
        defer {
            try? FileManager.default.removeItem(at: stagedURL)
            if releaseCoordinatorAsset {
                AssetUploadCoordinator.shared.releaseAsset(job.assetId, owner: .background)
                if activeAssetIds().isEmpty {
                    Task { @MainActor in
                        NotificationCenter.default.post(name: .photoHubCheckRemainingSilentUploads, object: nil)
                        let bg = BackgroundBackupManager.shared
                        if !bg.isPausedForRestore {
                            bg.triggerSilentAutoUpload(settings: AppSettings(), isMovingToBackground: true)
                        }
                    }
                }
            }
        }

        let settings = await MainActor.run { AppSettings() }
        let apiClient = PhotoHubAPIClient(settings: settings)
        let tracker = LocalProxyTracker.shared
        let photoService = PhotoLibraryService()
        let format = ProxyFormat(rawValue: job.proxyFormatRaw) ?? .heic

        var proxyBytes: Int64 = 0
        var generatedProxy: GeneratedProxy?

        do {
            if job.isVideo {
                generatedProxy = try await ProxyGenerator.createVideoProxy(
                    from: stagedURL,
                    maxPixelSize: job.proxyMaxPixelSize,
                    quality: job.proxyQuality,
                    masterHash: job.masterSha256
                )
            } else {
                generatedProxy = try ProxyGenerator.createProxy(
                    from: stagedURL,
                    format: format,
                    maxPixelSize: job.proxyMaxPixelSize,
                    quality: job.proxyQuality,
                    masterHash: job.masterSha256
                )
            }
        } catch {
            generatedProxy = nil
        }

        defer {
            ProxyGenerator.cleanupTempFile(generatedProxy?.fileURL)
            ProxyGenerator.cleanupTempFile(generatedProxy?.posterFileURL)
        }

        if let proxy = generatedProxy {
            proxyBytes = proxy.sizeBytes
            let previewURL = job.isVideo ? proxy.posterFileURL : proxy.fileURL
            let previewFmt = job.isVideo ? "jpeg" : format.rawValue
            let videoURL = job.isVideo ? proxy.fileURL : nil

            try? await apiClient.registerProxy(
                masterHash: job.masterSha256,
                proxyHash: proxy.sha256,
                assetId: job.assetId,
                proxyFileURL: previewURL,
                proxyFormat: previewFmt,
                videoProxyURL: videoURL
            )

            if let previewURL {
                LocalProxyStore.shared.copyPreviewFile(from: previewURL, forHash: job.masterSha256)
            }
            if job.isVideo {
                LocalProxyStore.shared.copyVideoProxy(from: proxy.fileURL, forHash: job.masterSha256)
            }

            tracker.markUploadedOriginal(assetId: job.assetId, masterHash: job.masterSha256)
            let isBackupOnlyNow = job.backupOnly || (await MainActor.run { settings.isBackupOnlyMode })
            let existingProxyPrefix = ProxyGenerator.proxyPrefixTag(forMasterHash: job.masterSha256)
            let alreadyHasProxyInPhotos = tracker.liveProxyAssetId(forMasterHash: job.masterSha256) != nil
                || PhotoLibraryService.scanExistingProxyPrefixesInPhotos()[existingProxyPrefix] != nil

            if !isBackupOnlyNow,
               job.keepLocalProxyInPhotos,
               !alreadyHasProxyInPhotos,
               let liveAsset = PhotoLibraryService.fetchLiveAssets(forLocalIdentifiers: [job.assetId]).first {
                if let newAssetId = try? await photoService.saveCompressedProxyToPhotosAsync(
                    originalAsset: liveAsset,
                    mediaType: job.isVideo ? .video : .image,
                    proxyFileURL: proxy.fileURL,
                    masterHash: job.masterSha256
                ), newAssetId != job.assetId {
                    tracker.markAsProxy(
                        assetId: newAssetId,
                        proxySha256: proxy.sha256,
                        masterHash: job.masterSha256,
                        originalName: job.filename
                    )
                }
            } else {
                tracker.markMasterHandledForPhotos(job.masterSha256)
            }
        }

        let isBackupOnlyMode = job.backupOnly || (await MainActor.run { settings.isBackupOnlyMode })
        if isBackupOnlyMode {
            await MainActor.run {
                BackgroundBackupManager.shared.updateSummary("Backed up · Originals kept on phone")
            }
            return
        }

        let savedBytes = job.keepLocalProxyInPhotos ? max(0, job.masterBytes - proxyBytes) : job.masterBytes
        let item = StagedCleanupItem(
            id: job.assetId,
            filename: job.filename,
            masterSha256: job.masterSha256,
            savedBytes: savedBytes,
            verifiedAt: Date()
        )

        await MainActor.run {
            let mgr = BackgroundBackupManager.shared
            mgr.appendStagedItems([item])
            mgr.pruneMissingAssetsFromStaged()
            if notifyNow && job.notifyOnComplete && !mgr.stagedItems.isEmpty {
                mgr.sendDeleteOriginalsNotification(
                    count: mgr.stagedItems.count,
                    savedBytes: mgr.stagedSavedBytes,
                    immediate: true,
                    morningHour: job.morningHour
                )
            }
        }
    }

    // MARK: - Persistence Helpers

    private func moveMasterToPersistentStaging(from sourceURL: URL, sha256: String, filename: String) throws -> URL {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let dir = caches.appendingPathComponent("PhotoHubPendingBgUploads", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = URL(fileURLWithPath: filename).pathExtension
        let safeExt = ext.isEmpty ? sourceURL.pathExtension : ext
        let dest = dir.appendingPathComponent("\(sha256.prefix(16))_\(UUID().uuidString.prefix(8)).\(safeExt)")
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: sourceURL, to: dest)
        return dest
    }

    private func loadJobs() {
        guard let data = defaults.data(forKey: jobsDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: PendingBackgroundUploadJob].self, from: data) else {
            return
        }
        var restored: [Int: PendingBackgroundUploadJob] = [:]
        for (key, value) in decoded {
            if let intKey = Int(key) {
                restored[intKey] = value
            }
        }
        jobsByTaskId = restored
    }

    private func saveJobsLocked() {
        let dict = Dictionary(uniqueKeysWithValues: jobsByTaskId.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: jobsDefaultsKey)
        }
    }
}
