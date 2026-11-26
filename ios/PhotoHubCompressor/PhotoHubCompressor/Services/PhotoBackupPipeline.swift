import CryptoKit
import Foundation
import Photos

struct BackupPipelineOutcome: Sendable {
    let masterSha256: String
    let masterBytes: Int64
    let proxyBytes: Int64
    let savedBytes: Int64
    let filename: String
}

enum BackupPipelineResult: Sendable {
    case backedUp(BackupPipelineOutcome)
    case skippedExistingProxy(masterHash: String?)
    case skippedProtectedOriginal(masterHash: String?)
    case skippedInFlight
}

enum PhotoBackupPipeline {
    static func sortCandidates(_ items: [PhotoCandidate], by mode: CandidateSortMode) -> [PhotoCandidate] {
        items.sorted { lhs, rhs in
            switch mode {
            case .largestVideosFirst:
                if lhs.isVideo != rhs.isVideo {
                    return lhs.isVideo && !rhs.isVideo
                }
                if lhs.estimatedBytes != rhs.estimatedBytes {
                    return lhs.estimatedBytes > rhs.estimatedBytes
                }
                return compareDatesDesc(lhs.creationDate, rhs.creationDate, lhsId: lhs.id, rhsId: rhs.id)

            case .largestFirst:
                if lhs.estimatedBytes != rhs.estimatedBytes {
                    return lhs.estimatedBytes > rhs.estimatedBytes
                }
                return compareDatesDesc(lhs.creationDate, rhs.creationDate, lhsId: lhs.id, rhsId: rhs.id)

            case .newestFirst:
                return compareDatesDesc(lhs.creationDate, rhs.creationDate, lhsId: lhs.id, rhsId: rhs.id)
            }
        }
    }

    private static func compareDatesDesc(
        _ lhs: Date?,
        _ rhs: Date?,
        lhsId: String,
        rhsId: String
    ) -> Bool {
        switch (lhs, rhs) {
        case let (ld?, rd?) where ld != rd:
            return ld > rd
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhsId > rhsId
        }
    }

