import Foundation

extension Notification.Name {
    static let photoHubUploadCoordinatorDidChange = Notification.Name("photoHub.uploadCoordinatorDidChange")
    static let photoHubServerSyncCompleted = Notification.Name("photoHub.serverSyncCompleted")
}

enum UploadOwner: String, Sendable {
    case manual
    case background
}

/// Shared coordinator across manual uploads, silent background scans, and OS `URLSession.background` jobs
/// so the same asset or master SHA-256 is never uploaded, compressed, or saved as a proxy twice concurrently.
final class AssetUploadCoordinator: @unchecked Sendable {
    static let shared = AssetUploadCoordinator()

    private let lock = NSLock()
    private var activeByAssetId: [String: UploadOwner] = [:]
    private var activeMasterHashes: Set<String> = []

    private init() {}

    func syncPersistedBackgroundAssetIds(_ assetIds: Set<String>) {
        guard !assetIds.isEmpty else { return }
        var changed = false
        lock.lock()
        for assetId in assetIds where activeByAssetId[assetId] == nil {
            activeByAssetId[assetId] = .background
            changed = true
        }
        lock.unlock()
        if changed {
            notifyChanged()
        }
    }

    func tryClaimAsset(_ assetId: String, owner: UploadOwner) -> Bool {
        lock.lock()
        guard activeByAssetId[assetId] == nil else {
            lock.unlock()
            return false
        }
        activeByAssetId[assetId] = owner
        lock.unlock()
        notifyChanged()
        return true
    }

    func releaseAsset(_ assetId: String, owner: UploadOwner? = nil) {
        lock.lock()
        let shouldRemove: Bool
        if let current = activeByAssetId[assetId] {
            shouldRemove = (owner == nil || current == owner)
        } else {
            shouldRemove = false
        }
        if shouldRemove {
            activeByAssetId.removeValue(forKey: assetId)
        }
        lock.unlock()
        if shouldRemove {
            notifyChanged()
        }
    }

    func isAssetActive(_ assetId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeByAssetId[assetId] != nil
    }

    func isClaimedByBackground(_ assetId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeByAssetId[assetId] == .background
    }

    func activeAssetIds() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(activeByAssetId.keys)
    }

    func backgroundActiveAssetIds() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(activeByAssetId.compactMap { $0.value == .background ? $0.key : nil })
    }

    func tryClaimMasterHash(_ sha256: String) -> Bool {
        let norm = sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !norm.isEmpty else { return true }
        lock.lock()
        let inserted = activeMasterHashes.insert(norm).inserted
        lock.unlock()
        return inserted
    }

    func releaseMasterHash(_ sha256: String) {
        let norm = sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !norm.isEmpty else { return }
        lock.lock()
        activeMasterHashes.remove(norm)
        lock.unlock()
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .photoHubUploadCoordinatorDidChange, object: nil)
        }
    }
}

/// Thread-safe work queue shared by bounded concurrent workers in `withTaskGroup`.
actor AsyncWorkQueue<Element: Sendable> {
    private let items: [Element]
    private var index = 0

    init(_ items: [Element]) {
        self.items = items
    }

    func next() -> Element? {
        guard index < items.count else { return nil }
        let value = items[index]
        index += 1
        return value
    }
}

/// Cooperative async counting semaphore for throttling heavy video encodes or PhotoKit write transactions.
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.permits = max(1, value)
    }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let nextWaiter = waiters.removeFirst()
            nextWaiter.resume()
        } else {
            permits += 1
        }
    }
}
