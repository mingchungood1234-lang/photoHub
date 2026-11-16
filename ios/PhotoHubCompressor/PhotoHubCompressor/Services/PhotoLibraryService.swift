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
    func requestAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited {
            return current
        }
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func scanCandidates(
        tracker: LocalProxyTracker
    ) -> [PhotoCandidate] {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)

        var candidates: [PhotoCandidate] = []
        candidates.reserveCapacity(assets.count)

        assets.enumerateObjects { asset, _, _ in
            autoreleasepool {
                let shortId = String(asset.localIdentifier.prefix(8))
                var candidate = PhotoCandidate(
                    id: asset.localIdentifier,
                    asset: asset,
                    filename: "Photo_\(shortId)",
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    creationDate: asset.creationDate
                )

                if tracker.isKnownProxy(assetId: asset.localIdentifier) {
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
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast

            let lock = NSLock()
            var hasResumed = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: image)
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
            PHAssetResourceManager.default().writeData(for: resource, toFile: tempURL, options: options) { error in
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
    /// and deletes the heavy original in the same atomic PhotoKit transaction.
    func replaceWithProxy(originalAsset: PHAsset, proxyFileURL: URL) async throws -> String {
        var createdLocalIdentifier: String?

        try await PHPhotoLibrary.shared().performChanges {
            let createRequest = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: proxyFileURL)
            createRequest?.creationDate = originalAsset.creationDate
            createRequest?.location = originalAsset.location
            createRequest?.isFavorite = originalAsset.isFavorite
            createdLocalIdentifier = createRequest?.placeholderForCreatedAsset?.localIdentifier

            PHAssetChangeRequest.deleteAssets([originalAsset] as NSArray)
        }

        return createdLocalIdentifier ?? originalAsset.localIdentifier
    }

    private static func pickOriginalResource(from resources: [PHAssetResource]) -> PHAssetResource? {
        resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first
    }
}
