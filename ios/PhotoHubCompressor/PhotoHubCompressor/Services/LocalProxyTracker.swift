import Foundation

/// Persists locally compressed proxy identifiers, SHA-256 hashes, and master-hash mappings
/// so proxies are never re-uploaded and can be resolved back to their original master on the server.
final class LocalProxyTracker {
    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private let assetIdsKey = "photohub_proxy_asset_ids"
    private let proxyHashesKey = "photohub_proxy_sha256_hashes"
    private let assetToMasterKey = "photohub_proxy_asset_to_master"
    private let assetToFilenameKey = "photohub_proxy_asset_to_filename"
    private let proxyHashToMasterKey = "photohub_proxy_hash_to_master"

    private var assetIds: Set<String>
    private var proxyHashes: Set<String>
    private var assetToMaster: [String: String]
    private var assetToFilename: [String: String]
    private var proxyHashToMaster: [String: String]

    init() {
        self.assetIds = Set(defaults.stringArray(forKey: assetIdsKey) ?? [])
        self.proxyHashes = Set(defaults.stringArray(forKey: proxyHashesKey) ?? [])
        self.assetToMaster = defaults.dictionary(forKey: assetToMasterKey) as? [String: String] ?? [:]
        self.assetToFilename = defaults.dictionary(forKey: assetToFilenameKey) as? [String: String] ?? [:]
        self.proxyHashToMaster = defaults.dictionary(forKey: proxyHashToMasterKey) as? [String: String] ?? [:]
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

    func masterHash(forProxySha256 sha256: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return proxyHashToMaster[sha256.lowercased()]
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
        proxyHashes.insert(normProxy)
        defaults.set(Array(assetIds), forKey: assetIdsKey)
        defaults.set(Array(proxyHashes), forKey: proxyHashesKey)

        if let masterHash, !masterHash.isEmpty {
            let normMaster = masterHash.lowercased()
            assetToMaster[assetId] = normMaster
            proxyHashToMaster[normProxy] = normMaster
            defaults.set(assetToMaster, forKey: assetToMasterKey)
            defaults.set(proxyHashToMaster, forKey: proxyHashToMasterKey)
        }

        if let originalName, !originalName.isEmpty {
            assetToFilename[assetId] = originalName
            defaults.set(assetToFilename, forKey: assetToFilenameKey)
        }
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        assetIds.removeAll()
        proxyHashes.removeAll()
        assetToMaster.removeAll()
        assetToFilename.removeAll()
        proxyHashToMaster.removeAll()
        defaults.removeObject(forKey: assetIdsKey)
        defaults.removeObject(forKey: proxyHashesKey)
        defaults.removeObject(forKey: assetToMasterKey)
        defaults.removeObject(forKey: assetToFilenameKey)
        defaults.removeObject(forKey: proxyHashToMasterKey)
    }
}
