import XCTest
@testable import ntfy_macos

/// End-to-end tests for the history pipeline against a real ntfy server (ntfy.sh):
/// publish → poll (since) → on-disk SQLite store → read/delete operations.
final class HistoryE2ETests: XCTestCase {

    private static let serverURL = "https://ntfy.sh"

    private func makeRandomTopic() -> String {
        "ntfy-macos-hist-e2e-" + UUID().uuidString.prefix(8).lowercased()
    }

    private static func publish(topic: String, title: String? = nil, body: String) async throws {
        var request = URLRequest(url: URL(string: "\(serverURL)/\(topic)")!)
        request.httpMethod = "POST"
        if let title {
            request.setValue(title, forHTTPHeaderField: "Title")
        }
        request.httpBody = body.data(using: .utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(status, 200, "publish failed with HTTP \(status)")
    }

    @MainActor
    func testPollStoreReadDeletePipeline() async throws {
        let topic = makeRandomTopic()
        let dbPath = NSTemporaryDirectory() + "hist-e2e-\(UUID().uuidString).db"
        let store = try MessageStore(dbPath: dbPath)
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        // 1. Publish three messages
        try await Self.publish(topic: topic, title: "First", body: "one")
        try await Self.publish(topic: topic, title: "Second", body: "two")
        try await Self.publish(topic: topic, title: "Third", body: "three")

        // ntfy.sh caches asynchronously — small settle delay
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // 2. Full poll into the store
        let sync = HistorySyncService(store: store)
        let ref = TopicRef(serverURL: Self.serverURL, topic: topic)
        await sync.syncFull(ref)

        let stored = try await store.messages(serverURL: Self.serverURL, topic: topic)
        XCTAssertEqual(stored.count, 3, "expected 3 polled messages, got \(stored.count)")
        XCTAssertEqual(stored.first?.message.title, "Third", "messages should be ordered newest first")

        // Sync state advanced to the newest message
        let syncInfo = try await store.latestSyncedInfo(serverURL: Self.serverURL, topic: topic)
        XCTAssertNotNil(syncInfo?.id)

        // 3. Publish one more and do an incremental sync — only the new one arrives
        try await Self.publish(topic: topic, title: "Fourth", body: "four")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        await sync.syncIncremental(ref)

        let afterIncremental = try await store.messages(serverURL: Self.serverURL, topic: topic)
        XCTAssertEqual(afterIncremental.count, 4, "incremental sync should only add the new message")
        XCTAssertEqual(afterIncremental.first?.message.title, "Fourth")

        // 4. Mark all read → unread count empty
        try await store.markAllRead(serverURL: Self.serverURL, topic: topic)
        let unread = try await store.unreadCountsByTopic()
        XCTAssertNil(unread[ref])

        // 5. Mark one unread again, delete it locally + on server
        let target = afterIncremental[0]
        try await store.markRead(false, serverURL: Self.serverURL, topic: topic, messageID: target.message.id)

        let deleted = try await store.tombstoneMessage(
            serverURL: Self.serverURL, topic: topic, messageID: target.message.id
        )
        XCTAssertTrue(deleted)
        await MessageActionService.deleteOnServer(
            serverURL: Self.serverURL, topic: topic,
            sequenceID: target.message.sequenceId, messageID: target.message.id,
            authToken: nil
        )

        let remaining = try await store.messages(serverURL: Self.serverURL, topic: topic)
        XCTAssertEqual(remaining.count, 3)
        XCTAssertFalse(remaining.contains { $0.message.id == target.message.id })

        // 6. Poll replay must not resurrect the deleted message
        await sync.syncFull(ref)
        let afterReplay = try await store.messages(serverURL: Self.serverURL, topic: topic)
        XCTAssertFalse(afterReplay.contains { $0.message.id == target.message.id },
                       "tombstoned message must survive a full poll replay")

        // Cleanup: delete remaining messages server-side (best effort)
        for message in afterReplay {
            await MessageActionService.deleteOnServer(
                serverURL: Self.serverURL, topic: topic,
                sequenceID: message.message.sequenceId, messageID: message.message.id,
                authToken: nil
            )
        }
    }

    /// A server-side `message_clear` must be applied as *read*, never as a delete, and a
    /// device that has never seen the topic must inherit the read state on its first full
    /// sync — the poll replays the event after its target message (ascending order).
    @MainActor
    func testServerMarkReadReplaysAsReadNotDelete() async throws {
        let topic = makeRandomTopic()
        let ref = TopicRef(serverURL: Self.serverURL, topic: topic)

        try await Self.publish(topic: topic, title: "Alpha", body: "alpha")
        try await Self.publish(topic: topic, title: "Beta", body: "beta")
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // Device A: sync, then mark one message read locally + on the server.
        let pathA = NSTemporaryDirectory() + "hist-read-e2e-A-\(UUID().uuidString).db"
        let storeA = try MessageStore(dbPath: pathA)
        defer { try? FileManager.default.removeItem(atPath: pathA) }

        await HistorySyncService(store: storeA).syncFull(ref)
        let onA = try await storeA.messages(serverURL: Self.serverURL, topic: topic)
        XCTAssertEqual(onA.count, 2, "both published messages should be polled")

        let target = onA.first { $0.message.title == "Alpha" } ?? onA[0]
        try await storeA.markRead(true, serverURL: Self.serverURL, topic: topic, messageID: target.message.id)
        let accepted = await MessageActionService.markReadOnServer(
            serverURL: Self.serverURL, topic: topic,
            sequenceID: target.message.sequenceId, messageID: target.message.id,
            authToken: nil
        )
        XCTAssertTrue(accepted, "server should accept GET /<topic>/<id>/read")

        // The clear event has to land in the server cache before a second device replays it.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // Device B: fresh store, first-ever sync.
        let pathB = NSTemporaryDirectory() + "hist-read-e2e-B-\(UUID().uuidString).db"
        let storeB = try MessageStore(dbPath: pathB)
        defer { try? FileManager.default.removeItem(atPath: pathB) }

        await HistorySyncService(store: storeB).syncFull(ref)
        let onB = try await storeB.messages(serverURL: Self.serverURL, topic: topic)
        XCTAssertEqual(onB.count, 2, "message_clear must mark read, not delete")
        XCTAssertEqual(onB.first { $0.message.id == target.message.id }?.isRead, true,
                       "read state must come from the replayed message_clear event")
        XCTAssertEqual(onB.filter { $0.isRead }.count, 1)
        XCTAssertEqual(onB.filter { !$0.isRead }.count, 1)

        // Cleanup (best effort)
        for message in onB {
            await MessageActionService.deleteOnServer(
                serverURL: Self.serverURL, topic: topic,
                sequenceID: message.message.sequenceId, messageID: message.message.id,
                authToken: nil
            )
        }
    }
}
