import Foundation

/// Keeps the menu bar unread badge in sync with the history store: computes the total
/// once at startup, then recomputes on every store change (new message, read here or
/// on another device, delete). Without the startup pass the badge stayed at zero until
/// the next live message arrived, even with thousands of unreads in the database.
@MainActor
final class UnreadBadgeSync: @unchecked Sendable {
    private let store: MessageStore
    private let setCount: @MainActor (Int) -> Void
    private var observer: NSObjectProtocol?

    init(store: MessageStore, setCount: @escaping @MainActor (Int) -> Void) {
        self.store = store
        self.setCount = setCount
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .historyStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    func refresh() {
        let store = self.store
        Task { @MainActor in
            let total = (try? await store.totalUnreadCount()) ?? 0
            setCount(total)
        }
    }
}
