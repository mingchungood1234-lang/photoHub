import CryptoKit
import Foundation
import Photos
import UIKit

enum LocalDuplicateReason: String, Sendable {
    case duplicateProxy = "Duplicate Proxy"
    case redundantProxy = "Redundant Proxy"
    case exactFile = "Exact Duplicate"
    case visuallyIdentical = "Identical Copy"
}

struct LocalDuplicateAssetItem: Identifiable {
    let id: String // PHAsset.localIdentifier
    let asset: PHAsset
    let filename: String
    let sizeBytes: Int64
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let isVideo: Bool
    let isFavorite: Bool
    let isProxy: Bool
    let isKeep: Bool
}

struct LocalDuplicateGroup: Identifiable {
    let id: String
    let reason: LocalDuplicateReason
    let items: [LocalDuplicateAssetItem]

    var removableItems: [LocalDuplicateAssetItem] {
        items.filter { !$0.isKeep }
    }

    var reclaimableBytes: Int64 {
        removableItems.reduce(0) { $0 + max(0, $1.sizeBytes) }
    }
}

struct LocalDuplicateScanResult {
    let scannedCount: Int
    let groups: [LocalDuplicateGroup]

    var totalRemovableCount: Int {
        groups.reduce(0) { $0 + $1.removableItems.count }
    }

    var totalReclaimableBytes: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }
}

enum LocalDuplicateCleaner {
    private struct ScannedAssetMeta {
        let id: String
        let asset: PHAsset
        let filename: String
        let sizeBytes: Int64
        let creationDate: Date?
        let pixelWidth: Int
        let pixelHeight: Int
        let isVideo: Bool
        let isFavorite: Bool
        let isProxy: Bool
        let proxyMasterPrefix: String?
        let trackedMasterPrefix: String?
    }

