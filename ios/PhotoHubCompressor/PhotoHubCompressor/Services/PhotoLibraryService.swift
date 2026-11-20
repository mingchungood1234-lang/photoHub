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

    func scanCandidates(tracker: LocalProxyTracker) -> [PhotoCandidate] {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: fetchOptions)

        var candidates: [PhotoCandidate] = []
        let totalCount = assets.count
        if totalCount == 0 {
            return []
        }
        candidates.reserveCapacity(min(totalCount, 500))

        for i in 0..<totalCount {
            autoreleasepool {
                let asset = assets.object(at: i)
                let localId = asset.localIdentifier
                if tracker.isKnownProxy(assetId: localId) {
                    return
                }

                let prefixLen = min(8, localId.count)
                let shortId = String(localId.prefix(prefixLen))
                let prefixLabel = asset.mediaType == .video ? "Video" : "Photo"

                let candidate = PhotoCandidate(
                    id: localId,
                    asset: asset,
                    mediaType: asset.mediaType,
                    duration: asset.duration,
                    filename: "\(prefixLabel)_\(shortId)",
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    creationDate: asset.creationDate,
                    estimatedBytes: Self.estimateBytes(for: asset)
                )

                candidates.append(candidate)
            }
        }

        return candidates
    }

    static func estimateBytes(for asset: PHAsset) -> Int64 {
        let pixels = Int64(max(0, asset.pixelWidth)) * Int64(max(0, asset.pixelHeight))
        if asset.mediaType == .video {
            let durationSec = max(1.0, asset.duration)
            let maxDim = max(asset.pixelWidth, asset.pixelHeight)
            let bytesPerSecond: Double
            if maxDim >= 3800 {
                bytesPerSecond = 5_500_000 // ~44 Mbps 4K HEVC/H.264
            } else if maxDim >= 1900 {
                bytesPerSecond = 2_200_000 // ~17 Mbps 1080p
            } else {
                bytesPerSecond = 1_200_000
            }
            return max(8_000_000, Int64(durationSec * bytesPerSecond))
        }
        return max(1_500_000, pixels / 4)
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

        let preloadedImage: UIImage? = (mediaType == .image) ? UIImage(contentsOfFile: proxyFileURL.path) : nil
        var createdLocalIdentifier: String?

        PHPhotoLibrary.shared().performChanges({
            let createRequest: PHAssetChangeRequest?
            if mediaType == .video {
                createRequest = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: proxyFileURL)
            } else if let img = preloadedImage {
                createRequest = PHAssetChangeRequest.creationRequestForAsset(from: img)
            } else {
                createRequest = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: proxyFileURL)
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

        return try await withCheckedThrowingContinuation { continuation in
            var createdLocalId: String?
            PHPhotoLibrary.shared().performChanges({
                let createRequest: PHAssetChangeRequest?
                if photo.isVideo, let videoURL {
                    createRequest = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
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
