import Foundation
import Photos

/// Persists locally compressed proxy identifiers, SHA-256 hashes, and master-hash mappings
/// so proxies are never re-uploaded and can be resolved back to their original master on the server.
final class LocalProxyTracker {
    static let shared = LocalProxyTracker()

    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private let assetIdsKey = "photohub_proxy_asset_ids"
    private let proxyHashesKey = "photohub_proxy_sha256_hashes"
    private let assetToMasterKey = "photohub_proxy_asset_to_master"
    private let assetToFilenameKey = "photohub_proxy_asset_to_filename"
    private let proxyHashToMasterKey = "photohub_proxy_hash_to_master"
    private let masterToAssetKey = "photohub_master_to_proxy_asset"
    private let autoHandledPhotosKey = "photohub_auto_handled_photos_masters"
    private let restoredAssetIdsKey = "photohub_restored_asset_ids"
    private let restoredMastersKey = "photohub_restored_master_hashes"
    private let restoredAssetToMasterKey = "photohub_restored_asset_to_master"
    private let uploadedOriginalMasterToAssetKey = "photohub_uploaded_original_master_to_asset"
    private let pendingProtectionSyncKey = "photohub_pending_protection_sync_masters"

    private var assetIds: Set<String>
    private var proxyHashes: Set<String>
    private var assetToMaster: [String: String]
    private var assetToFilename: [String: String]
    private var proxyHashToMaster: [String: String]
    private var masterToAssetId: [String: String]
    private var autoHandledPhotosMasters: Set<String>
    private var restoredAssetIds: Set<String>
    private var restoredMasterHashes: Set<String>
    private var restoredAssetToMaster: [String: String]
    private var restoredMasterToAssetIds: [String: [String]]
    private var uploadedOriginalMasterToAsset: [String: String]
    private var uploadedOriginalAssetIds: Set<String>
    private var pendingProtectionSyncMasters: Set<String>

    private init() {
        self.assetIds = Set(defaults.stringArray(forKey: assetIdsKey) ?? [])
        self.proxyHashes = Set(defaults.stringArray(forKey: proxyHashesKey) ?? [])
        self.assetToMaster = defaults.dictionary(forKey: assetToMasterKey) as? [String: String] ?? [:]
        self.assetToFilename = defaults.dictionary(forKey: assetToFilenameKey) as? [String: String] ?? [:]
        self.proxyHashToMaster = defaults.dictionary(forKey: proxyHashToMasterKey) as? [String: String] ?? [:]
        self.masterToAssetId = defaults.dictionary(forKey: masterToAssetKey) as? [String: String] ?? [:]
        self.autoHandledPhotosMasters = Set(defaults.stringArray(forKey: autoHandledPhotosKey) ?? [])
        self.restoredAssetIds = Set(defaults.stringArray(forKey: restoredAssetIdsKey) ?? [])
        self.restoredMasterHashes = Set(defaults.stringArray(forKey: restoredMastersKey) ?? [])
        let restoredMap = defaults.dictionary(forKey: restoredAssetToMasterKey) as? [String: String] ?? [:]
        self.restoredAssetToMaster = restoredMap
        var reverseRestored: [String: [String]] = [:]
        reverseRestored.reserveCapacity(restoredMap.count)
        for (assetId, master) in restoredMap where !assetId.isEmpty && !master.isEmpty {
            reverseRestored[master.lowercased(), default: []].append(assetId)
        }
        self.restoredMasterToAssetIds = reverseRestored
        let uploadedMap = defaults.dictionary(forKey: uploadedOriginalMasterToAssetKey) as? [String: String] ?? [:]
        self.uploadedOriginalMasterToAsset = uploadedMap
        self.uploadedOriginalAssetIds = Set(uploadedMap.values.filter { !$0.isEmpty })
        self.pendingProtectionSyncMasters = Set(defaults.stringArray(forKey: pendingProtectionSyncKey) ?? [])
    }

    func isKnownProxy(assetId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return assetIds.contains(assetId)
    }

    func isKnownProxy(sha256: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return proxyHashes.contains(sha256.lowercased())
    }