    /// Scans the local iPhone Photos library (zero iCloud network downloads) for:
    /// 1. Duplicate PhotoHub proxies or redundant proxies where the original is also on iPhone
    /// 2. 100% byte-for-byte identical duplicate photos & videos (size-bucketed SHA-256)
    /// 3. Visually identical re-saved / re-encoded photo copies (64-bit perceptual dHash)
    /// Always keeps the single best copy in every group.
    static func scanForDuplicates(
        tracker: LocalProxyTracker = .shared,
        onProgress: @escaping @Sendable (Int, Int, String) -> Void
    ) -> LocalDuplicateScanResult {
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard auth == .authorized || auth == .limited else {
            return LocalDuplicateScanResult(scannedCount: 0, groups: [])
        }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        let fetched = PHAsset.fetchAssets(with: fetchOptions)
        let total = fetched.count
        guard total > 1 else {
            onProgress(total, total, "Scan complete")
            return LocalDuplicateScanResult(scannedCount: total, groups: [])
        }

        onProgress(0, total, "Reading gallery metadata…")

        var allMetas: [ScannedAssetMeta] = []
        allMetas.reserveCapacity(total)

        for idx in 0..<total {
            if Task.isCancelled { break }
            autoreleasepool {
                let asset = fetched.object(at: idx)
                let inspection = PhotoLibraryService.inspectAssetResources(for: asset)
                let filename = inspection.originalFilename ?? "Photo"
                let sizeBytes = primaryLocalFileSize(for: asset)
                let proxyPrefixFromName = inspection.proxyMatch?.prefix.lowercased()
                let isTrackedProxy = tracker.isKnownProxy(assetId: asset.localIdentifier)
                let trackedMasterHash = tracker.anyMasterLookup(forAssetId: asset.localIdentifier)?.masterHash.lowercased()
                let isProxy = (proxyPrefixFromName != nil) || isTrackedProxy
                let proxyPrefix = proxyPrefixFromName ?? (isTrackedProxy ? trackedMasterHash.map { String($0.prefix(16)) } : nil)
                let origMasterPrefix = !isProxy ? trackedMasterHash.map { String($0.prefix(16)) } : nil

                allMetas.append(
                    ScannedAssetMeta(
                        id: asset.localIdentifier,
                        asset: asset,
                        filename: filename,
                        sizeBytes: sizeBytes,
                        creationDate: asset.creationDate,
                        pixelWidth: asset.pixelWidth,
                        pixelHeight: asset.pixelHeight,
                        isVideo: asset.mediaType == .video,
                        isFavorite: asset.isFavorite,
                        isProxy: isProxy,
                        proxyMasterPrefix: proxyPrefix,
                        trackedMasterPrefix: origMasterPrefix
                    )
                )
            }
            if idx % 150 == 0 {
                onProgress(idx, total, "Inspecting \(idx)/\(total) items…")
            }
        }

        var groups: [LocalDuplicateGroup] = []
        var assignedIds = Set<String>()

        // MARK: Pass 1 — Duplicate PhotoHub Proxies & Redundant Proxy+Original pairs
        var proxiesByPrefix: [String: [ScannedAssetMeta]] = [:]
        var originalsByPrefix: [String: [ScannedAssetMeta]] = [:]
        for meta in allMetas {
            if meta.isProxy, let prefix = meta.proxyMasterPrefix, prefix.count >= 8 {
                proxiesByPrefix[prefix, default: []].append(meta)
            } else if !meta.isProxy, let prefix = meta.trackedMasterPrefix, prefix.count >= 8 {
                originalsByPrefix[prefix, default: []].append(meta)
            }
        }

        for (prefix, proxies) in proxiesByPrefix {
            if let liveOriginals = originalsByPrefix[prefix], let bestOriginal = pickBestOriginal(liveOriginals) {
                let combined = [bestOriginal] + proxies
                let group = buildGroup(
                    id: "redundant_proxy_\(prefix)",
                    reason: .redundantProxy,
                    members: combined,
                    preferredKeepId: bestOriginal.id
                )
                groups.append(group)
                for m in combined { assignedIds.insert(m.id) }
            } else if proxies.count >= 2 {
                let group = buildGroup(
                    id: "dup_proxy_\(prefix)",
                    reason: .duplicateProxy,
                    members: proxies,
                    preferredKeepId: nil
                )
                groups.append(group)
                for m in proxies { assignedIds.insert(m.id) }
            }
        }

        // MARK: Pass 2 — Exact Byte-for-Byte Duplicate Photos & Videos (Size-Bucketed SHA-256)
        struct SizeBucketKey: Hashable {
            let isVideo: Bool
            let sizeBytes: Int64
        }

        var sizeBuckets: [SizeBucketKey: [ScannedAssetMeta]] = [:]
        for meta in allMetas where !assignedIds.contains(meta.id) && meta.sizeBytes > 0 {
            let key = SizeBucketKey(isVideo: meta.isVideo, sizeBytes: meta.sizeBytes)
            sizeBuckets[key, default: []].append(meta)
        }

        let candidateBuckets = sizeBuckets.values.filter { $0.count >= 2 }
        let totalToHash = candidateBuckets.reduce(0) { $0 + $1.count }
        var hashedSoFar = 0

        for bucket in candidateBuckets {
            if Task.isCancelled { break }
            var bySha: [String: [ScannedAssetMeta]] = [:]
            for meta in bucket {
                if Task.isCancelled { break }
                hashedSoFar += 1
                if hashedSoFar == 1 || hashedSoFar % 10 == 0 || hashedSoFar == totalToHash {
                    onProgress(hashedSoFar, max(1, totalToHash), "Verifying exact duplicates (\(hashedSoFar)/\(totalToHash))…")
                }
                if let sha = computeLocalAssetSha256(for: meta.asset) {
                    bySha[sha, default: []].append(meta)
                }
            }
            for (sha, matches) in bySha where matches.count >= 2 {
                let group = buildGroup(
                    id: "exact_\(sha.prefix(16))",
                    reason: .exactFile,
                    members: matches,
                    preferredKeepId: nil
                )
                groups.append(group)
                for m in matches { assignedIds.insert(m.id) }
            }
        }

        // MARK: Pass 3 — Visually Identical Re-Saved Photo Copies (64-bit dHash on fast thumbnails)
        let imageCandidates = allMetas.filter {
            !assignedIds.contains($0.id) && !$0.isVideo && !$0.isProxy
        }.prefix(900)

        struct VisualHashEntry {
            let meta: ScannedAssetMeta
            let dHash: UInt64
            let aspectRatio: Double
        }

        let imageManager = PHImageManager.default()
        let thumbOpts = PHImageRequestOptions()
        thumbOpts.isSynchronous = true
        thumbOpts.isNetworkAccessAllowed = false
        thumbOpts.deliveryMode = .fastFormat
        thumbOpts.resizeMode = .fast

        var visualEntries: [VisualHashEntry] = []
        visualEntries.reserveCapacity(imageCandidates.count)
        let visualTotal = imageCandidates.count
        var visualIdx = 0

        for meta in imageCandidates {
            if Task.isCancelled { break }
            visualIdx += 1
            if visualIdx == 1 || visualIdx % 40 == 0 || visualIdx == visualTotal {
                onProgress(visualIdx, max(1, visualTotal), "Checking identical copies (\(visualIdx)/\(visualTotal))…")
            }
            autoreleasepool {
                var capturedImage: UIImage?
                imageManager.requestImage(
                    for: meta.asset,
                    targetSize: CGSize(width: 48, height: 48),
                    contentMode: .aspectFill,
                    options: thumbOpts
                ) { img, _ in
                    capturedImage = img
                }
                if let cgImage = capturedImage?.cgImage,
                   let dHash = computeDHash64(cgImage: cgImage) {
                    let ar = meta.pixelHeight > 0 ? Double(meta.pixelWidth) / Double(meta.pixelHeight) : 1.0
                    visualEntries.append(VisualHashEntry(meta: meta, dHash: dHash, aspectRatio: ar))
                }
            }
        }

        // Group exact 64-bit dHash matches (zero false positives) or near-identical copies (hamming <= 2 within 5s)
        let vn = visualEntries.count
        if vn >= 2 {
            var parent = Array(0..<vn)
            func find(_ x: Int) -> Int {
                var cur = x
                while parent[cur] != cur {
                    parent[cur] = parent[parent[cur]]
                    cur = parent[cur]
                }
                return cur
            }
            func unite(_ a: Int, _ b: Int) {
                let ra = find(a)
                let rb = find(b)
                if ra != rb { parent[rb] = ra }
            }

            // Fast exact dHash bucket pass O(n)
            var exactBuckets: [UInt64: [Int]] = [:]
            for i in 0..<vn {
                exactBuckets[visualEntries[i].dHash, default: []].append(i)
            }
            for indices in exactBuckets.values where indices.count >= 2 {
                let first = indices[0]
                for other in indices.dropFirst() {
                    if abs(visualEntries[first].aspectRatio - visualEntries[other].aspectRatio) < 0.08 {
                        unite(first, other)
                    }
                }
            }

            // Adjacent chronological near-identical re-encode check (hamming <= 2 within 5s)
            for i in 0..<vn {
                let a = visualEntries[i]
                let upper = min(vn, i + 12)
                for j in (i + 1)..<upper {
                    let b = visualEntries[j]
                    guard abs(a.aspectRatio - b.aspectRatio) < 0.05 else { continue }
                    if let da = a.meta.creationDate, let db = b.meta.creationDate,
                       abs(da.timeIntervalSince(db)) <= 5.0 {
                        let dist = (a.dHash ^ b.dHash).nonzeroBitCount
                        if dist <= 2 {
                            unite(i, j)
                        }
                    }
                }
            }

            var visualGroupsMap: [Int: [ScannedAssetMeta]] = [:]
            for i in 0..<vn {
                visualGroupsMap[find(i), default: []].append(visualEntries[i].meta)
            }
            for (_, members) in visualGroupsMap where members.count >= 2 {
                let group = buildGroup(
                    id: "visual_\(members[0].id.prefix(12))",
                    reason: .visuallyIdentical,
                    members: members,
                    preferredKeepId: nil
                )
                groups.append(group)
            }
        }

        groups.sort { $0.reclaimableBytes > $1.reclaimableBytes }
        onProgress(total, total, "Scan complete")
        return LocalDuplicateScanResult(scannedCount: total, groups: groups)
    }

