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

    /// Step 2: Must be called synchronously inside a direct SwiftUI `Button` tap action on the main thread
    /// so iOS 18 preserves the active UIEvent user-interaction token and displays the system Delete confirmation alert.
    func deleteOriginalAssetsFromUserTap(
        _ assets: [PHAsset],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let ids = assets.map { $0.localIdentifier }
        guard !ids.isEmpty else {
            completion(.success(()))
            return
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard fetchResult.count > 0 else {
            completion(.success(()))
            return
        }

        // Call performChanges synchronously on the current (main) thread within the user's Button tap event
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(fetchResult)
        }, completionHandler: { deleteSuccess, deleteError in
            DispatchQueue.main.async {
                if deleteSuccess {
                    completion(.success(()))
                } else {
                    let nsErr = deleteError as NSError?
                    let detail = nsErr.map { "\($0.localizedDescription) [\($0.domain):\($0.code)]" }
                        ?? "Delete confirmation was cancelled or denied by iOS."
                    completion(.failure(PhotoLibraryError.proxyReplacementFailed(detail)))
                }
            }
        })
    }

    private static func pickOriginalResource(from resources: [PHAssetResource]) -> PHAssetResource? {
        resources.first(where: { $0.type == .photo || $0.type == .video })
            ?? resources.first(where: { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo })
            ?? resources.first
    }
}
