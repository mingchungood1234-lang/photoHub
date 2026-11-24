import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers

enum PhotoLibraryError: LocalizedError {
    case permissionDenied
    case noOriginalResourceFound
    case proxyReplacementFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Photo library read/write permission is required."
        case .noOriginalResourceFound:
            return "Could not locate original photo resource."
        case .proxyReplacementFailed(let msg):
            return msg
        }
    }
}

struct ExportedMaster {
    let fileURL: URL
    let sha256: String
    let sizeBytes: Int64
    let filename: String
    let mimeType: String
}

enum PhotoDeleteOutcome {
    case deleted([String])
    case cancelledByUser
}

final class PhotoLibraryService {
    func requestAuthorization(completion: @escaping (PHAuthorizationStatus) -> Void) {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited {
            DispatchQueue.main.async { completion(current) }
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async { completion(status) }
        }
    }

    /// Reads the original filename stored in Photos SQLite/CoreData without downloading iCloud media bytes.
    static func inspectAssetResources(
        for asset: PHAsset
    ) -> (proxyMatch: (prefix: String, filename: String)?, originalFilename: String?) {
        let resources = PHAssetResource.assetResources(for: asset)
        var primaryFilename: String?
        var fallbackFilename: String?
        for resource in resources {
            let name = resource.originalFilename.trimmingCharacters(in: .whitespacesAndNewlines)
            if let prefix = ProxyGenerator.extractMasterHashPrefix(fromProxyFilename: name) {
                return ((prefix, name), name)
            }
            guard !name.isEmpty else { continue }
            if resource.type == .photo || resource.type == .video {
                if primaryFilename == nil { primaryFilename = name }
            } else if resource.type == .fullSizePhoto || resource.type == .fullSizeVideo {
                fallbackFilename = name
            } else if fallbackFilename == nil {
                fallbackFilename = name
            }
        }
        return (nil, primaryFilename ?? fallbackFilename)
    }

    static func proxyHashPrefixFromAssetResources(_ asset: PHAsset) -> (prefix: String, filename: String)? {
        inspectAssetResources(for: asset).proxyMatch
    }

    /// Scans local Photos metadata (zero iCloud download) for any synced or locally created
    /// `PHOTOHUB_PROXY_<prefix>` assets, returning `prefix16 -> PHAsset.localIdentifier`.
    static func scanExistingProxyPrefixesInPhotos() -> [String: String] {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        let assets = PHAsset.fetchAssets(with: fetchOptions)
        var map: [String: String] = [:]
        for i in 0..<assets.count {
            autoreleasepool {
                let asset = assets.object(at: i)
                if let match = proxyHashPrefixFromAssetResources(asset) {
                    map[match.prefix] = asset.localIdentifier
                }
            }
        }
        return map
    }

