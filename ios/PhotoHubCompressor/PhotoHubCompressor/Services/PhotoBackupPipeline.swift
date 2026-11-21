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
                _ = try await apiClient.uploadMasterPresigned(
                    fileURL: master.fileURL,
                    filename: master.filename,
                    mimeType: master.mimeType,
                    createdAt: candidate.creationDate,
                    expectedSha256: master.sha256,
                    onProgress: progressHandler
                )
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
                proxy = try await ProxyGenerator.createVideoProxy(from: master.fileURL, masterHash: master.sha256)
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
