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

    func isMasterHashActive(_ sha256: String) -> Bool {
        let norm = sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !norm.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return activeMasterHashes.contains(norm)
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

/// Ensures bounded concurrent workers commit assets into Apple Photos in strict sequential
/// index order (0, 1, 2, ...). Writing chronologically oldest-first means the newest photo
/// is always inserted LAST, so Apple Photos "Recents" and third-party share pickers
/// (WhatsApp, Telegram, Instagram, etc.) show the newest photo first — matching the Library view.
actor OrderedCommitGate {
    private var nextIndex: Int = 0
    private var skipped: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var isCancelled: Bool = false

    func waitForTurn(_ index: Int) async -> Bool {
        if Task.isCancelled {
            cancelAll()
            return false
        }
        return await withTaskCancellationHandler {
            await self.waitForTurnLocked(index)
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }

    private func waitForTurnLocked(_ index: Int) async -> Bool {
        drainSkipped()
        if isCancelled || Task.isCancelled || index < nextIndex {
            return false
        }
        if index == nextIndex {
            return true
        }
        return await withCheckedContinuation { continuation in
            if isCancelled || Task.isCancelled {
                continuation.resume(returning: false)
                return
            }
            drainSkipped()
            if index == nextIndex {
                continuation.resume(returning: true)
                return
            }
            waiters[index] = continuation
        }
    }

    func completeTurn(_ index: Int) {
        guard index >= nextIndex else { return }
        if index == nextIndex {
            nextIndex += 1
        } else {
            skipped.insert(index)
        }
        drainSkipped()
        if let waiter = waiters.removeValue(forKey: nextIndex) {
            waiter.resume(returning: !isCancelled)
        }
    }

    func cancelAll() {
        isCancelled = true
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: false)
        }
    }

    private func drainSkipped() {
        while skipped.remove(nextIndex) != nil {
            nextIndex += 1
        }
    }
}

enum PhotoChronologicalOrder {
    /// Oldest-first comparator (undated items first, then ascending capture date, then hash).
    static func areServerPhotosOldestFirst(_ lhs: ServerPhoto, _ rhs: ServerPhoto) -> Bool {
        switch (lhs.parsedCreationDate, rhs.parsedCreationDate) {
        case let (ld?, rd?) where ld != rd:
            return ld < rd
        case (.none, .some):
            return true
        case (.some, .none):
            return false
        default:
            return lhs.hash.localizedCaseInsensitiveCompare(rhs.hash) == .orderedAscending
        }
    }

    static func sortServerPhotosOldestFirst(_ photos: [ServerPhoto]) -> [ServerPhoto] {
        photos.sorted(by: areServerPhotosOldestFirst)
    }

    /// Oldest-first comparator for local library candidates when writing compressed proxies.
    static func areCandidatesOldestFirst(_ lhs: PhotoCandidate, _ rhs: PhotoCandidate) -> Bool {
        switch (lhs.creationDate, rhs.creationDate) {
        case let (ld?, rd?) where ld != rd:
            return ld < rd
        case (.none, .some):
            return true
        case (.some, .none):
            return false
        default:
            return lhs.id < rhs.id
        }
    }

    static func sortCandidatesOldestFirst(_ items: [PhotoCandidate]) -> [PhotoCandidate] {
        items.sorted(by: areCandidatesOldestFirst)
    }
}
