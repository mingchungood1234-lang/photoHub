import Foundation

/// Persists locally compressed proxy identifiers and SHA-256 hashes so we never re-upload a proxy as a master.
final class LocalProxyTracker {
    private let defaults = UserDefaults.standard
    private let assetIdsKey = "photohub_proxy_asset_ids"
    private let proxyHashesKey = "photohub_proxy_sha256_hashes"

    private var assetIds: Set<String>
    private var proxyHashes: Set<String>

    init() {
        self.assetIds = Set(defaults.stringArray(forKey: assetIdsKey) ?? [])
        self.proxyHashes = Set(defaults.stringArray(forKey: proxyHashesKey) ?? [])
    }

    func isKnownProxy(assetId: String) -> Bool {
        assetIds.contains(assetId)
    }

    func isKnownProxy(sha256: String) -> Bool {
        proxyHashes.contains(sha256.lowercased())
    }

    func markAsProxy(assetId: String, proxySha256: String) {
        assetIds.insert(assetId)
        proxyHashes.insert(proxySha256.lowercased())
        defaults.set(Array(assetIds), forKey: assetIdsKey)
        defaults.set(Array(proxyHashes), forKey: proxyHashesKey)
    }

    func clearAll() {
        assetIds.removeAll()
        proxyHashes.removeAll()
        defaults.removeObject(forKey: assetIdsKey)
        defaults.removeObject(forKey: proxyHashesKey)
    }
}