    func masterLookup(forAssetId assetId: String) -> (masterHash: String, originalName: String?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let master = assetToMaster[assetId], !master.isEmpty else {
            return nil
        }
        return (master, assetToFilename[assetId])
    }

    func restoredMasterHash(forAssetId assetId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let master = restoredAssetToMaster[assetId], !master.isEmpty else {
            return nil
        }
        return master
    }

    func anyMasterLookup(forAssetId assetId: String) -> (masterHash: String, originalName: String?)? {
        lock.lock()
        defer { lock.unlock() }
        if let master = assetToMaster[assetId], !master.isEmpty {
            return (master, assetToFilename[assetId])
        }
        if let restored = restoredAssetToMaster[assetId], !restored.isEmpty {
            return (restored, nil)
        }
        if uploadedOriginalAssetIds.contains(assetId) {
            for (master, mappedId) in uploadedOriginalMasterToAsset where mappedId == assetId {
                return (master, nil)
            }
        }
        return nil
    }

    func masterHash(forProxySha256 sha256: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return proxyHashToMaster[sha256.lowercased()]
    }

    func isMasterHandledForPhotos(_ masterHash: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return autoHandledPhotosMasters.contains(masterHash.lowercased())
    }

    func markMasterHandledForPhotos(_ masterHash: String) {
        let normMaster = masterHash.lowercased()
        guard !normMaster.isEmpty else { return }
        lock.lock()
        autoHandledPhotosMasters.insert(normMaster)
        defaults.set(Array(autoHandledPhotosMasters), forKey: autoHandledPhotosKey)
        lock.unlock()
    }