    static func readLocalImageDataIfCached(for asset: PHAsset, maxBytes: Int64 = 4_000_000) -> Data? {
        guard asset.mediaType == .image else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        options.isSynchronous = true
        var resultData: Data?
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            if let data, data.count <= Int(maxBytes) {
                resultData = data
            }
        }
        return resultData
    }

    func scanCandidates(
        tracker: LocalProxyTracker,
        knownServerPhotos: [ServerPhoto] = [],
        maxResults: Int? = nil,
        maxInspect: Int? = nil
    ) -> [PhotoCandidate] {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let maxInspect, maxInspect > 0 {
            fetchOptions.fetchLimit = maxInspect
        }
        let assets = PHAsset.fetchAssets(with: fetchOptions)

        var candidates: [PhotoCandidate] = []
        let totalCount = assets.count
        if totalCount == 0 {
            return []
        }
        let targetCap = maxResults.map { min(totalCount, $0) } ?? min(totalCount, 500)
        candidates.reserveCapacity(targetCap)

        var prefixToServerPhoto: [String: ServerPhoto] = [:]
        var hashToServerPhoto: [String: ServerPhoto] = [:]
        prefixToServerPhoto.reserveCapacity(knownServerPhotos.count)
        hashToServerPhoto.reserveCapacity(knownServerPhotos.count)
        for serverPhoto in knownServerPhotos {
            hashToServerPhoto[serverPhoto.hash.lowercased()] = serverPhoto
            let prefix = ProxyGenerator.proxyPrefixTag(forMasterHash: serverPhoto.hash)
            if prefix.count >= 8 {
                prefixToServerPhoto[prefix] = serverPhoto
            }
        }

        var eligibleCount = 0

        for i in 0..<totalCount {
            if let maxResults, eligibleCount >= maxResults {
                break
            }
            autoreleasepool {
                let asset = assets.object(at: i)
                let localId = asset.localIdentifier
                let prefixLen = min(8, localId.count)
                let shortId = String(localId.prefix(prefixLen))
                let prefixLabel = asset.mediaType == .video ? "Video" : "Photo"

                // 1. Tracked proxy in LocalProxyTracker (auto-detected & skipped cleanly)
                if tracker.isKnownProxy(assetId: localId) {
                    return
                }

                // 2. Restored original protected on this device
                if tracker.isRestoredOriginal(assetId: localId) {
                    return
                }

                // 3. Filename tag PHOTOHUB_PROXY_<prefix16> from local or iCloud PHAssetResource
                let resourceInfo = Self.inspectAssetResources(for: asset)
                if let proxyMatch = resourceInfo.proxyMatch {
                    let matchedServerPhoto = prefixToServerPhoto[proxyMatch.prefix]
                    tracker.markAsProxy(
                        assetId: localId,
                        proxySha256: matchedServerPhoto?.proxyHash ?? "",
                        masterHash: matchedServerPhoto?.hash,
                        originalName: matchedServerPhoto?.originalName ?? proxyMatch.filename
                    )
                    return
                }

                // 4. Embedded EXIF PhotoHubProxy:<masterHash> marker on compact local images
                if asset.mediaType == .image,
                   max(asset.pixelWidth, asset.pixelHeight) <= 2400,
                   let localData = Self.readLocalImageDataIfCached(for: asset, maxBytes: 4_000_000),
                   let embeddedMaster = ProxyGenerator.extractEmbeddedProxyMasterHash(fromImageData: localData) {
                    let prefix = ProxyGenerator.proxyPrefixTag(forMasterHash: embeddedMaster)
                    let matchedServerPhoto = hashToServerPhoto[embeddedMaster.lowercased()] ?? prefixToServerPhoto[prefix]
                    let resolvedMaster = matchedServerPhoto?.hash ?? embeddedMaster
                    tracker.markAsProxy(
                        assetId: localId,
                        proxySha256: matchedServerPhoto?.proxyHash ?? "",
                        masterHash: resolvedMaster,
                        originalName: matchedServerPhoto?.originalName
                    )
                    return
                }

                eligibleCount += 1
                let displayName = resourceInfo.originalFilename ?? "\(prefixLabel)_\(shortId)"
                candidates.append(
                    PhotoCandidate(
                        id: localId,
                        asset: asset,
                        mediaType: asset.mediaType,
                        duration: asset.duration,
                        filename: displayName,
                        pixelWidth: asset.pixelWidth,
                        pixelHeight: asset.pixelHeight,
                        creationDate: asset.creationDate,
                        estimatedBytes: Self.estimateBytes(for: asset),
                        state: .pending,
                        isSelected: false
                    )
                )
            }
        }

        return candidates
    }

    static func estimateBytes(for asset: PHAsset) -> Int64 {
        let pixels = Int64(max(0, asset.pixelWidth)) * Int64(max(0, asset.pixelHeight))
        if asset.mediaType == .video {
            let durationSec = max(1.0, asset.duration)
            let bytesPerSecond: Double
            if pixels >= 7_000_000 {
                bytesPerSecond = 4_500_000 // ~36 Mbps 4K HEVC/H.264
            } else if pixels >= 1_800_000 {
                bytesPerSecond = 1_800_000 // ~14 Mbps 1080p
            } else if pixels >= 800_000 {
                bytesPerSecond = 900_000 // ~7 Mbps 720p
            } else {
                bytesPerSecond = max(120_000, Double(max(pixels, 1)) * 0.45)
            }
            return max(200_000, Int64(durationSec * bytesPerSecond))
        }
        return max(200_000, pixels / 6)
    }

    static func fetchLiveAssets(forLocalIdentifiers ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var out: [PHAsset] = []
        out.reserveCapacity(fetched.count)
        for idx in 0..<fetched.count {
            out.append(fetched.object(at: idx))
        }
        return out
    }

    func loadThumbnail(
        for asset: PHAsset,
        targetSize: CGSize = CGSize(width: 160, height: 160),
        completion: @escaping (UIImage?) -> Void
    ) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        options.isSynchronous = false

        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            guard let image = image else { return }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    func exportOriginalMaster(
        for asset: PHAsset,
        completion: @escaping (Result<ExportedMaster, Error>) -> Void
    ) {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = Self.pickOriginalResource(from: resources) else {
            completion(.failure(PhotoLibraryError.noOriginalResourceFound))
            return
        }

        let ext = (resource.originalFilename as NSString).pathExtension
        let safeExt = ext.isEmpty ? (asset.mediaType == .video ? "mov" : "heic") : ext
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("master_\(UUID().uuidString).\(safeExt)")

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        let lock = NSLock()
        var hasCompleted = false

        PHAssetResourceManager.default().writeData(for: resource, toFile: tempURL, options: options) { error in
            lock.lock()
            if hasCompleted {
                lock.unlock()
                return
            }
            hasCompleted = true
            lock.unlock()

            if let error = error {
                try? FileManager.default.removeItem(at: tempURL)
                completion(.failure(error))
                return
            }

            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
                let sizeBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let sha256 = try ProxyGenerator.computeFileSHA256(url: tempURL)
                let mimeType = UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream"

                let master = ExportedMaster(
                    fileURL: tempURL,
                    sha256: sha256,
                    sizeBytes: sizeBytes,
                    filename: resource.originalFilename,
                    mimeType: mimeType
                )
                completion(.success(master))
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                completion(.failure(error))
            }
        }
    }

    func exportOriginalMasterAsync(for asset: PHAsset) async throws -> ExportedMaster {
        try await withCheckedThrowingContinuation { continuation in
            exportOriginalMaster(for: asset) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Step 1: Saves the compressed proxy into the native iOS Photos library (proven working on device).
    func saveCompressedProxyToPhotos(
        originalAsset: PHAsset,
        mediaType: PHAssetMediaType,
        proxyFileURL: URL,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let originalId = originalAsset.localIdentifier
        let originalDate = originalAsset.creationDate
        let originalLocation = originalAsset.location
        let originalFavorite = originalAsset.isFavorite

        var createdLocalIdentifier: String?

        PHPhotoLibrary.shared().performChanges({
            let createRequest: PHAssetChangeRequest?
            if mediaType == .video {
                createRequest = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: proxyFileURL)
            } else if let fileReq = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: proxyFileURL) {
                createRequest = fileReq
            } else if let img = UIImage(contentsOfFile: proxyFileURL.path) {
                createRequest = PHAssetChangeRequest.creationRequestForAsset(from: img)
            } else {
                createRequest = nil
            }

            createRequest?.creationDate = originalDate
            createRequest?.location = originalLocation
            createRequest?.isFavorite = originalFavorite
            createdLocalIdentifier = createRequest?.placeholderForCreatedAsset?.localIdentifier
        }, completionHandler: { saveSuccess, saveError in
            DispatchQueue.main.async {
                if saveSuccess {
                    completion(.success(createdLocalIdentifier ?? originalId))
                } else {
                    let nsErr = saveError as NSError?
                    let detail = nsErr.map { "Could not save proxy: \($0.localizedDescription) [\($0.domain):\($0.code)]" }
                        ?? "Could not save compressed proxy to Photos."
                    completion(.failure(PhotoLibraryError.proxyReplacementFailed(detail)))
                }
            }
        })
    }

    func saveCompressedProxyToPhotosAsync(
        originalAsset: PHAsset,
        mediaType: PHAssetMediaType,
        proxyFileURL: URL
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            saveCompressedProxyToPhotos(
                originalAsset: originalAsset,
                mediaType: mediaType,
                proxyFileURL: proxyFileURL
            ) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Step 2: Triggers the native iOS "Allow 'photoHub' to delete..." confirmation sheet on the main thread
    /// using a fresh PHFetchResult<PHAsset>, observing whether iOS presents the system sheet and protecting against stalls.
    func deleteOriginalAssets(
        _ assets: [PHAsset],
        completion: @escaping (Result<PhotoDeleteOutcome, Error>) -> Void
    ) {
        let requestedIds = Array(Set(assets.map { $0.localIdentifier }))
        guard !requestedIds.isEmpty else {
            DispatchQueue.main.async { completion(.success(.deleted([]))) }
            return
        }

        let startDeleteOnMain = {
            let authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard authStatus == .authorized || authStatus == .limited else {
                completion(.failure(PhotoLibraryError.permissionDenied))
                return
            }

            let initialFetch = PHAsset.fetchAssets(withLocalIdentifiers: requestedIds, options: nil)
            guard initialFetch.count > 0 else {
                completion(.success(.deleted(requestedIds)))
                return
            }

            var deletableIds: [String] = []
            var blockedReasons: [String] = []
            for i in 0..<initialFetch.count {
                let asset = initialFetch.object(at: i)
                if asset.canPerform(.delete) {
                    deletableIds.append(asset.localIdentifier)
                } else {
                    blockedReasons.append("\(asset.pixelWidth)x\(asset.pixelHeight) src=\(asset.sourceType.rawValue)")
                }
            }

            guard !deletableIds.isEmpty else {
                let detail: String
                if authStatus == .limited {
                    detail = "Photos access is Limited Access, which blocks deleting originals. Open iOS Settings -> photoHub -> Photos -> Full Access."
                } else {
                    let info = blockedReasons.joined(separator: ", ")
                    detail = "iOS reports canPerform(.delete) == false (\(info)). Assets may be synced from a computer, in a Shared Album, or restricted by Screen Time."
                }
                completion(.failure(PhotoLibraryError.proxyReplacementFailed(detail)))
                return
            }

            let deletableFetch = PHAsset.fetchAssets(withLocalIdentifiers: deletableIds, options: nil)
            guard deletableFetch.count > 0 else {
                completion(.success(.deleted(requestedIds)))
                return
            }

            let lock = NSLock()
            var hasCompleted = false
            var didObserveSystemDialog = false
            var resignObserver: NSObjectProtocol?

            let finishOnce: (Result<PhotoDeleteOutcome, Error>) -> Void = { result in
                lock.lock()
                if hasCompleted {
                    lock.unlock()
                    return
                }
                hasCompleted = true
                let observerToRemove = resignObserver
                resignObserver = nil
                lock.unlock()

                DispatchQueue.main.async {
                    if let observerToRemove {
                        NotificationCenter.default.removeObserver(observerToRemove)
                    }
                    completion(result)
                }
            }

            resignObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                lock.lock()
                didObserveSystemDialog = true
                lock.unlock()
            }

            // Watchdog: if iOS never presented the native sheet within 8s while staying active,
            // surface a clear diagnostic instead of leaving the user waiting silently.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                lock.lock()
                let alreadyDone = hasCompleted
                let dialogShown = didObserveSystemDialog
                lock.unlock()

                guard !alreadyDone else { return }
                let isActive = (UIApplication.shared.applicationState == .active)
                guard !dialogShown && isActive else { return }

                let firstAsset = deletableFetch.firstObject
                let srcVal = firstAsset?.sourceType.rawValue ?? 0
                let sizeStr = firstAsset.map { "\($0.pixelWidth)x\($0.pixelHeight)" } ?? "?"
                let diag = "iOS did not pop up the system Delete dialog within 8s (Auth: \(Self.authLabel(authStatus)), Deletable: \(deletableIds.count)/\(initialFetch.count), Asset: \(sizeStr) src=\(srcVal)). Check Settings -> photoHub -> Photos (Full Access), Screen Time -> Content & Privacy Restrictions -> Photos, or restart iPhone if photolibraryd stalled."
                finishOnce(.failure(PhotoLibraryError.proxyReplacementFailed(diag)))
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(deletableFetch)
            }, completionHandler: { deleteSuccess, deleteError in
                DispatchQueue.main.async {
                    let remaining = PHAsset.fetchAssets(withLocalIdentifiers: deletableIds, options: nil)
                    if deleteSuccess && remaining.count == 0 {
                        finishOnce(.success(.deleted(deletableIds)))
                        return
                    }

                    lock.lock()
                    let dialogShown = didObserveSystemDialog
                    lock.unlock()

                    if let nsErr = deleteError as NSError? {
                        if nsErr.domain == PHPhotosErrorDomain && nsErr.code == PHPhotosError.Code.userCancelled.rawValue {
                            finishOnce(.success(.cancelledByUser))
                            return
                        }
                        let detail = "\(nsErr.localizedDescription) [\(nsErr.domain):\(nsErr.code)] (Auth: \(Self.authLabel(authStatus)), DialogShown: \(dialogShown), Deletable: \(deletableIds.count))"
                        finishOnce(.failure(PhotoLibraryError.proxyReplacementFailed(detail)))
                    } else if !deleteSuccess && dialogShown {
                        finishOnce(.success(.cancelledByUser))
                    } else if !deleteSuccess {
                        let detail = "iOS declined deletion without presenting a confirmation dialog (Auth: \(Self.authLabel(authStatus)), Deletable: \(deletableIds.count)/\(initialFetch.count)). Check Settings -> photoHub -> Photos -> Full Access and Screen Time restrictions."
                        finishOnce(.failure(PhotoLibraryError.proxyReplacementFailed(detail)))
                    } else {
                        let detail = "Delete completed, but \(remaining.count) asset(s) still remain in Photos (Auth: \(Self.authLabel(authStatus)))."
                        finishOnce(.failure(PhotoLibraryError.proxyReplacementFailed(detail)))
                    }
                }
            })
        }

        if Thread.isMainThread {
            startDeleteOnMain()
        } else {
            DispatchQueue.main.async(execute: startDeleteOnMain)
        }
    }

    static func currentReadWriteAuthLabel() -> String {
        authLabel(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    static func canWriteToPhotosLibrary() -> Bool {
        let rw = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if rw == .authorized || rw == .limited {
            return true
        }
        return PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
    }

    static func requestWriteAuthorizationAsync() async -> Bool {
        if canWriteToPhotosLibrary() {
            return true
        }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status == .authorized || status == .limited)
            }
        }
    }

    /// Saves a server-backed compressed proxy (JPEG/HEIC image or MP4 video) into Apple Photos,
    /// preserving original creation date and registering its asset ID in `LocalProxyTracker.shared`
    /// so it is never re-uploaded and can always be resolved back to its server master for Share Original.
    static func saveServerProxyToPhotosAsync(
        photo: ServerPhoto,
        imageData: Data? = nil,
        videoURL: URL? = nil
    ) async throws -> String {
        if photo.isVideo && videoURL == nil && imageData == nil {
            throw PhotoLibraryError.proxyReplacementFailed("Missing video proxy file to save.")
        }
        if !photo.isVideo && imageData == nil {
            throw PhotoLibraryError.proxyReplacementFailed("Missing image proxy data to save.")
        }

        let targetCreationDate = photo.parsedCreationDate
        var tempTaggedURL: URL?
        if photo.isVideo, let videoURL {
            tempTaggedURL = ProxyGenerator.writeTaggedVideoCopy(from: videoURL, masterHash: photo.hash)
        } else if let imageData {
            tempTaggedURL = ProxyGenerator.writeTaggedProxyImageData(imageData, masterHash: photo.hash)
        }

        let resolvedFileURL = tempTaggedURL

        return try await withCheckedThrowingContinuation { continuation in
            var createdLocalId: String?
            PHPhotoLibrary.shared().performChanges({
                let createRequest: PHAssetChangeRequest?
                if photo.isVideo, let targetVideoURL = resolvedFileURL ?? videoURL {
                    createRequest = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: targetVideoURL)
                } else if let targetImageURL = resolvedFileURL,
                          let fileReq = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: targetImageURL) {
                    createRequest = fileReq
                } else if let imageData {
                    if let img = UIImage(data: imageData) {
                        createRequest = PHAssetChangeRequest.creationRequestForAsset(from: img)
                    } else {
                        let req = PHAssetCreationRequest.forAsset()
                        req.addResource(with: .photo, data: imageData, options: nil)
                        createRequest = req
                    }
                } else {
                    createRequest = nil
                }

                createRequest?.creationDate = targetCreationDate
                createdLocalId = createRequest?.placeholderForCreatedAsset?.localIdentifier
            }, completionHandler: { success, error in
                ProxyGenerator.cleanupTempFile(resolvedFileURL)
                if success {
                    if let createdLocalId, !createdLocalId.isEmpty {
                        LocalProxyTracker.shared.markAsProxy(
                            assetId: createdLocalId,
                            proxySha256: photo.proxyHash ?? "",
                            masterHash: photo.hash,
                            originalName: photo.originalName
                        )
                    } else {
                        LocalProxyTracker.shared.markMasterHandledForPhotos(photo.hash)
                    }
                    continuation.resume(returning: createdLocalId ?? "")
                } else {
                    let message = error?.localizedDescription ?? "Could not save proxy to iPhone Photos."
                    continuation.resume(throwing: PhotoLibraryError.proxyReplacementFailed(message))
                }
            })
        }
    }

    /// Saves a full-resolution restored original (photo or video) back into Apple Photos,
    /// preserving original filename and creation timestamp.
    static func saveRestoredOriginalToPhotosAsync(
        photo: ServerPhoto,
        fileURL: URL
    ) async throws -> String {
        try await saveRestoredOriginalToPhotosAsync(
            isVideo: photo.isVideo,
            originalFilename: photo.originalName,
            creationDate: photo.parsedCreationDate,
            fileURL: fileURL
        )
    }

    static func saveRestoredOriginalToPhotosAsync(
        isVideo: Bool,
        originalFilename: String,
        creationDate: Date?,
        fileURL: URL
    ) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            var placeholderId: String?
            PHPhotoLibrary.shared().performChanges({
                let request: PHAssetChangeRequest?
                if isVideo {
                    request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                } else {
                    let creationReq = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = originalFilename
                    creationReq.addResource(with: .photo, fileURL: fileURL, options: options)
                    request = creationReq
                }
                request?.creationDate = creationDate
                placeholderId = request?.placeholderForCreatedAsset?.localIdentifier
            }) { success, error in
                if success {
                    continuation.resume(returning: placeholderId ?? "")
                } else {
                    let msg = error?.localizedDescription ?? "Unknown error"
                    continuation.resume(throwing: PhotoLibraryError.proxyReplacementFailed(msg))
                }
            }
        }
    }

    /// Downloads the master original for `photo`, saves it into Apple Photos (optionally throttled
    /// via `photoWriteSemaphore` for batch jobs), marks it restored locally, and protects it on the server.
    static func restoreMasterToPhotos(
        photo: ServerPhoto,
        client: PhotoHubAPIClient,
        photoWriteSemaphore: AsyncSemaphore? = nil
    ) async throws -> (updatedPhoto: ServerPhoto?, savedBytes: Int64) {
        let tempURL = try await client.downloadMasterToTempFile(
            hash: photo.hash,
            preferredFilename: photo.originalName
        )
        defer {
            let parent = tempURL.deletingLastPathComponent()
            if parent.lastPathComponent.hasPrefix("photohub_share_") {
                try? FileManager.default.removeItem(at: parent)
            } else {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        let fileSize = (try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? photo.size
        if let sem = photoWriteSemaphore {
            await sem.acquire()
        }
        let createdLocalId: String
        do {
            createdLocalId = try await saveRestoredOriginalToPhotosAsync(photo: photo, fileURL: tempURL)
            if let sem = photoWriteSemaphore {
                await sem.release()
            }
        } catch {
            if let sem = photoWriteSemaphore {
                await sem.release()
            }
            throw error
        }

        // Record both locally (asset ID + hash) and on the server so auto-cleanup won't re-compress it.
        LocalProxyTracker.shared.markRestoredOriginal(
            assetId: createdLocalId.isEmpty ? nil : createdLocalId,
            masterHash: photo.hash
        )
        let updated = try? await client.setOriginalProtected(masterHash: photo.hash, protected: true)
        return (updated, fileSize)
    }

    func testDeletePromptOnLatestAsset(completion: @escaping (String) -> Void) {
        requestAuthorization { status in
            let authText = Self.authLabel(status)
            guard status == .authorized || status == .limited else {
                completion("Auth is \(authText). Change Settings -> photoHub -> Photos to Full Access.")
                return
            }

            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            opts.fetchLimit = 1
            let latest = PHAsset.fetchAssets(with: .image, options: opts)
            guard let asset = latest.firstObject else {
                completion("Auth: \(authText), but no photos found in library.")
                return
            }

            let info = "Auth=\(authText), Size=\(asset.pixelWidth)x\(asset.pixelHeight), CanDelete=\(asset.canPerform(.delete)), Src=\(asset.sourceType.rawValue)"
            self.deleteOriginalAssets([asset]) { result in
                switch result {
                case .success(.deleted(let ids)):
                    completion("Prompt appeared and deleted \(ids.count) item(s)! (\(info))")
                case .success(.cancelledByUser):
                    completion("Native iOS Delete prompt DID appear! (User tapped Don't Allow; \(info))")
                case .failure(let error):
                    completion("Failed (\(info)): \(error.localizedDescription)")
                }
            }
        }
    }

    private static func authLabel(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Full Access"
        case .limited: return "Limited Access"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Determined"
        @unknown default: return "Unknown(\(status.rawValue))"
        }
    }

    private static func pickOriginalResource(from resources: [PHAssetResource]) -> PHAssetResource? {
        resources.first(where: { $0.type == .photo || $0.type == .video })
            ?? resources.first(where: { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo })
            ?? resources.first
    }
}

struct OriginalShareInput: Sendable {
    let assetId: String?
    let fileURL: URL?
    let filenameHint: String?
    let masterHashHint: String?
    let isVideo: Bool

    var displayName: String {
        if let hint = filenameHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            return URL(fileURLWithPath: hint).lastPathComponent
        }
        if let urlName = fileURL?.lastPathComponent, !urlName.isEmpty {
            return urlName
        }
        if let hash = masterHashHint, !hash.isEmpty {
            return "original_\(String(hash.prefix(8)))"
        }
        return isVideo ? "Video" : "Photo"
    }
}

