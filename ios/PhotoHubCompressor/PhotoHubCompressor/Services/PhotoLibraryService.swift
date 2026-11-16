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
                let prefixLen = min(8, localId.count)
                let shortId = String(localId.prefix(prefixLen))

                var candidate = PhotoCandidate(
                    id: localId,
                    asset: asset,
                    filename: "Photo_\(shortId)",
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    creationDate: asset.creationDate
                )

                if tracker.isKnownProxy(assetId: localId) {
                    candidate.state = .alreadyProxy
                    candidate.isSelected = false
                }

                candidates.append(candidate)
            }
        }

        return candidates
    }

    func loadThumbnail(for asset: PHAsset, targetSize: CGSize = CGSize(width: 160, height: 160)) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
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
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                // Only return when we have an image or when request is complete
                lock.lock()
                defer { lock.unlock() }
                if !hasResumed {
                    if let image = image, !isDegraded {
                        hasResumed = true
                        continuation.resume(returning: image)
                    } else if image != nil && hasResumed == false {
                        // Keep waiting for non-degraded, unless error or cancelled
                        let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                        let error = info?[PHImageErrorKey] as? Error
                        if isCancelled || error != nil {
                            hasResumed = true
                            continuation.resume(returning: image)
                        }
                    } else if info?[PHImageErrorKey] != nil || (info?[PHImageCancelledKey] as? Bool) == true {
                        hasResumed = true
                        continuation.resume(returning: nil)
                    }
                }
            }

            // Safety timeout to ensure continuation ALWAYS resumes even if PhotoKit drops callback
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
                lock.lock()
                defer { lock.unlock() }
                if !hasResumed {
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

    /// Step 1: Saves the lightweight proxy in the native Photos library using in-memory Data
    /// (avoids cross-process sandbox file deadlocks with photolibraryd).
    func saveProxyAsset(originalAsset: PHAsset, proxyFileURL: URL) async throws -> String {
        let proxyData = try Data(contentsOf: proxyFileURL)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let lock = NSLock()
            var hasResumed = false
            var placeholderId: String?

            PHPhotoLibrary.shared().performChanges({
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, data: proxyData, options: nil)
                creationRequest.creationDate = originalAsset.creationDate
                creationRequest.location = originalAsset.location
                creationRequest.isFavorite = originalAsset.isFavorite
                placeholderId = creationRequest.placeholderForCreatedAsset?.localIdentifier
            }, completionHandler: { success, error in
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true

                if success {
                    continuation.resume(returning: placeholderId ?? originalAsset.localIdentifier)
                } else {
                    let msg = error?.localizedDescription ?? "Could not save compressed proxy to Photos."
                    continuation.resume(throwing: PhotoLibraryError.proxyReplacementFailed(msg))
                }
            })
        }
    }

    /// Step 2: Requests iOS to delete the heavy original asset(s) in a separate transaction
    /// so iOS presents the native "Allow photoHub to delete photo(s)?" prompt cleanly without hanging.
    func deleteOriginalAssets(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var hasResumed = false

            DispatchQueue.main.async {
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.deleteAssets(assets as NSArray)
                }, completionHandler: { success, error in
                    lock.lock()
                    defer { lock.unlock() }
                    guard !hasResumed else { return }
                    hasResumed = true

                    if success {
                        continuation.resume(returning: ())
                    } else {
                        let msg = error?.localizedDescription ?? "Original deletion was cancelled or denied."
                        continuation.resume(throwing: PhotoLibraryError.proxyReplacementFailed(msg))
                    }
                })
            }
        }
    }

    private static func pickOriginalResource(from resources: [PHAssetResource]) -> PHAssetResource? {
        resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first
    }
}
