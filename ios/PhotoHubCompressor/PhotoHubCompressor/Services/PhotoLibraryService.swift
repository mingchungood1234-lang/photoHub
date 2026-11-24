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

    enum CompressedProxyDeleteResult: Sendable {
        case deleted(Int)
        case cancelledByUser
        case noPermission
        case failed(String)
    }

    /// Scans local Photos metadata (zero iCloud download) for all synced or locally created
    /// `PHOTOHUB_PROXY_<prefix>` assets, returning `prefix16 -> [PHAsset.localIdentifier]`.
    static func scanAllProxyPrefixesInPhotos() -> [String: [String]] {
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard auth == .authorized || auth == .limited else {
            return [:]
        }
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        let assets = PHAsset.fetchAssets(with: fetchOptions)
        var map: [String: [String]] = [:]
        for i in 0..<assets.count {
            autoreleasepool {
                let asset = assets.object(at: i)
                if let match = proxyHashPrefixFromAssetResources(asset) {
                    map[match.prefix, default: []].append(asset.localIdentifier)
                }
            }
        }
        return map
    }

    /// Scans local Photos metadata (zero iCloud download) for any synced or locally created
    /// `PHOTOHUB_PROXY_<prefix>` assets, returning `prefix16 -> PHAsset.localIdentifier`.
    static func scanExistingProxyPrefixesInPhotos() -> [String: String] {
        scanAllProxyPrefixesInPhotos().compactMapValues { $0.first }
    }

    /// Finds live compressed proxy `PHAsset`s in Apple Photos matching the provided master hashes,
    /// strictly excluding any restored full-resolution original assets.
    static func findCompressedProxyAssets(forMasterHashes hashes: Set<String>) -> [PHAsset] {
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard auth == .authorized || auth == .limited else {
            return []
        }

        let normHashes = Set(
            hashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !normHashes.isEmpty else { return [] }

        let tracker = LocalProxyTracker.shared
        var candidateIds = Set(tracker.trackedProxyAssetIds(forMasterHashes: normHashes))

        let targetPrefixes = Set(
            normHashes.map { ProxyGenerator.proxyPrefixTag(forMasterHash: $0) }
                .filter { $0.count >= 8 }
        )
        if !targetPrefixes.isEmpty {
            let prefixMap = scanAllProxyPrefixesInPhotos()
            for prefix in targetPrefixes {
                if let ids = prefixMap[prefix] {
                    candidateIds.formUnion(ids)
                }
            }
        }

        let filteredIds = candidateIds.filter { !tracker.isRestoredOriginal(assetId: $0) }
        guard !filteredIds.isEmpty else { return [] }

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: Array(filteredIds), options: nil)
        var verified: [PHAsset] = []
        verified.reserveCapacity(fetch.count)
        for i in 0..<fetch.count {
            let asset = fetch.object(at: i)
            let localId = asset.localIdentifier
            guard !tracker.isRestoredOriginal(assetId: localId) else { continue }
            if tracker.isKnownProxy(assetId: localId) || proxyHashPrefixFromAssetResources(asset) != nil {
                verified.append(asset)
            }
        }
        return verified
    }

    /// Presents one native iOS Photos confirmation dialog to delete all verified compressed proxies
    /// corresponding to successfully restored originals, and clears their proxy tracker entries.
    static func deleteCompressedProxyAssets(forMasterHashes hashes: Set<String>) async -> CompressedProxyDeleteResult {
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard auth == .authorized || auth == .limited else {
            return .noPermission
        }

        let assetIds = await Task.detached(priority: .userInitiated) {
            PhotoLibraryService.findCompressedProxyAssets(forMasterHashes: hashes).map(\.localIdentifier)
        }.value

        guard !assetIds.isEmpty else {
            return .deleted(0)
        }

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetched.count)
        for i in 0..<fetched.count {
            assets.append(fetched.object(at: i))
        }
        guard !assets.isEmpty else {
            return .deleted(0)
        }

        return await withCheckedContinuation { continuation in
            PhotoLibraryService().deleteOriginalAssets(assets) { result in
                switch result {
                case .success(.deleted(let deletedIds)):
                    LocalProxyTracker.shared.clearProxyMappings(assetIds: deletedIds)
                    continuation.resume(returning: .deleted(deletedIds.count))
                case .success(.cancelledByUser):
                    continuation.resume(returning: .cancelledByUser)
                case .failure(PhotoLibraryError.permissionDenied):
                    continuation.resume(returning: .noPermission)
                case .failure(let error):
                    continuation.resume(returning: .failed(error.localizedDescription))
                }
            }
        }
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

    static func requestReadWriteAuthorizationAsync() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited {
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
            tempTaggedURL = await ProxyGenerator.writeTaggedVideoCopyAsync(from: videoURL, masterHash: photo.hash)
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
        await client.warmConnectionIfNeeded()
        let tempURL = try await OriginalDownloadCache.shared.getOrFetchShareCopy(
            hash: photo.hash,
            preferredFilename: photo.originalName,
            expectedSizeBytes: photo.size > 0 ? photo.size : nil,
            isVideo: photo.isVideo,
            client: client
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
    let creationDateHint: Date?

    init(
        assetId: String?,
        fileURL: URL?,
        filenameHint: String?,
        masterHashHint: String?,
        isVideo: Bool,
        creationDateHint: Date? = nil
    ) {
        self.assetId = assetId
        self.fileURL = fileURL
        self.filenameHint = filenameHint
        self.masterHashHint = masterHashHint
        self.isVideo = isVideo
        self.creationDateHint = creationDateHint
    }

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

private struct SendableClientBox: @unchecked Sendable {
    let client: PhotoHubAPIClient
}

/// Persistent LRU disk cache + ref-counted single-flight coalescer for downloaded originals.
final class OriginalDownloadCache: @unchecked Sendable {
    static let shared = OriginalDownloadCache()

    private static let maxCacheBytes: Int64 = 400 * 1024 * 1024
    private static let cacheFolderName = "photohub_originals_cache"

    private final class InFlightEntry: @unchecked Sendable {
        let id: UUID
        let task: Task<URL, Error>
        var waiterIDs = Set<UUID>()

        init(id: UUID, task: Task<URL, Error>, waiterID: UUID) {
            self.id = id
            self.task = task
            self.waiterIDs.insert(waiterID)
        }
    }

    private let lock = NSLock()
    private var inFlight: [String: InFlightEntry] = [:]
    private var entryCallbacks: [UUID: [UUID: @Sendable (Int64, Int64?) -> Void]] = [:]

    private init() {}

    private var cacheRootDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(Self.cacheFolderName, isDirectory: true)
    }

    private static func normalizeHash(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private func itemDirectory(forNormalizedHash normHash: String) -> URL {
        cacheRootDirectory.appendingPathComponent(String(normHash.prefix(24)), isDirectory: true)
    }

    func getCachedOriginal(hash: String, expectedSizeBytes: Int64? = nil) -> URL? {
        let normHash = Self.normalizeHash(hash)
        guard !normHash.isEmpty else { return nil }
        let dir = itemDirectory(forNormalizedHash: normHash)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for candidate in entries {
            let name = candidate.lastPathComponent
            if name.hasPrefix(".") || name.hasSuffix(".part") {
                continue
            }
            guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let byteCount = values.fileSize,
                  byteCount > 0 else {
                continue
            }
            let actualSize = Int64(byteCount)
            if let expected = expectedSizeBytes, expected > 0, actualSize != expected {
                try? fm.removeItem(at: candidate)
                continue
            }
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: candidate.path)
            return candidate
        }
        return nil
    }

    func removeCachedOriginals(hashes: [String]) {
        let normHashes = Set(hashes.map(Self.normalizeHash).filter { !$0.isEmpty })
        guard !normHashes.isEmpty else { return }

        var tasksToCancel: [Task<URL, Error>] = []
        lock.lock()
        for h in normHashes {
            if let entry = inFlight.removeValue(forKey: h) {
                tasksToCancel.append(entry.task)
            }
        }
        lock.unlock()

        for t in tasksToCancel {
            t.cancel()
        }

        let fm = FileManager.default
        for h in normHashes {
            try? fm.removeItem(at: itemDirectory(forNormalizedHash: h))
        }
    }

    func getOrFetchOriginal(
        hash: String,
        preferredFilename: String? = nil,
        expectedSizeBytes: Int64? = nil,
        isVideo: Bool = false,
        client: PhotoHubAPIClient,
        onProgress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async throws -> URL {
        let normHash = Self.normalizeHash(hash)
        guard !normHash.isEmpty else {
            throw APIClientError.invalidResponse
        }

        if let cached = getCachedOriginal(hash: normHash, expectedSizeBytes: expectedSizeBytes) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: cached.path)
            let sz = (attrs?[.size] as? NSNumber)?.int64Value ?? expectedSizeBytes ?? 0
            if sz > 0 {
                onProgress?(sz, sz)
            }
            return cached
        }

        let waiterID = UUID()
        let clientBox = SendableClientBox(client: client)
        let entry = acquireEntry(
            normHash: normHash,
            waiterID: waiterID,
            preferredFilename: preferredFilename,
            expectedSizeBytes: expectedSizeBytes,
            isVideo: isVideo,
            clientBox: clientBox,
            onProgress: onProgress
        )

        return try await withTaskCancellationHandler {
            defer { releaseWaiter(normHash: normHash, entry: entry, waiterID: waiterID, cancelIfUnused: false) }
            try Task.checkCancellation()
            return try await entry.task.value
        } onCancel: {
            releaseWaiter(normHash: normHash, entry: entry, waiterID: waiterID, cancelIfUnused: true)
        }
    }

    func getOrFetchShareCopy(
        hash: String,
        preferredFilename: String? = nil,
        expectedSizeBytes: Int64? = nil,
        isVideo: Bool = false,
        client: PhotoHubAPIClient,
        onProgress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async throws -> URL {
        let cachedURL = try await getOrFetchOriginal(
            hash: hash,
            preferredFilename: preferredFilename,
            expectedSizeBytes: expectedSizeBytes,
            isVideo: isVideo,
            client: client,
            onProgress: onProgress
        )

        let fm = FileManager.default
        let shareDir = fm.temporaryDirectory.appendingPathComponent(
            "photohub_share_\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: shareDir, withIntermediateDirectories: true)
        let targetURL = shareDir.appendingPathComponent(cachedURL.lastPathComponent)
        if fm.fileExists(atPath: targetURL.path) {
            try? fm.removeItem(at: targetURL)
        }
        // APFS copyItem clones extents cleanly while giving callers a disposable temp path.
        try fm.copyItem(at: cachedURL, to: targetURL)
        return targetURL
    }

    private func emitProgress(entryID: UUID, downloaded: Int64, total: Int64?) {
        lock.lock()
        let callbacks = entryCallbacks[entryID].map { Array($0.values) } ?? []
        lock.unlock()
        for cb in callbacks {
            cb(downloaded, total)
        }
    }

    private func acquireEntry(
        normHash: String,
        waiterID: UUID,
        preferredFilename: String?,
        expectedSizeBytes: Int64?,
        isVideo: Bool,
        clientBox: SendableClientBox,
        onProgress: (@Sendable (Int64, Int64?) -> Void)?
    ) -> InFlightEntry {
        lock.lock()
        defer { lock.unlock() }

        if let existing = inFlight[normHash], !existing.task.isCancelled {
            existing.waiterIDs.insert(waiterID)
            if let onProgress {
                entryCallbacks[existing.id, default: [:]][waiterID] = onProgress
            }
            return existing
        }

        let entryID = UUID()
        if let onProgress {
            entryCallbacks[entryID] = [waiterID: onProgress]
        }
        let task = Task<URL, Error> { [self] in
            defer {
                self.lock.lock()
                if self.inFlight[normHash]?.id == entryID {
                    self.inFlight.removeValue(forKey: normHash)
                }
                self.entryCallbacks.removeValue(forKey: entryID)
                self.lock.unlock()
            }
            return try await self.downloadIntoCache(
                entryID: entryID,
                normHash: normHash,
                preferredFilename: preferredFilename,
                expectedSizeBytes: expectedSizeBytes,
                isVideo: isVideo,
                client: clientBox.client
            )
        }
        let createdEntry = InFlightEntry(id: entryID, task: task, waiterID: waiterID)
        inFlight[normHash] = createdEntry
        return createdEntry
    }

    private func releaseWaiter(
        normHash: String,
        entry: InFlightEntry,
        waiterID: UUID,
        cancelIfUnused: Bool
    ) {
        var taskToCancel: Task<URL, Error>?
        lock.lock()
        entryCallbacks[entry.id]?.removeValue(forKey: waiterID)
        let removed = entry.waiterIDs.remove(waiterID) != nil
        if removed && cancelIfUnused && entry.waiterIDs.isEmpty {
            if inFlight[normHash]?.id == entry.id {
                inFlight.removeValue(forKey: normHash)
            }
            entryCallbacks.removeValue(forKey: entry.id)
            taskToCancel = entry.task
        }
        lock.unlock()
        taskToCancel?.cancel()
    }

    private func downloadIntoCache(
        entryID: UUID,
        normHash: String,
        preferredFilename: String?,
        expectedSizeBytes: Int64?,
        isVideo: Bool,
        client: PhotoHubAPIClient
    ) async throws -> URL {
        if let cached = getCachedOriginal(hash: normHash, expectedSizeBytes: expectedSizeBytes) {
            return cached
        }

        let fm = FileManager.default
        let destDir = itemDirectory(forNormalizedHash: normHash)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let stageDir = destDir.appendingPathComponent(".stage_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stageDir) }

        let stagedURL = try await client.downloadMasterToDirectory(
            hash: normHash,
            destinationDir: stageDir,
            preferredFilename: preferredFilename,
            expectedSizeBytes: expectedSizeBytes,
            isVideo: isVideo,
            onProgress: { [self] down, total in
                self.emitProgress(entryID: entryID, downloaded: down, total: total)
            }
        )
        try Task.checkCancellation()

        let finalURL = destDir.appendingPathComponent(stagedURL.lastPathComponent)
        if let existingItems = try? fm.contentsOfDirectory(at: destDir, includingPropertiesForKeys: nil) {
            for existing in existingItems where existing.lastPathComponent != stageDir.lastPathComponent {
                try? fm.removeItem(at: existing)
            }
        }
        try fm.moveItem(at: stagedURL, to: finalURL)
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: finalURL.path)
        pruneAndEnforceBudget(keepingDirName: destDir.lastPathComponent)
        return finalURL
    }

    private func pruneAndEnforceBudget(keepingDirName: String) {
        let fm = FileManager.default
        let root = cacheRootDirectory
        guard let itemDirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        struct CacheEntryMeta {
            let dir: URL
            let dirName: String
            let totalBytes: Int64
            let lastModified: Date
        }

        var metas: [CacheEntryMeta] = []
        var totalBytes: Int64 = 0

        for dir in itemDirs {
            let dirName = dir.lastPathComponent
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: []
            ) else {
                continue
            }
            var entryBytes: Int64 = 0
            var newestDate = Date.distantPast
            for file in files {
                let name = file.lastPathComponent
                if name.hasPrefix(".") || name.hasSuffix(".part") {
                    if name.hasPrefix(".stage_") || name.hasSuffix(".part") {
                        let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                        if Date().timeIntervalSince(mod) > 1800 {
                            try? fm.removeItem(at: file)
                        }
                    }
                    continue
                }
                if let vals = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                   vals.isRegularFile == true {
                    entryBytes += Int64(vals.fileSize ?? 0)
                    if let m = vals.contentModificationDate, m > newestDate {
                        newestDate = m
                    }
                }
            }
            if entryBytes == 0 {
                if dirName != keepingDirName {
                    try? fm.removeItem(at: dir)
                }
                continue
            }
            totalBytes += entryBytes
            metas.append(CacheEntryMeta(dir: dir, dirName: dirName, totalBytes: entryBytes, lastModified: newestDate))
        }

        guard totalBytes > Self.maxCacheBytes else { return }
        let sortedOldestFirst = metas.sorted { $0.lastModified < $1.lastModified }
        for entry in sortedOldestFirst {
            if totalBytes <= Self.maxCacheBytes { break }
            if entry.dirName == keepingDirName { continue }
            try? fm.removeItem(at: entry.dir)
            totalBytes -= entry.totalBytes
        }
    }
}

private actor BatchShareStatusTracker {
    private var completedCount: Int = 0
    private let totalCount: Int
    private let onProgress: @MainActor (_ completed: Int, _ total: Int, _ stage: String) -> Void

    init(
        totalCount: Int,
        onProgress: @MainActor @escaping (_ completed: Int, _ total: Int, _ stage: String) -> Void
    ) {
        self.totalCount = totalCount
        self.onProgress = onProgress
    }

    func emitByteProgress(_ stage: String) async {
        await onProgress(completedCount, totalCount, stage)
    }

    func recordItemCompleted() async {
        completedCount += 1
        let stage = totalCount > 1
            ? "Prepared \(completedCount) of \(totalCount) item(s)..."
            : "Finishing original..."
        await onProgress(completedCount, totalCount, stage)
    }
}

enum OriginalMediaResolver {
    static func resolveMaster(
        input: OriginalShareInput,
        cachedPhotos: [ServerPhoto],
        client: PhotoHubAPIClient
    ) async throws -> (masterHash: String, originalName: String?, expectedSizeBytes: Int64?)? {
        // 1. Explicit masterHash / prefix query parameter
        if let hint = input.masterHashHint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter({ $0.isHexDigit }),
           hint.count >= 8 {
            if hint.count == 64 {
                let match = cachedPhotos.first(where: { $0.hash.lowercased() == hint })
                return (hint, match?.originalName ?? input.filenameHint, match?.size)
            }
            if let match = try await matchPrefix(hint, cachedPhotos: cachedPhotos, client: client) {
                return (match.hash, match.originalName, match.size)
            }
        }

        // 2. Local tracker lookup + Photos PHAssetResource metadata (zero iCloud download)
        if let assetId = input.assetId, !assetId.isEmpty {
            if let tracked = LocalProxyTracker.shared.anyMasterLookup(forAssetId: assetId) {
                let match = cachedPhotos.first(where: {
                    $0.hash.caseInsensitiveCompare(tracked.masterHash) == .orderedSame
                })
                return (tracked.masterHash, tracked.originalName ?? match?.originalName, match?.size)
            }

            let rwAuth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if rwAuth == .authorized || rwAuth == .limited,
               let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject,
               let proxyMatch = PhotoLibraryService.proxyHashPrefixFromAssetResources(asset) {
                if let match = try await matchPrefix(proxyMatch.prefix, cachedPhotos: cachedPhotos, client: client) {
                    return (match.hash, match.originalName, match.size)
                }
            }
        }

        // 3. Filename prefix PHOTOHUB_PROXY_<prefix16>
        let nameCandidates = [input.filenameHint, input.fileURL?.lastPathComponent].compactMap { $0 }
        for rawName in nameCandidates {
            if let prefix = ProxyGenerator.extractMasterHashPrefix(fromProxyFilename: rawName),
               let match = try await matchPrefix(prefix, cachedPhotos: cachedPhotos, client: client) {
                return (match.hash, match.originalName, match.size)
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
                    return (match?.hash ?? norm, match?.originalName ?? input.filenameHint, match?.size)
                } else if let match = try await matchPrefix(norm, cachedPhotos: cachedPhotos, client: client) {
                    return (match.hash, match.originalName, match.size)
                }
            }

            // 5. Stream SHA-256 -> LocalProxyTracker proxy map / cached server index / GET /api/check/:sha
            let sha = try ProxyGenerator.computeFileSHA256(url: fileURL).lowercased()
            if let knownMaster = LocalProxyTracker.shared.masterHash(forProxySha256: sha) {
                let match = cachedPhotos.first(where: { $0.hash.lowercased() == knownMaster.lowercased() })
                return (knownMaster, match?.originalName ?? input.filenameHint, match?.size)
            }
            if let cachedByHash = cachedPhotos.first(where: {
                $0.hash.lowercased() == sha || ($0.proxyHash?.lowercased() == sha)
            }) {
                return (cachedByHash.hash, cachedByHash.originalName, cachedByHash.size)
            }

            let check = try await client.checkHash(sha)
            if check.exists {
                let resolved = check.masterHash ?? sha
                let cachedMatch = cachedPhotos.first(where: { $0.hash.lowercased() == resolved.lowercased() })
                var resolvedName = check.originalName ?? cachedMatch?.originalName
                var resolvedSize = check.size ?? cachedMatch?.size
                if resolvedName == nil || resolvedName?.isEmpty == true || resolvedSize == nil {
                    if let prefixMatch = try? await matchPrefix(String(resolved.prefix(16)), cachedPhotos: cachedPhotos, client: client) {
                        if resolvedName == nil || resolvedName?.isEmpty == true {
                            resolvedName = prefixMatch.originalName
                        }
                        if resolvedSize == nil {
                            resolvedSize = prefixMatch.size
                        }
                    }
                }
                return (resolved, resolvedName ?? input.filenameHint, resolvedSize)
            }
        }

        // 6. Zero-copy filename + creation date metadata matching (handles Shortcuts "Get Name" and large
        // videos where iOS Shortcuts could not export bytes or transcoded/stripped metadata).
        if let rawHint = input.filenameHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawHint.isEmpty {
            if let matchedByMeta = await matchByFilenameMetadata(
                rawHint,
                creationDateHint: input.creationDateHint,
                preferVideo: input.isVideo,
                cachedPhotos: cachedPhotos,
                client: client
            ) {
                return matchedByMeta
            }
        }

        return nil
    }

    private static func matchByFilenameMetadata(
        _ rawHint: String,
        creationDateHint: Date?,
        preferVideo: Bool,
        cachedPhotos: [ServerPhoto],
        client: PhotoHubAPIClient
    ) async -> (masterHash: String, originalName: String?, expectedSizeBytes: Int64?)? {
        let hintName = URL(fileURLWithPath: rawHint).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !hintName.isEmpty else { return nil }
        let hintStem = URL(fileURLWithPath: hintName).deletingPathExtension().lastPathComponent.lowercased()
        let hintHasExt = !URL(fileURLWithPath: hintName).pathExtension.isEmpty

        let ignoredStems: Set<String> = ["media", "video", "photo", "image", "movie", "untitled"]
        if ignoredStems.contains(hintStem)
            || hintStem.hasPrefix("media_")
            || hintStem.hasPrefix("clipboard_")
            || hintStem.hasPrefix("photohub_pick_") {
            return nil
        }

        // 6a. Fast match in cached server catalog
        if let hit = pickBestServerPhotoMatch(
            from: cachedPhotos,
            hintName: hintName,
            hintStem: hintStem,
            hintHasExt: hintHasExt,
            creationDateHint: creationDateHint,
            preferVideo: preferVideo
        ) {
            return (hit.hash, hit.originalName, hit.size)
        }

        // 6b. Check live server index if local cache missed (e.g. newly uploaded item or fresh install)
        if let freshPhotos = try? await client.fetchAllServerPhotos(sync: false),
           let hit = pickBestServerPhotoMatch(
               from: freshPhotos,
               hintName: hintName,
               hintStem: hintStem,
               hintHasExt: hintHasExt,
               creationDateHint: creationDateHint,
               preferVideo: preferVideo
           ) {
            return (hit.hash, hit.originalName, hit.size)
        }

        // 6c. Zero-copy Apple Photos PHAsset metadata lookup (handles renamed/localized proxy assets)
        let rwAuth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if rwAuth == .authorized || rwAuth == .limited {
            let fetchOptions = PHFetchOptions()
            if let creationDateHint {
                let start = creationDateHint.addingTimeInterval(-30) as NSDate
                let end = creationDateHint.addingTimeInterval(30) as NSDate
                fetchOptions.predicate = NSPredicate(
                    format: "(mediaType == %d OR mediaType == %d) AND creationDate >= %@ AND creationDate <= %@",
                    PHAssetMediaType.image.rawValue,
                    PHAssetMediaType.video.rawValue,
                    start,
                    end
                )
            } else {
                fetchOptions.predicate = NSPredicate(
                    format: "mediaType == %d OR mediaType == %d",
                    PHAssetMediaType.image.rawValue,
                    PHAssetMediaType.video.rawValue
                )
                fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                fetchOptions.fetchLimit = 2000
            }

            let assets = PHAsset.fetchAssets(with: fetchOptions)
            var matchedMaster: (String, String?, Int64?)?
            var matchedPrefix: String?
            for i in 0..<assets.count {
                if matchedMaster != nil || matchedPrefix != nil { break }
                autoreleasepool {
                    let asset = assets.object(at: i)
                    let info = PhotoLibraryService.inspectAssetResources(for: asset)
                    guard let resName = info.originalFilename?.lowercased(), !resName.isEmpty else { return }
                    let resStem = URL(fileURLWithPath: resName).deletingPathExtension().lastPathComponent.lowercased()
                    let nameMatches = hintHasExt ? (resName == hintName) : (resStem == hintStem)
                    guard nameMatches else { return }

                    if let tracked = LocalProxyTracker.shared.anyMasterLookup(forAssetId: asset.localIdentifier) {
                        let cachedMatch = cachedPhotos.first(where: {
                            $0.hash.caseInsensitiveCompare(tracked.masterHash) == .orderedSame
                        })
                        matchedMaster = (tracked.masterHash, tracked.originalName ?? cachedMatch?.originalName ?? info.originalFilename, cachedMatch?.size)
                    } else if let proxyMatch = info.proxyMatch {
                        matchedPrefix = proxyMatch.prefix
                    }
                }
            }

            if let matchedMaster {
                return matchedMaster
            }
            if let matchedPrefix,
               let match = try? await matchPrefix(matchedPrefix, cachedPhotos: cachedPhotos, client: client) {
                return (match.hash, match.originalName, match.size)
            }
        }

        return nil
    }

    private static func pickBestServerPhotoMatch(
        from photos: [ServerPhoto],
        hintName: String,
        hintStem: String,
        hintHasExt: Bool,
        creationDateHint: Date?,
        preferVideo: Bool
    ) -> ServerPhoto? {
        var matches = photos.filter { photo in
            let candidate = URL(fileURLWithPath: photo.originalName).lastPathComponent.lowercased()
            if candidate == hintName { return true }
            if !hintHasExt {
                let stem = URL(fileURLWithPath: candidate).deletingPathExtension().lastPathComponent.lowercased()
                return stem == hintStem
            }
            return false
        }
        guard !matches.isEmpty else { return nil }
        if matches.count == 1 { return matches[0] }

        if let creationDateHint {
            let nearDate = matches.compactMap { photo -> (ServerPhoto, TimeInterval)? in
                guard let d = photo.parsedCreationDate else { return nil }
                let diff = abs(d.timeIntervalSince(creationDateHint))
                return diff <= 120 ? (photo, diff) : nil
            }
            if let closest = nearDate.min(by: { $0.1 < $1.1 }) {
                return closest.0
            }
        }

        if preferVideo {
            let videoMatches = matches.filter { $0.isVideo }
            if !videoMatches.isEmpty {
                matches = videoMatches
            }
        }
        return matches.first
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
        let warmClientBox = SendableClientBox(client: client)
        let warmTask = Task(priority: .userInitiated) {
            await warmClientBox.client.warmConnectionIfNeeded()
        }
        defer { warmTask.cancel() }

        let cachedPhotos = LocalProxyStore.shared.cachedPhotos(
            baseURL: settings.normalizedBaseURL,
            apiKey: settings.apiKey
        )
        let indexed = inputs.enumerated().map { (index: $0.offset, input: $0.element) }
        let queue = AsyncWorkQueue(indexed)
        let hasVideo = inputs.contains { $0.isVideo }
        let workerCount = hasVideo ? 1 : min(3, max(1, indexed.count))
        let statusTracker = BatchShareStatusTracker(totalCount: indexed.count, onProgress: onProgress)

        var outcomes: [BatchOriginalFetchItemOutcome] = []
        var sawAuthExpired = false

        await withTaskGroup(of: BatchOriginalFetchItemOutcome?.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    await fetchNextItem(
                        queue: queue,
                        cachedPhotos: cachedPhotos,
                        client: client,
                        statusTracker: statusTracker
                    )
                }
            }

            for await outcome in group {
                guard let outcome else { continue }
                outcomes.append(outcome)
                if case .authExpired = outcome {
                    sawAuthExpired = true
                }
                await statusTracker.recordItemCompleted()

                if !Task.isCancelled && !sawAuthExpired {
                    group.addTask {
                        await fetchNextItem(
                            queue: queue,
                            cachedPhotos: cachedPhotos,
                            client: client,
                            statusTracker: statusTracker
                        )
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
        client: PhotoHubAPIClient,
        statusTracker: BatchShareStatusTracker
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

            let trimmedName = resolved.originalName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let displayLabel = trimmedName.isEmpty ? input.displayName : trimmedName
            let expectedBytes = resolved.expectedSizeBytes
            let resolvedExt = URL(fileURLWithPath: displayLabel).pathExtension.lowercased()
            let resolvedIsVideo = input.isVideo
                || ["mp4", "mov", "m4v", "3gp", "avi", "mkv", "webm"].contains(resolvedExt)

            let tempMasterURL = try await OriginalDownloadCache.shared.getOrFetchShareCopy(
                hash: resolved.masterHash,
                preferredFilename: resolved.originalName,
                expectedSizeBytes: expectedBytes,
                isVideo: resolvedIsVideo,
                client: client,
                onProgress: { down, total in
                    let effectiveTotal = total ?? expectedBytes
                    let downStr = ByteCountFormatter.string(fromByteCount: down, countStyle: .file)
                    let msg: String
                    if let effectiveTotal, effectiveTotal > 0 {
                        let totStr = ByteCountFormatter.string(fromByteCount: effectiveTotal, countStyle: .file)
                        msg = "Downloading \(displayLabel) (\(downStr) / \(totStr))..."
                    } else {
                        msg = "Downloading \(displayLabel) (\(downStr))..."
                    }
                    Task {
                        await statusTracker.emitByteProgress(msg)
                    }
                }
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
