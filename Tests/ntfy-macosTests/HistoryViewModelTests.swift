import XCTest
@testable import ntfy_macos

/// The database holds every catch-up message as unread, so without a global
/// "mark everything read" the user has to clear topics one by one. These tests
/// pin that markEverythingRead empties the unread counts locally for all topics
/// (and deliberately does not replay thousands of clear events to the server).
@MainActor
final class HistoryViewModelTests: XCTestCase {

    private func makeMessage(id: String, topic: String) -> NtfyMessage {
        NtfyMessage(
            id: id, time: 1_700_000_000, event: "message", topic: topic,
            message: "body", title: nil, priority: 3, tags: nil,
            click: nil, actions: nil, attachment: nil, contentType: nil, sequenceId: nil
        )
    }

    func testMarkEverythingReadClearsAllTopicsLocally() async throws {
        let store = try MessageStore.inMemory()
        try await store.upsert(makeMessage(id: "a1", topic: "alpha"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "a2", topic: "alpha"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "b1", topic: "beta"), serverURL: "https://s.example")

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        try await waitUntil { vm.totalUnread == 3 }

        vm.markEverythingRead()

        try await waitUntil { vm.totalUnread == 0 }
        let counts = try await store.unreadCountsByTopic()
        XCTAssertTrue(counts.isEmpty)
    }

    func testMarkEverythingReadIsNoopWhenNothingUnread() async throws {
        let store = try MessageStore.inMemory()
        try await store.upsert(makeMessage(id: "a1", topic: "alpha"), serverURL: "https://s.example")
        try await store.markAllRead(serverURL: "https://s.example", topic: "alpha")

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        try await waitUntil { vm.totalUnread == 0 }

        vm.markEverythingRead()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(vm.totalUnread, 0)
    }

    private func waitUntil(timeoutSeconds: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met before timeout")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
