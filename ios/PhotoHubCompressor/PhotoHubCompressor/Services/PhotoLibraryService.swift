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
                    creationDate: asset.creationDate
                )

                candidates.append(candidate)
            }
        }

        return candidates
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
            for i in 0..<initialFetch.count {
                let asset = initialFetch.object(at: i)
                if asset.canPerform(.delete) {
                    deletableIds.append(asset.localIdentifier)
                }
            }

            guard !deletableIds.isEmpty else {
                let detail: String
                if authStatus == .limited {
                    detail = "Photos access is set to Limited Access, which blocks deleting originals. Open iOS Settings -> photoHub -> Photos and choose Full Access."
                } else {
                    detail = "iOS reports \(initialFetch.count) photo(s) cannot be deleted by apps (canPerform(.delete) == false). They may be synced from a computer, in a Shared Album, or restricted by Screen Time."
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

            // Watchdog: if iOS never presented the native sheet within 15s while staying active,
            // surface a clear diagnostic instead of leaving the UI stuck.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
                lock.lock()
                let alreadyDone = hasCompleted
                let dialogShown = didObserveSystemDialog
                lock.unlock()

                guard !alreadyDone else { return }
                let isActive = (UIApplication.shared.applicationState == .active)
                guard !dialogShown && isActive else { return }

                let diag = "iOS did not display the Delete confirmation dialog within 15s (Auth: \(Self.authLabel(authStatus)), Deletable: \(deletableIds.count)/\(initialFetch.count)). Ensure Settings -> photoHub -> Photos is Full Access, check Screen Time restrictions, or tap 'Retry Delete Now'."
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