    static func backupAndProxyAsset(
        candidate: PhotoCandidate,
        photoService: PhotoLibraryService,
        apiClient: PhotoHubAPIClient,
        tracker: LocalProxyTracker,
        format: ProxyFormat,
        maxPixelSize: Int,
        quality: Double,
        uploadMode: UploadMode,
        keepLocalProxy: Bool,
        normalizedBaseURL: URL?,
        cacheScopeKey: String,
        videoSemaphore: AsyncSemaphore,
        photosSaveSemaphore: AsyncSemaphore,
        onStageChange: @Sendable @escaping (PhotoCompressionState) -> Void
    ) async throws -> BackupPipelineResult {
        // Fast local metadata guard before any export/iCloud download
        if let proxyMatch = PhotoLibraryService.proxyHashPrefixFromAssetResources(candidate.asset) {
            tracker.markAsProxy(
                assetId: candidate.id,
                proxySha256: "",
                masterHash: nil,
                originalName: proxyMatch.filename
            )
            return .skippedExistingProxy(masterHash: nil)
        }
        if tracker.isRestoredOriginal(assetId: candidate.id) {
            return .skippedProtectedOriginal(masterHash: nil)
        }

        // Step 1: Export full-resolution original & compute SHA-256
        let master = try await photoService.exportOriginalMasterAsync(for: candidate.asset)
        defer { try? FileManager.default.removeItem(at: master.fileURL) }

        // Step 1b: Inspect embedded EXIF/QuickTime proxy marker (catches iCloud-synced proxies even if renamed/re-encoded)
        if let embeddedMasterHash = await ProxyGenerator.extractEmbeddedProxyMasterHash(
            fromFileURL: master.fileURL,
            isVideo: candidate.mediaType == .video
        ) {
            tracker.markAsProxy(
                assetId: candidate.id,
                proxySha256: master.sha256,
                masterHash: embeddedMasterHash,
                originalName: master.filename
            )
            return .skippedExistingProxy(masterHash: embeddedMasterHash)
        }

        // Step 2: Check server & upload original if not already verified on server
        let checkResult = try await apiClient.checkHash(master.sha256)
        if checkResult.isProxy == true {
            tracker.markAsProxy(
                assetId: candidate.id,
                proxySha256: master.sha256,
                masterHash: checkResult.masterHash,
                originalName: master.filename
            )
            return .skippedExistingProxy(masterHash: checkResult.masterHash)
        }

        let resolvedMasterHash = checkResult.masterHash ?? master.sha256
        guard AssetUploadCoordinator.shared.tryClaimMasterHash(resolvedMasterHash) else {
            return .skippedInFlight
        }
        defer { AssetUploadCoordinator.shared.releaseMasterHash(resolvedMasterHash) }

        let isProtectedOriginal = (checkResult.keepOriginalOnDevice == true)
            || (checkResult.isProtectedOriginal == true)
            || tracker.isRestoredMasterHash(master.sha256)
            || tracker.isRestoredMasterHash(resolvedMasterHash)
        if isProtectedOriginal {
            tracker.markRestoredOriginal(assetId: candidate.id, masterHash: resolvedMasterHash)
            return .skippedProtectedOriginal(masterHash: resolvedMasterHash)
        }

        let needsUpload = !(checkResult.exists && checkResult.isMaster == true && checkResult.canReplaceWithProxy == true)
        let serverHasProxy = (checkResult.hasProxy == true)
        let localProxyAlreadyExists = tracker.liveProxyAssetId(forMasterHash: resolvedMasterHash) != nil
            || tracker.isMasterHandledForPhotos(resolvedMasterHash)

        // If original + server proxy (and local proxy if needed) are already completed,
        // skip both uploading and re-compressing/saving duplicate proxies to Apple Photos.
        if !needsUpload && serverHasProxy && (!keepLocalProxy || localProxyAlreadyExists) {
            let knownProxyBytes = checkResult.proxySize ?? 0
            let savedBytes = keepLocalProxy ? max(0, master.sizeBytes - knownProxyBytes) : master.sizeBytes
            return .backedUp(
                BackupPipelineOutcome(
                    masterSha256: master.sha256,
                    masterBytes: master.sizeBytes,
                    proxyBytes: knownProxyBytes,
                    savedBytes: savedBytes,
                    filename: master.filename
                )
            )
        }

        if needsUpload {
            onStageChange(.uploading(0))
            let progressHandler: @Sendable (Double) -> Void = { progress in
                onStageChange(.uploading(progress))
            }

            switch uploadMode {
            case .directVPS:
                _ = try await apiClient.uploadMasterDirect(
                    fileURL: master.fileURL,
                    filename: master.filename,
                    mimeType: master.mimeType,
                    createdAt: candidate.creationDate,
                    expectedSha256: master.sha256,
                    onProgress: progressHandler
                )
            case .s3Presigned:
                do {
                    _ = try await apiClient.uploadMasterPresigned(
                        fileURL: master.fileURL,
                        filename: master.filename,
                        mimeType: master.mimeType,
                        createdAt: candidate.creationDate,
                        expectedSha256: master.sha256,
                        onProgress: progressHandler
                    )
                } catch APIClientError.httpError(501, _) {
                    // Server switched back to direct storage; fall back transparently.
                    _ = try await apiClient.uploadMasterDirect(
                        fileURL: master.fileURL,
                        filename: master.filename,
                        mimeType: master.mimeType,
                        createdAt: candidate.creationDate,
                        expectedSha256: master.sha256,
                        onProgress: progressHandler
                    )
                }
            }
        }

        // Step 3: Create lightweight proxy (limit heavy video transcoding to 1 at a time)
        onStageChange(.creatingProxy)
        let proxy: GeneratedProxy
        let previewFileForServer: URL?
        let previewFormatForServer: String
        let videoProxyFileForServer: URL?

        if candidate.mediaType == .video {
            await videoSemaphore.acquire()
            do {
                proxy = try await ProxyGenerator.createVideoProxy(
                    from: master.fileURL,
                    maxPixelSize: maxPixelSize,
                    quality: quality,
                    masterHash: master.sha256
                )
                await videoSemaphore.release()
            } catch {
                await videoSemaphore.release()
                throw error
            }
            previewFileForServer = proxy.posterFileURL
            previewFormatForServer = "jpeg"
            videoProxyFileForServer = proxy.fileURL
        } else {
            proxy = try ProxyGenerator.createProxy(
                from: master.fileURL,
                format: format,
                maxPixelSize: maxPixelSize,
                quality: quality,
                masterHash: master.sha256
            )
            previewFileForServer = proxy.fileURL
            previewFormatForServer = format.rawValue
            videoProxyFileForServer = nil
        }

        try? FileManager.default.removeItem(at: master.fileURL)
        defer {
            ProxyGenerator.cleanupTempFile(proxy.fileURL)
            ProxyGenerator.cleanupTempFile(proxy.posterFileURL)
        }

        // Step 4: Register proxy on server & cache locally
        try? await apiClient.registerProxy(
            masterHash: master.sha256,
            proxyHash: proxy.sha256,
            assetId: candidate.id,
            proxyFileURL: previewFileForServer,
            proxyFormat: previewFormatForServer,
            videoProxyURL: videoProxyFileForServer
        )

        if let previewURL = previewFileForServer {
            LocalProxyStore.shared.copyPreviewFile(from: previewURL, forHash: master.sha256)
        }
        if candidate.mediaType == .video {
            LocalProxyStore.shared.copyVideoProxy(from: proxy.fileURL, forHash: master.sha256)
        }

        let iso = ISO8601DateFormatter()
        let nowISO = iso.string(from: Date())
        let photoISO = candidate.creationDate.map { iso.string(from: $0) } ?? nowISO
        let posterSize: Int64? = {
            guard let previewURL = previewFileForServer,
                  let values = try? previewURL.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize else {
                return nil
            }
            return Int64(size)
        }()
        LocalProxyStore.shared.upsertPhoto(
            ServerPhoto(
                hash: master.sha256,
                originalName: master.filename,
                size: master.sizeBytes,
                photoDate: photoISO,
                takenAt: photoISO,
                uploadedAt: nowISO,
                savedPath: checkResult.savedPath ?? master.filename,
                hasProxy: true,
                hasPreview: previewFileForServer != nil,
                proxyHash: proxy.sha256,
                proxySize: candidate.mediaType == .video ? posterSize : proxy.sizeBytes,
                hasVideoProxy: candidate.mediaType == .video,
                videoProxySize: candidate.mediaType == .video ? proxy.sizeBytes : nil,
                keepOriginalOnDevice: false
            ),
            baseURL: normalizedBaseURL,
            apiKey: cacheScopeKey
        )

        // Step 5: Save compressed proxy to iPhone Photos (serialized for photolibraryd stability)
        let savedBytes = keepLocalProxy
            ? max(0, master.sizeBytes - proxy.sizeBytes)
            : master.sizeBytes

        if keepLocalProxy {
            onStageChange(.replacingInPhotos)
            await photosSaveSemaphore.acquire()
            let newAssetId: String
            do {
                newAssetId = try await photoService.saveCompressedProxyToPhotosAsync(
                    originalAsset: candidate.asset,
                    mediaType: candidate.mediaType,
                    proxyFileURL: proxy.fileURL
                )
                await photosSaveSemaphore.release()
            } catch {
                await photosSaveSemaphore.release()
                throw error
            }

            if newAssetId != candidate.id {
                tracker.markAsProxy(
                    assetId: newAssetId,
                    proxySha256: proxy.sha256,
                    masterHash: master.sha256,
                    originalName: master.filename
                )
            }
        } else {
            tracker.markMasterHandledForPhotos(master.sha256)
        }

        return .backedUp(
            BackupPipelineOutcome(
                masterSha256: master.sha256,
                masterBytes: master.sizeBytes,
                proxyBytes: proxy.sizeBytes,
                savedBytes: savedBytes,
                filename: master.filename
            )
        )
    }
}