    private static func pickBestOriginal(_ list: [ScannedAssetMeta]) -> ScannedAssetMeta? {
        list.max { lhs, rhs in
            bestScore(for: lhs) < bestScore(for: rhs)
        }
    }

    private static func bestScore(for meta: ScannedAssetMeta) -> Double {
        var score: Double = 0
        if !meta.isProxy { score += 1_000_000 }
        if meta.isFavorite { score += 500_000 }
        let pixels = Double(meta.pixelWidth) * Double(meta.pixelHeight)
        score += min(300_000, pixels / 100.0)
        score += min(100_000, Double(meta.sizeBytes) / 1024.0)
        // Prefer clean original filename without " (1)" or "copy"
        let lower = meta.filename.lowercased()
        if !lower.contains("copy") && !lower.contains("(1)") && !lower.contains("(2)") {
            score += 5_000
        }
        // Slightly prefer the older (original) timestamp
        if let dt = meta.creationDate {
            score -= dt.timeIntervalSince1970 / 1_000_000_000.0
        }
        return score
    }

    private static func buildGroup(
        id: String,
        reason: LocalDuplicateReason,
        members: [ScannedAssetMeta],
        preferredKeepId: String?
    ) -> LocalDuplicateGroup {
        let keepId: String = preferredKeepId ?? (pickBestOriginal(members)?.id ?? members[0].id)
        let sorted = members.sorted { lhs, rhs in
            if lhs.id == keepId { return true }
            if rhs.id == keepId { return false }
            return bestScore(for: lhs) > bestScore(for: rhs)
        }
        let items = sorted.map { m in
            LocalDuplicateAssetItem(
                id: m.id,
                asset: m.asset,
                filename: m.filename,
                sizeBytes: m.sizeBytes,
                creationDate: m.creationDate,
                pixelWidth: m.pixelWidth,
                pixelHeight: m.pixelHeight,
                isVideo: m.isVideo,
                isFavorite: m.isFavorite,
                isProxy: m.isProxy,
                isKeep: m.id == keepId
            )
        }
        return LocalDuplicateGroup(id: id, reason: reason, items: items)
    }