struct ResolvedOriginalDownload: Identifiable, Sendable {
    let id = UUID()
    let masterHash: String
    let fileURL: URL
    let originalName: String
    let sizeBytes: Int64
    let isVideo: Bool
}

private enum BatchOriginalFetchItemOutcome: Sendable {
    case resolved(index: Int, download: ResolvedOriginalDownload)
    case unresolved(index: Int, input: OriginalShareInput, errorMessage: String?)
    case authExpired
}

enum OriginalMediaResolver {
    static func resolveMaster(
        input: OriginalShareInput,
        cachedPhotos: [ServerPhoto],
        client: PhotoHubAPIClient
    ) async throws -> (masterHash: String, originalName: String?)? {
        // 1. Explicit masterHash / prefix query parameter
        if let hint = input.masterHashHint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter({ $0.isHexDigit }),
           hint.count >= 8 {
            if hint.count == 64 {
                let name = cachedPhotos.first(where: { $0.hash.lowercased() == hint })?.originalName
                return (hint, name ?? input.filenameHint)
            }
            if let match = try await matchPrefix(hint, cachedPhotos: cachedPhotos, client: client) {
                return (match.hash, match.originalName)
            }
        }

        // 2. Local tracker lookup + Photos PHAssetResource metadata (zero iCloud download)
        if let assetId = input.assetId, !assetId.isEmpty {
            if let tracked = LocalProxyTracker.shared.masterLookup(forAssetId: assetId) {
                let fallbackName = cachedPhotos.first(where: {
                    $0.hash.caseInsensitiveCompare(tracked.masterHash) == .orderedSame
                })?.originalName
                return (tracked.masterHash, tracked.originalName ?? fallbackName)
            }

            let rwAuth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if rwAuth == .authorized || rwAuth == .limited,
               let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject,
               let proxyMatch = PhotoLibraryService.proxyHashPrefixFromAssetResources(asset) {
                if let match = try await matchPrefix(proxyMatch.prefix, cachedPhotos: cachedPhotos, client: client) {
                    return (match.hash, match.originalName)
                }
            }
        }

        // 3. Filename prefix PHOTOHUB_PROXY_<prefix16>
        let nameCandidates = [input.filenameHint, input.fileURL?.lastPathComponent].compactMap { $0 }
        for rawName in nameCandidates {
            if let prefix = ProxyGenerator.extractMasterHashPrefix(fromProxyFilename: rawName),
               let match = try await matchPrefix(prefix, cachedPhotos: cachedPhotos, client: client) {
                return (match.hash, match.originalName)
            }
        }

        // 4. Embedded EXIF UserComment / TIFF ImageDescription / MP4 QuickTime udta PhotoHubProxy:<hash>
        if let fileURL = input.fileURL {
            if let embedded = await ProxyGenerator.extractEmbeddedProxyMasterHash(
                fromFileURL: fileURL,
                isVideo: input.isVideo
            ) {
                let norm = embedded.lowercased()
                if norm.count == 64 {
                    let match = cachedPhotos.first(where: { $0.hash.lowercased() == norm })
                    return (match?.hash ?? norm, match?.originalName ?? input.filenameHint)
                } else if let match = try await matchPrefix(norm, cachedPhotos: cachedPhotos, client: client) {
                    return (match.hash, match.originalName)
                }
            }

            // 5. Stream SHA-256 -> LocalProxyTracker proxy map / cached server index / GET /api/check/:sha
            let sha = try ProxyGenerator.computeFileSHA256(url: fileURL).lowercased()
            if let knownMaster = LocalProxyTracker.shared.masterHash(forProxySha256: sha) {
                let match = cachedPhotos.first(where: { $0.hash.lowercased() == knownMaster.lowercased() })
                return (knownMaster, match?.originalName ?? input.filenameHint)
            }
            if let cachedByHash = cachedPhotos.first(where: {
                $0.hash.lowercased() == sha || ($0.proxyHash?.lowercased() == sha)
            }) {
                return (cachedByHash.hash, cachedByHash.originalName)
            }

            let check = try await client.checkHash(sha)
            if check.exists {
                let resolved = check.masterHash ?? sha
                let match = cachedPhotos.first(where: { $0.hash.lowercased() == resolved.lowercased() })
                return (resolved, match?.originalName ?? input.filenameHint)
            }
        }

        return nil
    }

