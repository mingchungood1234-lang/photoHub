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
            return "Failed to replace photo in Photos library: \(msg)"
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

    func scanCandidates(
        tracker: LocalProxyTracker
    ) -> [PhotoCandidate] {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)

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
                // Skip photos that have already been compressed into local proxies
                if tracker.isKnownProxy(assetId: localId) {
                    return
                }

                let prefixLen = min(8, localId.count)
                let shortId = String(localId.prefix(prefixLen))

                let candidate = PhotoCandidate(
                    id: localId,
                    asset: asset,
                    filename: "Photo_\(shortId)",
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    creationDate: asset.creationDate
                )

                candidates.append(candidate)
            }
        }

        return candidates
    }

    func loadThumbnail(for asset: PHAsset, targetSize: CGSize = CGSize(width: 160, height: 160)) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            options.isSynchronous = false

            var hasResumed = false
            let lock = NSLock()

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }

                if let image = image {
                    hasResumed = true
                    continuation.resume(returning: image)
                } else if info?[PHImageErrorKey] != nil || (info?[PHImageCancelledKey] as? Bool) == true {
                    hasResumed = true
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func exportOriginalMaster(for asset: PHAsset) async throws -> ExportedMaster {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = Self.pickOriginalResource(from: resources) else {
            throw PhotoLibraryError.noOriginalResourceFound
        }

        let ext = (resource.originalFilename as NSString).pathExtension
        let safeExt = ext.isEmpty ? "heic" : ext
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("master_\(UUID().uuidString).\(safeExt)")

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var hasResumed = false
            PHAssetResourceManager.default().writeData(for: resource, toFile: tempURL, options: options) { error in
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                if let error {
                    try? FileManager.default.removeItem(at: tempURL)
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        let sizeBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let sha256 = try ProxyGenerator.computeFileSHA256(url: tempURL)
        let mimeType = UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream"

        return ExportedMaster(
            fileURL: tempURL,
            sha256: sha256,
            sizeBytes: sizeBytes,
            filename: resource.originalFilename,
            mimeType: mimeType
        )
    }

    struct PendingProxyReplacement {
        let originalAsset: PHAsset
        let proxyData: Data
        let proxySha256: String
        let savedBytes: Int64
    }

    /// Performs PhotoKit deletion (and optional proxy creation) using plain completion handlers
    /// (NO async/await continuation) so the MainActor runloop is completely free to display the iOS Delete confirmation alert.
    func performBatchDeleteAndOptionalProxySave(
        items: [PendingProxyReplacement],
        keepLocalProxy: Bool,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        guard !items.isEmpty else {
            DispatchQueue.main.async { completion(.success([])) }
            return
        }

        let identifiers = items.map { $0.originalAsset.localIdentifier }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)

        guard fetchResult.count > 0 else {
            DispatchQueue.main.async { completion(.success([])) }
            return
        }

        // Step 1: Delete original assets first using fresh PHFetchResult
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(fetchResult)
        }, completionHandler: { deleteSuccess, deleteError in
            guard deleteSuccess else {
                let nsErr = deleteError as NSError?
                let detail = nsErr.map { "\($0.localizedDescription) [\($0.domain):\($0.code)]" }
                    ?? "Photo deletion was cancelled or denied."
                DispatchQueue.main.async {
                    completion(.failure(PhotoLibraryError.proxyReplacementFailed(detail)))
                }
                return
            }

            // If user does not want a duplicate/proxy copy added back to iPhone Photos, we are done!
            guard keepLocalProxy else {
                DispatchQueue.main.async {
                    completion(.success([]))
                }
                return
            }

            // Step 2: Save lightweight proxy assets in a separate performChanges call after deletion succeeded
            var createdIds: [String] = []
            PHPhotoLibrary.shared().performChanges({
                for item in items {
                    let creationRequest = PHAssetCreationRequest.forAsset()
                    creationRequest.addResource(with: .photo, data: item.proxyData, options: nil)
                    creationRequest.creationDate = item.originalAsset.creationDate
                    creationRequest.location = item.originalAsset.location
                    creationRequest.isFavorite = item.originalAsset.isFavorite
                    if let id = creationRequest.placeholderForCreatedAsset?.localIdentifier {
                        createdIds.append(id)
                    }
                }
            }, completionHandler: { _, _ in
                DispatchQueue.main.async {
                    completion(.success(createdIds))
                }
            })
        })
    }

    private static func pickOriginalResource(from resources: [PHAssetResource]) -> PHAssetResource? {
        resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first
    }
}