enum GalleryMediaKind: Sendable {
    case proxy
    case originalBackedUp
    case originalUnbacked
    case unknown
}

struct GalleryProxyInspectionItem: Identifiable, Sendable {
    let id: String
    let assetId: String?
    let displayName: String
    let isVideo: Bool
    let localSizeBytes: Int64
    let kind: GalleryMediaKind
    let signals: [String]
    let masterHash: String?
    let proxySha256: String?
    let originalName: String?
    let originalSizeBytes: Int64?
    let isProtectedOriginal: Bool
    let hasServerProxy: Bool
}

struct CandidateDeepCheckMatch: Sendable {
    let isProxy: Bool
    let isMaster: Bool
    let masterHash: String?
    let proxySha256: String?
    let originalName: String?
    let originalSizeBytes: Int64?
    let isProtectedOriginal: Bool
    let signal: String
}

/// Multi-signal detector for native iPhone Photos items:
/// 1. LocalProxyTracker
/// 2. PHOTOHUB_PROXY_ filename tag
/// 3. Embedded EXIF / QuickTime PhotoHubProxy:<masterHash> metadata
/// 4. SHA-256 against cached ServerPhotos and POST /api/check/batch
enum GalleryProxyDetector {
    private static let autoDeepScanMaxBytes: Int64 = 5 * 1024 * 1024
    private static let autoDeepScanLimit: Int = 150

