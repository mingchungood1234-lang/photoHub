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
                // Skip photos/videos that have already been compressed into local proxies
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

    /// Creates the lightweight proxy in the native Photos library (preserving date, GPS, and favorite status)
    /// and deletes the heavy original in the same atomic PhotoKit transaction (exact proven implementation from e2c7312).
    func replaceWithProxy(
        originalAsset: PHAsset,
        mediaType: PHAssetMediaType,
        proxyFileURL: URL,
        keepLocalProxy: Bool = true
    ) async throws -> String {
        var createdLocalIdentifier: String?

        try await PHPhotoLibrary.shared().performChanges {
            if keepLocalProxy {
                let createRequest = (mediaType == .video)
                    ? PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: proxyFileURL)
                    : PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: proxyFileURL)
                createRequest?.creationDate = originalAsset.creationDate
                createRequest?.location = originalAsset.location
                createRequest?.isFavorite = originalAsset.isFavorite
                createdLocalIdentifier = createRequest?.placeholderForCreatedAsset?.localIdentifier
            }

            PHAssetChangeRequest.deleteAssets([originalAsset] as NSArray)
        }

        return createdLocalIdentifier ?? originalAsset.localIdentifier
    }

    private static func pickOriginalResource(from resources: [PHAssetResource]) -> PHAssetResource? {
        resources.first(where: { $0.type == .photo || $0.type == .video })
            ?? resources.first(where: { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo })
            ?? resources.first
    }
}
