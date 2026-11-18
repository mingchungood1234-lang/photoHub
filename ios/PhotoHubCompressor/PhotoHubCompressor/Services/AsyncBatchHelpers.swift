import Foundation

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