    static func enrichCandidatesWithServer(
        candidates: [PhotoCandidate],
        tracker: LocalProxyTracker,
        client: PhotoHubAPIClient,
        cachedServerPhotos: [ServerPhoto]
    ) async -> [String: CandidateDeepCheckMatch] {
        let eligible = candidates.filter {
            $0.state == .pending &&
            !$0.isVideo &&
            $0.estimatedBytes <= autoDeepScanMaxBytes
        }.prefix(autoDeepScanLimit)
        guard !eligible.isEmpty else { return [:] }

        var serverByHash: [String: ServerPhoto] = [:]
        var serverByProxyHash: [String: ServerPhoto] = [:]
        for p in cachedServerPhotos {
            serverByHash[p.hash.lowercased()] = p
            if let ph = p.proxyHash, !ph.isEmpty {
                serverByProxyHash[ph.lowercased()] = p
            }
        }

        var candidateToSha: [(PhotoCandidate, String)] = []
        candidateToSha.reserveCapacity(eligible.count)
        for cand in eligible {
            guard !Task.isCancelled else { break }
            if let data = PhotoLibraryService.readLocalImageDataIfCached(for: cand.asset, maxBytes: autoDeepScanMaxBytes) {
                let digest = SHA256.hash(data: data)
                let sha = digest.map { String(format: "%02x", $0) }.joined()
                candidateToSha.append((cand, sha))
            }
        }
        guard !candidateToSha.isEmpty else { return [:] }

        var unknownHashes: [String] = []
        var matches: [String: CandidateDeepCheckMatch] = [:]

        for (cand, sha) in candidateToSha {
            let trackedMaster = tracker.masterHash(forProxySha256: sha)
            let cachedByProxy = serverByProxyHash[sha]
            if tracker.isKnownProxy(sha256: sha) || trackedMaster != nil || cachedByProxy != nil {
                let mHash = trackedMaster ?? cachedByProxy?.hash
                let linkedServer = mHash.flatMap { serverByHash[$0.lowercased()] } ?? cachedByProxy
                tracker.markAsProxy(
                    assetId: cand.id,
                    proxySha256: sha,
                    masterHash: mHash,
                    originalName: linkedServer?.originalName ?? cand.filename
                )
                matches[cand.id] = CandidateDeepCheckMatch(
                    isProxy: true,
                    isMaster: false,
                    masterHash: mHash,
                    proxySha256: sha,
                    originalName: linkedServer?.originalName,
                    originalSizeBytes: linkedServer?.size,
                    isProtectedOriginal: linkedServer?.isProtectedOriginal ?? false,
                    signal: "Local / Server Proxy Hash"
                )
            } else {
                unknownHashes.append(sha)
            }
        }

        if !unknownHashes.isEmpty,
           let batchResults = try? await client.checkHashesBatch(unknownHashes) {
            for (cand, sha) in candidateToSha where matches[cand.id] == nil {
                guard let check = batchResults[sha], check.exists else { continue }
                let resolvedMaster = (check.masterHash ?? sha)
                let linkedServer = serverByHash[resolvedMaster.lowercased()]
                if check.isProxy == true {
                    tracker.markAsProxy(
                        assetId: cand.id,
                        proxySha256: sha,
                        masterHash: resolvedMaster,
                        originalName: linkedServer?.originalName ?? cand.filename
                    )
                    matches[cand.id] = CandidateDeepCheckMatch(
                        isProxy: true,
                        isMaster: false,
                        masterHash: resolvedMaster,
                        proxySha256: sha,
                        originalName: linkedServer?.originalName,
                        originalSizeBytes: linkedServer?.size,
                        isProtectedOriginal: (check.keepOriginalOnDevice == true) || (check.isProtectedOriginal == true),
                        signal: "Server SHA-256"
                    )
                } else if check.isMaster == true {
                    let prot = (check.keepOriginalOnDevice == true) || (check.isProtectedOriginal == true)
                    if prot {
                        tracker.markRestoredOriginal(assetId: cand.id, masterHash: resolvedMaster)
                    }
                    matches[cand.id] = CandidateDeepCheckMatch(
                        isProxy: false,
                        isMaster: true,
                        masterHash: resolvedMaster,
                        proxySha256: nil,
                        originalName: linkedServer?.originalName ?? cand.filename,
                        originalSizeBytes: linkedServer?.size,
                        isProtectedOriginal: prot,
                        signal: "Server SHA-256"
                    )
                }
            }
        }

        return matches
    }