    /// Returns the local `PHAsset.localIdentifier` if a proxy for `masterHash` still physically exists in Apple Photos.
    func liveProxyAssetId(forMasterHash masterHash: String) -> String? {
        lock.lock()
        let savedId = masterToAssetId[masterHash.lowercased()]
        lock.unlock()
        guard let savedId, !savedId.isEmpty else { return nil }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [savedId], options: nil)
        return fetched.firstObject?.localIdentifier
    }

    func markAsProxy(
        assetId: String,
        proxySha256: String,
        masterHash: String? = nil,
        originalName: String? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }

        let normProxy = proxySha256.lowercased()
        assetIds.insert(assetId)
        defaults.set(Array(assetIds), forKey: assetIdsKey)

        if !normProxy.isEmpty {
            proxyHashes.insert(normProxy)
            defaults.set(Array(proxyHashes), forKey: proxyHashesKey)
        }

        if let masterHash, !masterHash.isEmpty {
            let normMaster = masterHash.lowercased()
            assetToMaster[assetId] = normMaster
            masterToAssetId[normMaster] = assetId
            autoHandledPhotosMasters.insert(normMaster)
            defaults.set(assetToMaster, forKey: assetToMasterKey)
            defaults.set(masterToAssetId, forKey: masterToAssetKey)
            defaults.set(Array(autoHandledPhotosMasters), forKey: autoHandledPhotosKey)
            if !normProxy.isEmpty {
                proxyHashToMaster[normProxy] = normMaster
                defaults.set(proxyHashToMaster, forKey: proxyHashToMasterKey)
            }
        }

        if let originalName, !originalName.isEmpty {
            assetToFilename[assetId] = originalName
            defaults.set(assetToFilename, forKey: assetToFilenameKey)
        }
    }

    /// Returns all tracked local compressed proxy `PHAsset.localIdentifier`s for the given master hashes,
    /// excluding any asset ID recorded as a restored full-resolution original.
    func trackedProxyAssetIds(forMasterHashes hashes: Set<String>) -> [String] {
        let normHashes = Set(
            hashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !normHashes.isEmpty else { return [] }
        lock.lock()
        var result = Set<String>()
        for h in normHashes {
            if let direct = masterToAssetId[h], !direct.isEmpty, !restoredAssetIds.contains(direct) {
                result.insert(direct)
            }
        }
        for (assetId, mappedMaster) in assetToMaster {
            if normMastersContains(normHashes, master: mappedMaster), !restoredAssetIds.contains(assetId) {
                result.insert(assetId)
            }
        }
        lock.unlock()
        return Array(result)
    }

    private func normMastersContains(_ normHashes: Set<String>, master: String) -> Bool {
        normHashes.contains(master.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Removes deleted compressed proxy asset IDs from proxy tracking while preserving restored-original protection.
    func clearProxyMappings(assetIds deletedIds: [String]) {
        let idSet = Set(deletedIds.filter { !$0.isEmpty })
        guard !idSet.isEmpty else { return }

        lock.lock()
        for id in idSet {
            assetIds.remove(id)
            assetToMaster.removeValue(forKey: id)
            assetToFilename.removeValue(forKey: id)
        }
        for (master, mappedId) in Array(masterToAssetId) where idSet.contains(mappedId) {
            masterToAssetId.removeValue(forKey: master)
        }
        defaults.set(Array(assetIds), forKey: assetIdsKey)
        defaults.set(assetToMaster, forKey: assetToMasterKey)
        defaults.set(assetToFilename, forKey: assetToFilenameKey)
        defaults.set(masterToAssetId, forKey: masterToAssetKey)
        lock.unlock()
    }

    func isRestoredOriginal(assetId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return restoredAssetIds.contains(assetId)
    }

    func isRestoredMasterHash(_ masterHash: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return restoredMasterHashes.contains(masterHash.lowercased())
    }

    /// Returns a live `PHAsset.localIdentifier` of a locally restored original if it still exists in Photos.
    func liveRestoredAssetId(forMasterHash masterHash: String) -> String? {
        let normMaster = masterHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normMaster.isEmpty else { return nil }
        lock.lock()
        let candidateIds = restoredMasterToAssetIds[normMaster] ?? []
        lock.unlock()
        guard !candidateIds.isEmpty else { return nil }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: candidateIds, options: nil)
        return fetched.firstObject?.localIdentifier
    }

    func markRestoredOriginal(assetId: String?, masterHash: String) {
        let normMaster = masterHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock()
        if let assetId, !assetId.isEmpty {
            restoredAssetIds.insert(assetId)
            defaults.set(Array(restoredAssetIds), forKey: restoredAssetIdsKey)
            if !normMaster.isEmpty {
                restoredAssetToMaster[assetId] = normMaster
                var list = restoredMasterToAssetIds[normMaster] ?? []
                if !list.contains(assetId) {
                    list.append(assetId)
                    restoredMasterToAssetIds[normMaster] = list
                }
                defaults.set(restoredAssetToMaster, forKey: restoredAssetToMasterKey)
            }
        }
        if !normMaster.isEmpty {
            restoredMasterHashes.insert(normMaster)
            defaults.set(Array(restoredMasterHashes), forKey: restoredMastersKey)
        }
        lock.unlock()
    }

    func clearRestoredProtection(masterHash: String) {
        let normMaster = masterHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normMaster.isEmpty else { return }
        lock.lock()
        restoredMasterHashes.remove(normMaster)
        pendingProtectionSyncMasters.remove(normMaster)
        let matchingAssetIds = restoredMasterToAssetIds.removeValue(forKey: normMaster) ?? restoredAssetToMaster
            .filter { $0.value == normMaster }
            .map(\.key)
        var dirtyUploaded = false
        for assetId in matchingAssetIds {
            restoredAssetIds.remove(assetId)
            restoredAssetToMaster.removeValue(forKey: assetId)
            // Keep asset linked as uploaded original so Cloud browsing remains zero-download while Optimize can re-proxy it.
            if !assetId.isEmpty && !assetIds.contains(assetId) && uploadedOriginalMasterToAsset[normMaster] == nil {
                uploadedOriginalMasterToAsset[normMaster] = assetId
                uploadedOriginalAssetIds.insert(assetId)
                dirtyUploaded = true
            }
        }
        defaults.set(Array(restoredMasterHashes), forKey: restoredMastersKey)
        defaults.set(Array(restoredAssetIds), forKey: restoredAssetIdsKey)
        defaults.set(restoredAssetToMaster, forKey: restoredAssetToMasterKey)
        defaults.set(Array(pendingProtectionSyncMasters), forKey: pendingProtectionSyncKey)
        if dirtyUploaded {
            defaults.set(uploadedOriginalMasterToAsset, forKey: uploadedOriginalMasterToAssetKey)
        }
        lock.unlock()
    }

    func markPendingProtectionSync(masterHashes: [String]) {
        let cleaned = masterHashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        lock.lock()
        var dirty = false
        for h in cleaned {
            if pendingProtectionSyncMasters.insert(h).inserted { dirty = true }
        }
        if dirty {
            defaults.set(Array(pendingProtectionSyncMasters), forKey: pendingProtectionSyncKey)
        }
        lock.unlock()
    }

    func clearPendingProtectionSync(masterHashes: [String]) {
        let cleaned = masterHashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        lock.lock()
        var dirty = false
        for h in cleaned {
            if pendingProtectionSyncMasters.remove(h) != nil { dirty = true }
        }
        if dirty {
            defaults.set(Array(pendingProtectionSyncMasters), forKey: pendingProtectionSyncKey)
        }
        lock.unlock()
    }

    func isPendingProtectionSync(masterHash: String) -> Bool {
        let norm = masterHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !norm.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return pendingProtectionSyncMasters.contains(norm)
    }

    func pendingProtectionSyncHashes() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(pendingProtectionSyncMasters)
    }

    /// Reconciles local restored-original locks with the server's authoritative `keepOriginalOnDevice` set:
    /// - Items unlocked on the webpage (`keepOriginalOnDevice == false`) are unlocked locally so they disappear
    ///   from Protected and become immediately eligible for re-proxying in Backup/Compress.
    /// - Items protected on the webpage (`keepOriginalOnDevice == true`) are protected locally too.
    @discardableResult
    func syncProtectedMasterHashesFromServer(
        _ serverProtectedHashes: Set<String>,
        scopedToHashes: Set<String>? = nil
    ) -> Bool {
        let normalizedProtected = Set(
            serverProtectedHashes
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        lock.lock()
        defer { lock.unlock() }

        var dirtyRestoredMasters = false
        var dirtyRestoredAssets = false
        var dirtyRestoredMap = false
        var dirtyUploaded = false

        // 1. Unlock locally protected items that the server says are NO LONGER protected (e.g. Allow Re-Proxy on webpage)
        let currentLocalProtected = Array(restoredMasterHashes)
        for h in currentLocalProtected {
            if let scopedToHashes, !scopedToHashes.contains(h) { continue }
            if pendingProtectionSyncMasters.contains(h) { continue }
            if !normalizedProtected.contains(h) {
                restoredMasterHashes.remove(h)
                dirtyRestoredMasters = true
                let linkedIds = restoredMasterToAssetIds.removeValue(forKey: h) ?? restoredAssetToMaster
                    .filter { $0.value == h }
                    .map(\.key)
                for assetId in linkedIds {
                    if restoredAssetIds.remove(assetId) != nil { dirtyRestoredAssets = true }
                    if restoredAssetToMaster.removeValue(forKey: assetId) != nil { dirtyRestoredMap = true }
                    if !assetId.isEmpty && !assetIds.contains(assetId) && uploadedOriginalMasterToAsset[h] == nil {
                        uploadedOriginalMasterToAsset[h] = assetId
                        uploadedOriginalAssetIds.insert(assetId)
                        dirtyUploaded = true
                    }
                }
            }
        }

        // Also sweep any orphaned restoredAssetToMaster entries whose master was unlocked on server
        for (assetId, mappedMaster) in Array(restoredAssetToMaster) {
            let norm = mappedMaster.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let scopedToHashes, !scopedToHashes.contains(norm) { continue }
            if pendingProtectionSyncMasters.contains(norm) { continue }
            if !normalizedProtected.contains(norm) {
                restoredAssetToMaster.removeValue(forKey: assetId)
                restoredMasterToAssetIds[norm]?.removeAll { $0 == assetId }
                if restoredMasterToAssetIds[norm]?.isEmpty == true {
                    restoredMasterToAssetIds.removeValue(forKey: norm)
                }
                if restoredAssetIds.remove(assetId) != nil { dirtyRestoredAssets = true }
                dirtyRestoredMap = true
                if !assetId.isEmpty && !assetIds.contains(assetId) && uploadedOriginalMasterToAsset[norm] == nil {
                    uploadedOriginalMasterToAsset[norm] = assetId
                    uploadedOriginalAssetIds.insert(assetId)
                    dirtyUploaded = true
                }
            }
        }

        // 2. Protect locally any items marked protected on the server (e.g. protected from webpage or another device)
        for h in normalizedProtected {
            if restoredMasterHashes.insert(h).inserted {
                dirtyRestoredMasters = true
            }
            if let knownOrigAsset = uploadedOriginalMasterToAsset[h],
               !knownOrigAsset.isEmpty,
               !assetIds.contains(knownOrigAsset) {
                if restoredAssetIds.insert(knownOrigAsset).inserted { dirtyRestoredAssets = true }
                if restoredAssetToMaster[knownOrigAsset] != h {
                    restoredAssetToMaster[knownOrigAsset] = h
                    dirtyRestoredMap = true
                }
                var list = restoredMasterToAssetIds[h] ?? []
                if !list.contains(knownOrigAsset) {
                    list.append(knownOrigAsset)
                    restoredMasterToAssetIds[h] = list
                }
            }
        }

        if dirtyRestoredMasters { defaults.set(Array(restoredMasterHashes), forKey: restoredMastersKey) }
        if dirtyRestoredAssets { defaults.set(Array(restoredAssetIds), forKey: restoredAssetIdsKey) }
        if dirtyRestoredMap { defaults.set(restoredAssetToMaster, forKey: restoredAssetToMasterKey) }
        if dirtyUploaded { defaults.set(uploadedOriginalMasterToAsset, forKey: uploadedOriginalMasterToAssetKey) }

        return dirtyRestoredMasters || dirtyRestoredAssets || dirtyRestoredMap
    }

    @discardableResult
    func syncProtectionStateFromServer(photos: [ServerPhoto]) -> Bool {
        var serverProtected = Set<String>()
        var allServerHashes = Set<String>()
        allServerHashes.reserveCapacity(photos.count)
        for photo in photos {
            let norm = photo.hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !norm.isEmpty else { continue }
            allServerHashes.insert(norm)
            if photo.isProtectedOriginal {
                serverProtected.insert(norm)
            }
        }
        return syncProtectedMasterHashesFromServer(serverProtected, scopedToHashes: allServerHashes)
    }

    /// Records a live original `PHAsset.localIdentifier` that was verified/uploaded to the server,
    /// allowing Cloud browsing to fetch thumbnails/playback directly from Apple Photos without duplicating media.
    func markUploadedOriginal(assetId: String, masterHash: String) {
        let normMaster = masterHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanId = assetId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normMaster.isEmpty, !cleanId.isEmpty else { return }
        lock.lock()
        uploadedOriginalAssetIds.insert(cleanId)
        if uploadedOriginalMasterToAsset[normMaster] != cleanId {
            uploadedOriginalMasterToAsset[normMaster] = cleanId
            defaults.set(uploadedOriginalMasterToAsset, forKey: uploadedOriginalMasterToAssetKey)
        }
        lock.unlock()
    }

    /// Returns `true` if `assetId` is a full-resolution original already verified/uploaded to the server.
    /// Used in Backup Only mode so originals kept on the phone are not repeatedly queued for upload.
    func isUploadedOriginal(assetId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return uploadedOriginalAssetIds.contains(assetId)
    }

    /// Returns a live `PHAsset.localIdentifier` of an uploaded original still present in Apple Photos.
    func liveUploadedOriginalAssetId(forMasterHash masterHash: String) -> String? {
        let normMaster = masterHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normMaster.isEmpty else { return nil }
        lock.lock()
        let savedId = uploadedOriginalMasterToAsset[normMaster]
        lock.unlock()
        guard let savedId, !savedId.isEmpty else { return nil }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [savedId], options: nil)
        return fetched.firstObject?.localIdentifier
    }

    /// Pure in-memory O(1) lookup of candidate Apple Photos localIdentifiers for `masterHash`,
    /// ordered by priority: restored original -> still-present uploaded original -> local compressed proxy.
    func candidateGalleryAssetIds(forMasterHash masterHash: String) -> [String] {
        let normMaster = masterHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normMaster.isEmpty else { return [] }
        lock.lock()
        let ids = candidateGalleryAssetIdsLocked(normMaster: normMaster)
        lock.unlock()
        return ids
    }

    private func candidateGalleryAssetIdsLocked(normMaster: String) -> [String] {
        var orderedIds: [String] = []
        if let restoredIds = restoredMasterToAssetIds[normMaster] {
            for assetId in restoredIds where !assetId.isEmpty {
                orderedIds.append(assetId)
            }
        }
        if let origId = uploadedOriginalMasterToAsset[normMaster], !origId.isEmpty, !orderedIds.contains(origId) {
            orderedIds.append(origId)
        }
        if let proxyId = masterToAssetId[normMaster], !proxyId.isEmpty, !orderedIds.contains(proxyId) {
            orderedIds.append(proxyId)
        }
        return orderedIds
    }

    /// Resolves live `PHAsset`s for many `masterHashes` in ONE batched PhotoKit fetch
    /// instead of N separate XPC round-trips.
    func batchResolveLiveGalleryAssets(forMasterHashes masterHashes: [String]) -> [String: PHAsset] {
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard auth == .authorized || auth == .limited, !masterHashes.isEmpty else { return [:] }

        var candidatesByHash: [String: [String]] = [:]
        candidatesByHash.reserveCapacity(masterHashes.count)
        var allUniqueIds = Set<String>()
        allUniqueIds.reserveCapacity(masterHashes.count)

        lock.lock()
        for rawHash in masterHashes {
            let norm = rawHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !norm.isEmpty, candidatesByHash[norm] == nil else { continue }
            let ids = candidateGalleryAssetIdsLocked(normMaster: norm)
            if !ids.isEmpty {
                candidatesByHash[norm] = ids
                for id in ids {
                    allUniqueIds.insert(id)
                }
            }
        }
        lock.unlock()

        guard !allUniqueIds.isEmpty else { return [:] }

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(allUniqueIds), options: nil)
        guard fetched.count > 0 else { return [:] }

        var assetsById: [String: PHAsset] = [:]
        assetsById.reserveCapacity(fetched.count)
        for i in 0..<fetched.count {
            let asset = fetched.object(at: i)
            assetsById[asset.localIdentifier] = asset
        }

        var resolved: [String: PHAsset] = [:]
        resolved.reserveCapacity(candidatesByHash.count)
        for (normHash, orderedIds) in candidatesByHash {
            for candidateId in orderedIds {
                if let asset = assetsById[candidateId] {
                    resolved[normHash] = asset
                    break
                }
            }
        }
        return resolved
    }

    /// Batch-commits reconciled proxy and uploaded-original mappings with a SINGLE UserDefaults flush
    /// instead of writing UserDefaults per item inside a large library loop.
    func batchRecordReconciledLinks(
        proxies: [(assetId: String, proxySha256: String, masterHash: String, originalName: String)],
        uploadedOriginals: [(assetId: String, masterHash: String)]
    ) {
        guard !proxies.isEmpty || !uploadedOriginals.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        var dirtyAssetIds = false
        var dirtyProxyHashes = false
        var dirtyAssetToMaster = false
        var dirtyMasterToAsset = false
        var dirtyAutoHandled = false
        var dirtyProxyHashToMaster = false
        var dirtyAssetToFilename = false
        var dirtyUploadedOriginals = false

        for item in proxies {
            let cleanId = item.assetId.trimmingCharacters(in: .whitespacesAndNewlines)
            let normMaster = item.masterHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normProxy = item.proxySha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !cleanId.isEmpty else { continue }

            if assetIds.insert(cleanId).inserted { dirtyAssetIds = true }
            if !normProxy.isEmpty && proxyHashes.insert(normProxy).inserted { dirtyProxyHashes = true }
            if !normMaster.isEmpty {
                if assetToMaster[cleanId] != normMaster {
                    assetToMaster[cleanId] = normMaster
                    dirtyAssetToMaster = true
                }
                if masterToAssetId[normMaster] != cleanId {
                    masterToAssetId[normMaster] = cleanId
                    dirtyMasterToAsset = true
                }
                if autoHandledPhotosMasters.insert(normMaster).inserted { dirtyAutoHandled = true }
                if !normProxy.isEmpty && proxyHashToMaster[normProxy] != normMaster {
                    proxyHashToMaster[normProxy] = normMaster
                    dirtyProxyHashToMaster = true
                }
            }
            if !item.originalName.isEmpty && assetToFilename[cleanId] != item.originalName {
                assetToFilename[cleanId] = item.originalName
                dirtyAssetToFilename = true
            }
        }

        for item in uploadedOriginals {
            let cleanId = item.assetId.trimmingCharacters(in: .whitespacesAndNewlines)
            let normMaster = item.masterHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !cleanId.isEmpty, !normMaster.isEmpty else { continue }
            uploadedOriginalAssetIds.insert(cleanId)
            if uploadedOriginalMasterToAsset[normMaster] != cleanId {
                uploadedOriginalMasterToAsset[normMaster] = cleanId
                dirtyUploadedOriginals = true
            }
        }

        if dirtyAssetIds { defaults.set(Array(assetIds), forKey: assetIdsKey) }
        if dirtyProxyHashes { defaults.set(Array(proxyHashes), forKey: proxyHashesKey) }
        if dirtyAssetToMaster { defaults.set(assetToMaster, forKey: assetToMasterKey) }
        if dirtyMasterToAsset { defaults.set(masterToAssetId, forKey: masterToAssetKey) }
        if dirtyAutoHandled { defaults.set(Array(autoHandledPhotosMasters), forKey: autoHandledPhotosKey) }
        if dirtyProxyHashToMaster { defaults.set(proxyHashToMaster, forKey: proxyHashToMasterKey) }
        if dirtyAssetToFilename { defaults.set(assetToFilename, forKey: assetToFilenameKey) }
        if dirtyUploadedOriginals { defaults.set(uploadedOriginalMasterToAsset, forKey: uploadedOriginalMasterToAssetKey) }
    }

    /// Returns the best live `PHAsset` currently in Apple Photos for `masterHash`,
    /// preferring restored original -> still-present uploaded original -> local compressed proxy.
    func liveGalleryAsset(forMasterHash masterHash: String) -> PHAsset? {
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard auth == .authorized || auth == .limited else { return nil }
        let orderedIds = candidateGalleryAssetIds(forMasterHash: masterHash)
        guard !orderedIds.isEmpty else { return nil }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: orderedIds, options: nil)
        guard fetched.count > 0 else { return nil }
        var byId: [String: PHAsset] = [:]
        for i in 0..<fetched.count {
            let a = fetched.object(at: i)
            byId[a.localIdentifier] = a
        }
        for candidateId in orderedIds {
            if let asset = byId[candidateId] {
                return asset
            }
        }
        return fetched.firstObject
    }

    func hasAnyLiveGalleryAsset(forMasterHash masterHash: String) -> Bool {
        liveGalleryAsset(forMasterHash: masterHash) != nil
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        assetIds.removeAll()
        proxyHashes.removeAll()
        assetToMaster.removeAll()
        assetToFilename.removeAll()
        proxyHashToMaster.removeAll()
        masterToAssetId.removeAll()
        autoHandledPhotosMasters.removeAll()
        restoredAssetIds.removeAll()
        restoredMasterHashes.removeAll()
        restoredAssetToMaster.removeAll()
        restoredMasterToAssetIds.removeAll()
        uploadedOriginalMasterToAsset.removeAll()
        uploadedOriginalAssetIds.removeAll()
        pendingProtectionSyncMasters.removeAll()
        defaults.removeObject(forKey: assetIdsKey)
        defaults.removeObject(forKey: proxyHashesKey)
        defaults.removeObject(forKey: assetToMasterKey)
        defaults.removeObject(forKey: assetToFilenameKey)
        defaults.removeObject(forKey: proxyHashToMasterKey)
        defaults.removeObject(forKey: masterToAssetKey)
        defaults.removeObject(forKey: autoHandledPhotosKey)
        defaults.removeObject(forKey: restoredAssetIdsKey)
        defaults.removeObject(forKey: restoredMastersKey)
        defaults.removeObject(forKey: restoredAssetToMasterKey)
        defaults.removeObject(forKey: uploadedOriginalMasterToAssetKey)
        defaults.removeObject(forKey: pendingProtectionSyncKey)
    }
}
