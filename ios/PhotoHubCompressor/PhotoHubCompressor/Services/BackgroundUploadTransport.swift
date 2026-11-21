import Foundation
import Photos

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
    let serverBaseURLString: String
    let cacheScopeKey: String
    let notifyOnComplete: Bool
    let morningHour: Int
}

/// Manages true silent OS-managed background uploads (`URLSession.background`) so large photos
/// and videos continue uploading in the background with zero Home Screen/Lock Screen notice,
/// waking the app on completion to verify SHA-256, create the proxy, and notify the user to delete originals.
final class BackgroundUploadTransport: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, URLSessionDelegate, @unchecked Sendable {
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
    private var sessionCompletionHandler: (() -> Void)?

    private lazy var backgroundSession: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.allowsExpensiveNetworkAccess = true
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        loadJobs()
        _ = backgroundSession
    }

    func activeAssetIds() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(jobsByTaskId.values.map { $0.assetId })
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
        lock.unlock()
        _ = backgroundSession
    }

    /// Exports/stages `candidate` to Caches and starts an OS-managed background upload task.
    /// Returns `true` if queued cleanly for silent background upload (or already handled/skipped).
    func enqueueSilentUpload(
        candidate: PhotoCandidate,
        photoService: PhotoLibraryService,
        settings: AppSettings
    ) async -> Bool {
        let assetId = candidate.id
        if activeAssetIds().contains(assetId) {
            return true
        }

        let authToken = await MainActor.run { settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !authToken.isEmpty else { return false }
        guard let baseURL = await MainActor.run { settings.normalizedBaseURL } else { return false }

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
                return true
            }

            let apiClient = PhotoHubAPIClient(settings: settings)
            let check = try await apiClient.checkHash(master.sha256)
            if check.isProxy == true {
                try? FileManager.default.removeItem(at: master.fileURL)
                LocalProxyTracker.shared.markAsProxy(
                    assetId: assetId,
                    proxySha256: master.sha256,
                    masterHash: check.masterHash,
                    originalName: master.filename
                )
                return true
            }

            let resolvedMasterHash = check.masterHash ?? master.sha256
            let isProtected = (check.keepOriginalOnDevice == true)
                || (check.isProtectedOriginal == true)
                || LocalProxyTracker.shared.isRestoredMasterHash(master.sha256)
                || LocalProxyTracker.shared.isRestoredMasterHash(resolvedMasterHash)
            if isProtected {
                try? FileManager.default.removeItem(at: master.fileURL)
                LocalProxyTracker.shared.markRestoredOriginal(assetId: assetId, masterHash: resolvedMasterHash)
                return true
            }

            // Move master file into persistent Caches folder so iOS doesn't purge /tmp mid-upload
            let stagedURL = try moveMasterToPersistentStaging(from: master.fileURL, sha256: master.sha256, filename: master.filename)

            let uploadURL = baseURL.appendingPathComponent("api/upload")
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
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

            let job = await MainActor.run {
                PendingBackgroundUploadJob(
                    jobId: UUID().uuidString,
                    assetId: assetId,
                    masterSha256: master.sha256,
                    masterBytes: master.sizeBytes,
                    filename: master.filename,
                    mimeType: master.mimeType,
                    creationDate: candidate.creationDate,
                    stagedFilePath: stagedURL.path,
                    isVideo: candidate.mediaType == .video,
                    proxyFormatRaw: settings.proxyFormat.rawValue,
                    proxyMaxPixelSize: settings.proxyMaxPixelSize,
                    proxyQuality: settings.proxyQuality,
                    keepLocalProxyInPhotos: settings.keepLocalProxyInPhotos,
                    serverBaseURLString: baseURL.absoluteString,
                    cacheScopeKey: settings.apiKey,
                    notifyOnComplete: settings.notifyWhenBackgroundUploadFinishes,
                    morningHour: settings.morningReminderHour
                )
            }

            let task = backgroundSession.uploadTask(with: request, fromFile: stagedURL)
            task.taskDescription = job.jobId

            lock.lock()
            jobsByTaskId[task.taskIdentifier] = job
            saveJobsLocked()
            lock.unlock()

            task.resume()
            return true
        } catch {
            return false
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

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let job = jobsByTaskId.removeValue(forKey: task.taskIdentifier)
        let responseData = responseDataByTaskId.removeValue(forKey: task.taskIdentifier)
        if job != nil {
            saveJobsLocked()
        }
        lock.unlock()

        guard let job else { return }
        let stagedURL = URL(fileURLWithPath: job.stagedFilePath)

        guard error == nil,
              let http = task.response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let responseData,
              let confirm = try? JSONDecoder().decode(UploadConfirmResponse.self, from: responseData) else {
            try? FileManager.default.removeItem(at: stagedURL)
            return
        }

        let confirmedHash = (confirm.serverSha256 ?? confirm.hash)?.lowercased()
        let verifiedFlag = (confirm.checksumVerified == true) || (confirm.canDelete == true)
        guard confirm.success, verifiedFlag, confirmedHash == job.masterSha256.lowercased() else {
            try? FileManager.default.removeItem(at: stagedURL)
            return
        }

        Task {
            await finalizeCompletedBackgroundUpload(job: job, stagedURL: stagedURL)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = sessionCompletionHandler
        sessionCompletionHandler = nil
        lock.unlock()

        if let handler {
            DispatchQueue.main.async {
                handler()
            }
        }
    }

    // MARK: - Finalize Proxy & Notify for Deletion

    private func finalizeCompletedBackgroundUpload(job: PendingBackgroundUploadJob, stagedURL: URL) async {
        defer { try? FileManager.default.removeItem(at: stagedURL) }

        let settings = await MainActor.run { AppSettings() }
        let apiClient = PhotoHubAPIClient(settings: settings)
        let tracker = LocalProxyTracker.shared
        let photoService = PhotoLibraryService()
        let format = ProxyFormat(rawValue: job.proxyFormatRaw) ?? .heic

        var proxyBytes: Int64 = 0
        var generatedProxy: GeneratedProxy?

        do {
            if job.isVideo {
                generatedProxy = try await ProxyGenerator.createVideoProxy(from: stagedURL, masterHash: job.masterSha256)
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

            if job.keepLocalProxyInPhotos,
               let liveAsset = PhotoLibraryService.fetchLiveAssets(forLocalIdentifiers: [job.assetId]).first {
                if let newAssetId = try? await photoService.saveCompressedProxyToPhotosAsync(
                    originalAsset: liveAsset,
                    mediaType: job.isVideo ? .video : .image,
                    proxyFileURL: proxy.fileURL
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
            if job.notifyOnComplete && !mgr.stagedItems.isEmpty {
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