    static func inspectPickedItems(
        _ items: [PickedMediaResult],
        client: PhotoHubAPIClient,
        tracker: LocalProxyTracker,
        cachedServerPhotos: [ServerPhoto],
        isSignedIn: Bool
    ) async -> [GalleryProxyInspectionItem] {
        guard !items.isEmpty else { return [] }

        var hashByServer: [String: ServerPhoto] = [:]
        var prefixByServer: [String: ServerPhoto] = [:]
        var proxyHashByServer: [String: ServerPhoto] = [:]
        for p in cachedServerPhotos {
            hashByServer[p.hash.lowercased()] = p
            let prefix = ProxyGenerator.proxyPrefixTag(forMasterHash: p.hash)
            if prefix.count >= 8 {
                prefixByServer[prefix] = p
            }
            if let ph = p.proxyHash, !ph.isEmpty {
                proxyHashByServer[ph.lowercased()] = p
            }
        }

        struct Draft {
            let id: String
            let assetId: String?
            let displayName: String
            let isVideo: Bool
            let localSize: Int64
            var signals: [String]
            var masterHash: String?
            var proxySha: String?
            var prefixHint: String?
            var isTrackedProxy: Bool
            var isTrackedRestored: Bool
        }

        let photoService = PhotoLibraryService()
        var drafts: [Draft] = []
        drafts.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            let copiedURL = item.copiedFileURL
            defer {
                if let copiedURL {
                    try? FileManager.default.removeItem(at: copiedURL)
                }
            }

            let asset: PHAsset? = {
                guard let assetId = item.assetId else { return nil }
                return PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject
            }()

            var displayName = copiedURL?.lastPathComponent ?? "Media_\(index + 1)"
            var signals: [String] = []
            var masterHash: String?
            var isTrackedProxy = false
            var isTrackedRestored = false
            var prefixHint: String?

            if let assetId = item.assetId {
                if tracker.isRestoredOriginal(assetId: assetId) {
                    isTrackedRestored = true
                }
                if let match = tracker.masterLookup(forAssetId: assetId) {
                    isTrackedProxy = true
                    masterHash = match.masterHash
                    if let name = match.originalName, !name.isEmpty {
                        displayName = name
                    }
                    signals.append("Local Tracker")
                } else if tracker.isKnownProxy(assetId: assetId) {
                    isTrackedProxy = true
                    signals.append("Local Tracker")
                }
            }

            if let asset, let proxyMatch = PhotoLibraryService.proxyHashPrefixFromAssetResources(asset) {
                prefixHint = proxyMatch.prefix
                displayName = proxyMatch.filename
                signals.append("Filename Tag")
                if masterHash == nil {
                    masterHash = prefixByServer[proxyMatch.prefix]?.hash
                }
            } else if let urlName = copiedURL?.lastPathComponent,
                      let prefix = ProxyGenerator.extractMasterHashPrefix(fromProxyFilename: urlName) {
                prefixHint = prefix
                signals.append("Filename Tag")
                if masterHash == nil {
                    masterHash = prefixByServer[prefix]?.hash
                }
            }

            var exportedTempURL: URL?
            defer {
                if let exportedTempURL {
                    try? FileManager.default.removeItem(at: exportedTempURL)
                }
            }

            var localSize: Int64 = 0
            var inspectionURL: URL? = copiedURL
            var sha: String?

            if let url = copiedURL,
               let vals = try? url.resourceValues(forKeys: [.fileSizeKey]),
               let sz = vals.fileSize, sz > 0 {
                localSize = Int64(sz)
                sha = try? ProxyGenerator.computeFileSHA256(url: url).lowercased()
            } else if let asset, let exported = try? await photoService.exportOriginalMasterAsync(for: asset) {
                exportedTempURL = exported.fileURL
                inspectionURL = exported.fileURL
                localSize = exported.sizeBytes
                sha = exported.sha256.lowercased()
                if displayName.hasPrefix("Media_") {
                    displayName = exported.filename
                }
            } else if let asset {
                localSize = PhotoLibraryService.estimateBytes(for: asset)
            }

            if let inspectionURL,
               let embedded = await ProxyGenerator.extractEmbeddedProxyMasterHash(
                   fromFileURL: inspectionURL,
                   isVideo: item.isVideo
               ) {
                let sig = item.isVideo ? "Video Metadata" : "EXIF Metadata"
                if !signals.contains(sig) { signals.append(sig) }
                if embedded.count == 64 {
                    masterHash = embedded.lowercased()
                } else {
                    if prefixHint == nil { prefixHint = embedded }
                    if masterHash == nil { masterHash = prefixByServer[embedded]?.hash }
                }
            }

            if let sha {
                let trackedBySha = tracker.masterHash(forProxySha256: sha)
                let cachedBySha = proxyHashByServer[sha]
                if tracker.isKnownProxy(sha256: sha) || trackedBySha != nil || cachedBySha != nil {
                    isTrackedProxy = true
                    if !signals.contains("Local Proxy Hash") {
                        signals.append("Local Proxy Hash")
                    }
                    masterHash = masterHash ?? trackedBySha ?? cachedBySha?.hash
                }
            }

            let rowId = item.assetId ?? sha ?? "\(index)_\(displayName)"
            drafts.append(Draft(
                id: rowId,
                assetId: item.assetId,
                displayName: displayName,
                isVideo: item.isVideo,
                localSize: localSize,
                signals: signals,
                masterHash: masterHash,
                proxySha: sha,
                prefixHint: prefixHint,
                isTrackedProxy: isTrackedProxy,
                isTrackedRestored: isTrackedRestored
            ))
        }

