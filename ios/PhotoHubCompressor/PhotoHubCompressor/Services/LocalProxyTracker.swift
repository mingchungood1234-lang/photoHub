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
    private var uploadedOriginalMasterToAsset: [String: String]

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
        self.restoredAssetToMaster = defaults.dictionary(forKey: restoredAssetToMasterKey) as? [String: String] ?? [:]
        self.uploadedOriginalMasterToAsset = defaults.dictionary(forKey: uploadedOriginalMasterToAssetKey) as? [String: String] ?? [:]
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
        let candidateIds = restoredAssetToMaster
            .filter { $0.value == normMaster }
            .map(\.key)
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
        let matchingAssetIds = restoredAssetToMaster
            .filter { $0.value == normMaster }
            .map(\.key)
        for assetId in matchingAssetIds {
            restoredAssetIds.remove(assetId)
            restoredAssetToMaster.removeValue(forKey: assetId)
        }
        defaults.set(Array(restoredMasterHashes), forKey: restoredMastersKey)
        defaults.set(Array(restoredAssetIds), forKey: restoredAssetIdsKey)
        defaults.set(restoredAssetToMaster, forKey: restoredAssetToMasterKey)
        lock.unlock()
    }

    /// Records a live original `PHAsset.localIdentifier` that was verified/uploaded to the server,
    /// allowing Cloud browsing to fetch thumbnails/playback directly from Apple Photos without duplicating media.
    func markUploadedOriginal(assetId: String, masterHash: String) {
        let normMaster = masterHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanId = assetId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normMaster.isEmpty, !cleanId.isEmpty else { return }
        lock.lock()
        if uploadedOriginalMasterToAsset[normMaster] != cleanId {
            uploadedOriginalMasterToAsset[normMaster] = cleanId
            defaults.set(uploadedOriginalMasterToAsset, forKey: uploadedOriginalMasterToAssetKey)
        }
        lock.unlock()
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

    /// Returns the best live `PHAsset` currently in Apple Photos for `masterHash`,
    /// preferring restored original -> still-present uploaded original -> local compressed proxy.
    func liveGalleryAsset(forMasterHash masterHash: String) -> PHAsset? {
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard auth == .authorized || auth == .limited else { return nil }
        let normMaster = masterHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normMaster.isEmpty else { return nil }

        lock.lock()
        var orderedIds: [String] = []
        for (assetId, mapped) in restoredAssetToMaster where mapped == normMaster {
            if !assetId.isEmpty { orderedIds.append(assetId) }
        }
        if let origId = uploadedOriginalMasterToAsset[normMaster], !origId.isEmpty, !orderedIds.contains(origId) {
            orderedIds.append(origId)
        }
        if let proxyId = masterToAssetId[normMaster], !proxyId.isEmpty, !orderedIds.contains(proxyId) {
            orderedIds.append(proxyId)
        }
        lock.unlock()

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
        uploadedOriginalMasterToAsset.removeAll()
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
    }
}