    private static func primaryLocalFileSize(for asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        for res in resources where res.type == .photo || res.type == .video || res.type == .fullSizePhoto || res.type == .fullSizeVideo {
            if let num = res.value(forKey: "fileSize") as? NSNumber, num.int64Value > 0 {
                return num.int64Value
            }
        }
        return 0
    }

    private static func computeLocalAssetSha256(for asset: PHAsset) -> String? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo })
            ?? resources.first(where: { $0.type == .photo || $0.type == .video }) else {
            return nil
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false

        var hasher = SHA256()
        var totalBytes: Int64 = 0
        var failed = false
        let semaphore = DispatchSemaphore(value: 0)

        PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
            totalBytes += Int64(chunk.count)
            hasher.update(data: chunk)
        } completionHandler: { error in
            if error != nil {
                failed = true
            }
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + 25.0)
        if waitResult == .timedOut || failed || totalBytes == 0 {
            return nil
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func computeDHash64(cgImage: CGImage) -> UInt64? {
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hash: UInt64 = 0
        var bitIndex = 0
        for row in 0..<height {
            let rowStart = row * width
            for col in 0..<8 {
                if pixels[rowStart + col] > pixels[rowStart + col + 1] {
                    hash |= (UInt64(1) << UInt64(bitIndex))
                }
                bitIndex += 1
            }
        }
        return hash
    }
}