    static func resolveAndFetchBatch(
        inputs: [OriginalShareInput],
        settings: AppSettings,
        onProgress: @MainActor @escaping (_ completed: Int, _ total: Int, _ stage: String) -> Void
    ) async -> (
        resolved: [ResolvedOriginalDownload],
        unresolved: [OriginalShareInput],
        errorMessage: String?,
        authExpired: Bool
    ) {
        let client = PhotoHubAPIClient(settings: settings)
        let cachedPhotos = LocalProxyStore.shared.cachedPhotos(
            baseURL: settings.normalizedBaseURL,
            apiKey: settings.apiKey
        )
        let indexed = inputs.enumerated().map { (index: $0.offset, input: $0.element) }
        let queue = AsyncWorkQueue(indexed)
        let workerCount = min(3, max(1, indexed.count))

        var outcomes: [BatchOriginalFetchItemOutcome] = []
        var completed = 0
        var sawAuthExpired = false

        await withTaskGroup(of: BatchOriginalFetchItemOutcome?.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    await fetchNextItem(queue: queue, cachedPhotos: cachedPhotos, client: client)
                }
            }

            for await outcome in group {
                guard let outcome else { continue }
                outcomes.append(outcome)
                completed += 1
                if case .authExpired = outcome {
                    sawAuthExpired = true
                }
                let stageLabel = indexed.count > 1
                    ? "Prepared \(completed) of \(indexed.count) item(s)..."
                    : "Downloading original from server..."
                await onProgress(completed, indexed.count, stageLabel)

                if !Task.isCancelled && !sawAuthExpired {
                    group.addTask {
                        await fetchNextItem(queue: queue, cachedPhotos: cachedPhotos, client: client)
                    }
                }
            }
        }

        if sawAuthExpired {
            return ([], inputs, "Session expired. Please sign in again.", true)
        }

        var resolvedPairs: [(Int, ResolvedOriginalDownload)] = []
        var unresolvedPairs: [(Int, OriginalShareInput)] = []
        var firstError: String?

        for item in outcomes {
            switch item {
            case .resolved(let idx, let download):
                resolvedPairs.append((idx, download))
            case .unresolved(let idx, let input, let err):
                unresolvedPairs.append((idx, input))
                if firstError == nil, let err, !err.isEmpty {
                    firstError = err
                }
            case .authExpired:
                break
            }
        }

        resolvedPairs.sort { $0.0 < $1.0 }
        unresolvedPairs.sort { $0.0 < $1.0 }
        return (
            resolvedPairs.map(\.1),
            unresolvedPairs.map(\.1),
            firstError,
            false
        )
    }

    private static func matchPrefix(
        _ prefix: String,
        cachedPhotos: [ServerPhoto],
        client: PhotoHubAPIClient
    ) async throws -> ServerPhoto? {
        if let localMatch = cachedPhotos.first(where: { $0.hash.lowercased().hasPrefix(prefix.lowercased()) }) {
            return localMatch
        }
        return try? await client.lookupPhotoByHashPrefix(prefix)
    }

    private static func fetchNextItem(
        queue: AsyncWorkQueue<(index: Int, input: OriginalShareInput)>,
        cachedPhotos: [ServerPhoto],
        client: PhotoHubAPIClient
    ) async -> BatchOriginalFetchItemOutcome? {
        guard !Task.isCancelled, let work = await queue.next() else {
            return nil
        }
        let input = work.input
        do {
            guard let resolved = try await resolveMaster(
                input: input,
                cachedPhotos: cachedPhotos,
                client: client
            ) else {
                return .unresolved(
                    index: work.index,
                    input: input,
                    errorMessage: "Not linked to an uploaded PhotoHub original on the server."
                )
            }

            let tempMasterURL = try await client.downloadMasterToTempFile(
                hash: resolved.masterHash,
                preferredFilename: resolved.originalName
            )
            let attrs = try? FileManager.default.attributesOfItem(atPath: tempMasterURL.path)
            let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let trimmedPreferred = resolved.originalName?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let finalName = trimmedPreferred.isEmpty ? tempMasterURL.lastPathComponent : trimmedPreferred
            let ext = tempMasterURL.pathExtension.lowercased()
            let isVid = input.isVideo || ["mp4", "mov", "m4v", "3gp", "avi"].contains(ext)

            return .resolved(
                index: work.index,
                download: ResolvedOriginalDownload(
                    masterHash: resolved.masterHash,
                    fileURL: tempMasterURL,
                    originalName: finalName,
                    sizeBytes: bytes,
                    isVideo: isVid
                )
            )
        } catch APIClientError.httpError(401, _) {
            return .authExpired
        } catch {
            return .unresolved(
                index: work.index,
                input: input,
                errorMessage: error.localizedDescription
            )
        }
    }
}