        let allShas = drafts.compactMap(\.proxySha)
        let batchResults: [String: CheckResponse]
        let serverOnline: Bool
        if isSignedIn && !allShas.isEmpty {
            do {
                batchResults = try await client.checkHashesBatch(allShas)
                serverOnline = true
            } catch {
                batchResults = [:]
                serverOnline = false
            }
        } else {
            batchResults = [:]
            serverOnline = false
        }

        return drafts.map { d in
            let check = d.proxySha.flatMap { batchResults[$0] }
            let hasLocalProxySignal = d.isTrackedProxy || !d.signals.isEmpty
            let serverSaysProxy = (check?.isProxy == true)
            let resolvedMaster = (d.masterHash ?? check?.masterHash)?.lowercased()
            let linkedServer = resolvedMaster.flatMap { hashByServer[$0] }
                ?? d.prefixHint.flatMap { prefixByServer[$0] }
                ?? d.proxySha.flatMap { proxyHashByServer[$0] }

            var signals = d.signals
            let kind: GalleryMediaKind
            let isProtected = (check?.keepOriginalOnDevice == true) || (check?.isProtectedOriginal == true) || d.isTrackedRestored
            let hasServerProxy = (check?.hasProxy == true) || (linkedServer?.hasProxy == true)

            if serverSaysProxy || hasLocalProxySignal {
                if serverSaysProxy && !signals.contains("Server SHA-256") {
                    signals.append("Server SHA-256")
                }
                kind = .proxy
                if let assetId = d.assetId {
                    tracker.markAsProxy(
                        assetId: assetId,
                        proxySha256: d.proxySha ?? "",
                        masterHash: resolvedMaster ?? linkedServer?.hash,
                        originalName: linkedServer?.originalName ?? d.displayName
                    )
                }
            } else if check?.isMaster == true || d.isTrackedRestored {
                if check?.isMaster == true && !signals.contains("Server SHA-256") {
                    signals.append("Server SHA-256")
                }
                if d.isTrackedRestored && !signals.contains("Restored Original") {
                    signals.append("Restored Original")
                }
                kind = .originalBackedUp
            } else if serverOnline {
                kind = .originalUnbacked
            } else {
                kind = .unknown
            }

            let finalMaster = resolvedMaster ?? linkedServer?.hash ?? (kind == .originalBackedUp ? d.proxySha : nil)
            return GalleryProxyInspectionItem(
                id: d.id,
                assetId: d.assetId,
                displayName: d.displayName,
                isVideo: d.isVideo,
                localSizeBytes: d.localSize,
                kind: kind,
                signals: signals,
                masterHash: finalMaster,
                proxySha256: d.proxySha,
                originalName: linkedServer?.originalName ?? d.displayName,
                originalSizeBytes: linkedServer?.size,
                isProtectedOriginal: isProtected,
                hasServerProxy: hasServerProxy
            )
        }
    }
}
