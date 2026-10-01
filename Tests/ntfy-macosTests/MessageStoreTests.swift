import XCTest
@testable import ntfy_macos

final class MessageStoreTests: XCTestCase {
    private var store: MessageStore!

    override func setUpWithError() throws {
        store = try MessageStore.inMemory()
    }

    override func tearDownWithError() throws {
        store = nil
    }

    // MARK: - Helpers

    private func makeMessage(
        id: String = "abc123",
        topic: String = "alerts",
        time: Int = 1_700_000_000,
        title: String? = "Test title",
        message: String? = "Test body",
        priority: Int? = 3,
        tags: [String]? = ["warning"],
        sequenceId: String? = nil,
        event: String = "message"
    ) -> NtfyMessage {
        NtfyMessage(
            id: id,
            time: time,
            event: event,
            topic: topic,
            message: message,
            title: title,
            priority: priority,
            tags: tags,
            click: nil,
            actions: nil,
            attachment: nil,
            contentType: nil,
            sequenceId: sequenceId
        )
    }

    // MARK: - Upsert

    func testUpsertAndFetch() async throws {
        try await store.upsert(makeMessage(), serverURL: "https://ntfy.example.com")

        let messages = try await store.messages(serverURL: "https://ntfy.example.com", topic: "alerts")
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].message.id, "abc123")
        XCTAssertEqual(messages[0].message.title, "Test title")
        XCTAssertEqual(messages[0].message.priority, 3)
        XCTAssertEqual(messages[0].message.tags, ["warning"])
        XCTAssertFalse(messages[0].isRead)
        XCTAssertFalse(messages[0].isDeleted)
    }

    func testUpsertIsIdempotent() async throws {
        let message = makeMessage()
        try await store.upsert(message, serverURL: "https://ntfy.example.com")
        try await store.upsert(message, serverURL: "https://ntfy.example.com")

        let messages = try await store.messages(serverURL: "https://ntfy.example.com", topic: "alerts")
        XCTAssertEqual(messages.count, 1)
    }

    func testUpsertDoesNotOverwriteReadState() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")
        try await store.markRead(true, serverURL: "https://s.example", topic: "alerts", messageID: "m1")

        // Poll replay of the same message must not reset read state
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")

        let messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertTrue(messages[0].isRead)
    }

    func testUpsertDoesNotResurrectDeletedMessage() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")
        try await store.tombstoneMessage(serverURL: "https://s.example", topic: "alerts", messageID: "m1")

        // Poll replay after local delete must not bring the message back
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")

        let messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertTrue(messages.isEmpty)
    }

    // MARK: - Ordering & Pagination

    func testMessagesOrderedNewestFirst() async throws {
        for (index, time) in [100, 300, 200].enumerated() {
            try await store.upsert(makeMessage(id: "m\(index)", time: time), serverURL: "https://s.example")
        }

        let messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(messages.map { $0.message.time }, [300, 200, 100])
    }

    func testPaginationWithBeforeTimeCursor() async throws {
        for index in 0..<10 {
            try await store.upsert(makeMessage(id: "m\(index)", time: 1_000 + index), serverURL: "https://s.example")
        }

        let firstPage = try await store.messages(serverURL: "https://s.example", topic: "alerts", limit: 4)
        XCTAssertEqual(firstPage.map { $0.message.time }, [1009, 1008, 1007, 1006])

        let secondPage = try await store.messages(
            serverURL: "https://s.example", topic: "alerts", limit: 4,
            beforeTime: firstPage.last?.time
        )
        XCTAssertEqual(secondPage.map { $0.message.time }, [1005, 1004, 1003, 1002])
    }

    func testMessageCount() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m2"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m3", topic: "other"), serverURL: "https://s.example")
        try await store.tombstoneMessage(serverURL: "https://s.example", topic: "alerts", messageID: "m2")

        let alertsCount = try await store.messageCount(serverURL: "https://s.example", topic: "alerts")
        let otherCount = try await store.messageCount(serverURL: "https://s.example", topic: "other")
        XCTAssertEqual(alertsCount, 1)
        XCTAssertEqual(otherCount, 1)
    }

    // MARK: - Read state

    func testMarkReadAndUnread() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")

        try await store.markRead(true, serverURL: "https://s.example", topic: "alerts", messageID: "m1")
        var messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertTrue(messages[0].isRead)

        try await store.markRead(false, serverURL: "https://s.example", topic: "alerts", messageID: "m1")
        messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertFalse(messages[0].isRead)
    }

    func testMarkAllRead() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m2"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m3", topic: "other"), serverURL: "https://s.example")

        try await store.markAllRead(serverURL: "https://s.example", topic: "alerts")

        let alerts = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertTrue(alerts.allSatisfy { $0.isRead })

        // Other topic untouched
        let others = try await store.messages(serverURL: "https://s.example", topic: "other")
        XCTAssertFalse(others[0].isRead)
    }

    func testUnreadCountsByTopic() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m2"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m3", topic: "other"), serverURL: "https://s2.example")

        try await store.markRead(true, serverURL: "https://s.example", topic: "alerts", messageID: "m1")

        let counts = try await store.unreadCountsByTopic()
        XCTAssertEqual(counts[TopicRef(serverURL: "https://s.example", topic: "alerts")], 1)
        XCTAssertEqual(counts[TopicRef(serverURL: "https://s2.example", topic: "other")], 1)
    }

    func testUnreadIgnoresDeletedMessages() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")
        try await store.tombstoneMessage(serverURL: "https://s.example", topic: "alerts", messageID: "m1")

        let counts = try await store.unreadCountsByTopic()
        XCTAssertTrue(counts.isEmpty)
        let total = try await store.totalUnreadCount()
        XCTAssertEqual(total, 0)
    }

    // MARK: - Tombstones

    func testTombstoneMessage() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")

        let affected = try await store.tombstoneMessage(serverURL: "https://s.example", topic: "alerts", messageID: "m1")
        XCTAssertTrue(affected)

        let messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertTrue(messages.isEmpty)
    }

    func testTombstoneAll() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m2"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m3", topic: "other"), serverURL: "https://s.example")

        try await store.tombstoneAll(serverURL: "https://s.example", topic: "alerts")

        let remaining = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        let otherCount = try await store.messageCount(serverURL: "https://s.example", topic: "other")
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(otherCount, 1)
    }

    // MARK: - Delete events

    func testApplyDeleteEventBySequenceID() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: "seq-1"), serverURL: "https://s.example")

        // Server delete events carry a fresh event id, with sequence_id pointing at the target
        let affected = try await store.applyDeleteEvent(
            serverURL: "https://s.example", topic: "alerts",
            targetSequenceID: "seq-1", targetMessageID: "evt-random"
        )
        XCTAssertTrue(affected)
        let remaining = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertTrue(remaining.isEmpty)
    }

    func testApplyDeleteEventByMessageID() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: nil), serverURL: "https://s.example")

        let affected = try await store.applyDeleteEvent(
            serverURL: "https://s.example", topic: "alerts",
            targetSequenceID: nil, targetMessageID: "m1"
        )
        XCTAssertTrue(affected)
        let remaining = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertTrue(remaining.isEmpty)
    }

    func testApplyDeleteEventNoMatch() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")

        let affected = try await store.applyDeleteEvent(
            serverURL: "https://s.example", topic: "alerts",
            targetSequenceID: "nope", targetMessageID: "also-nope"
        )
        XCTAssertFalse(affected)
        let count = try await store.messageCount(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(count, 1)
    }

    // MARK: - Action events (delete vs. clear/read)

    /// `/<topic>/<seq>/read|clear` makes the server broadcast message_clear, which means
    /// "mark as read" — never "remove the message".
    func testClearEventMarksReadAndKeepsMessage() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: "seq-1"), serverURL: "https://s.example")
        var unread = try await store.totalUnreadCount()
        XCTAssertEqual(unread, 1)

        let affected = try await store.applyActionEvent(
            makeMessage(id: "evt-fresh", sequenceId: "seq-1", event: NtfyMessage.clearEvent),
            serverURL: "https://s.example"
        )
        XCTAssertTrue(affected)

        let messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].isRead)
        XCTAssertFalse(messages[0].isDeleted)
        unread = try await store.totalUnreadCount()
        XCTAssertEqual(unread, 0)
    }

    func testDeleteEventStillTombstones() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: "seq-1"), serverURL: "https://s.example")

        let affected = try await store.applyActionEvent(
            makeMessage(id: "evt-fresh", sequenceId: "seq-1", event: NtfyMessage.deleteEvent),
            serverURL: "https://s.example"
        )
        XCTAssertTrue(affected)
        let remaining = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertTrue(remaining.isEmpty)
    }

    /// Our client puts `sequence_id ?? message_id` in the URL, so a clear event for a message
    /// that has no sequence id carries that message id as its sequence_id.
    func testClearEventMatchesMessageWithoutSequenceID() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: nil), serverURL: "https://s.example")

        let affected = try await store.applyActionEvent(
            makeMessage(id: "evt-fresh", sequenceId: "m1", event: NtfyMessage.clearEvent),
            serverURL: "https://s.example"
        )
        XCTAssertTrue(affected)

        let messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].isRead)
    }

    func testClearEventIgnoresUnknownAndDeletedTargets() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: "seq-1"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m2", time: 1_700_000_001, sequenceId: "seq-2"), serverURL: "https://s.example")
        try await store.tombstoneMessage(serverURL: "https://s.example", topic: "alerts", messageID: "m2")

        let unknown = try await store.applyActionEvent(
            makeMessage(id: "evt", sequenceId: "nope", event: NtfyMessage.clearEvent),
            serverURL: "https://s.example"
        )
        XCTAssertFalse(unknown)

        let onTombstone = try await store.applyActionEvent(
            makeMessage(id: "evt", sequenceId: "seq-2", event: NtfyMessage.clearEvent),
            serverURL: "https://s.example"
        )
        XCTAssertFalse(onTombstone)
        let unread = try await store.totalUnreadCount()
        XCTAssertEqual(unread, 1)
    }

    /// A clear event replayed by `since=` must not duplicate or resurrect anything.
    func testClearEventIsIdempotent() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: "seq-1"), serverURL: "https://s.example")
        let event = makeMessage(id: "evt", sequenceId: "seq-1", event: NtfyMessage.clearEvent)

        try await store.applyActionEvent(event, serverURL: "https://s.example")
        try await store.applyActionEvent(event, serverURL: "https://s.example")

        let messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].isRead)
        XCTAssertFalse(messages[0].isDeleted)
    }

    // MARK: - Action event target lookup

    /// Revoking a banner needs the id the message was delivered under, not the sequence id
    /// the event carries.
    func testTargetMessageIDResolvesFromRealSequenceID() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: "seq-1"), serverURL: "https://s.example")
        let resolved = try await store.targetMessageID(
            for: makeMessage(id: "evt", sequenceId: "seq-1", event: NtfyMessage.clearEvent),
            serverURL: "https://s.example"
        )
        XCTAssertEqual(resolved, "m1")
    }

    /// Without a sequence id the event echoes back the message id we put in the URL.
    func testTargetMessageIDResolvesFromEchoedMessageID() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: nil), serverURL: "https://s.example")
        let resolved = try await store.targetMessageID(
            for: makeMessage(id: "evt", sequenceId: "m1", event: NtfyMessage.clearEvent),
            serverURL: "https://s.example"
        )
        XCTAssertEqual(resolved, "m1")
    }

    /// A delete event still has to resolve its target after the row is tombstoned — that is
    /// precisely the moment the banner has to go.
    func testTargetMessageIDResolvesTombstonedRow() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: "seq-1"), serverURL: "https://s.example")
        try await store.applyActionEvent(
            makeMessage(id: "evt", sequenceId: "seq-1", event: NtfyMessage.deleteEvent),
            serverURL: "https://s.example"
        )
        let resolved = try await store.targetMessageID(
            for: makeMessage(id: "evt", sequenceId: "seq-1", event: NtfyMessage.deleteEvent),
            serverURL: "https://s.example"
        )
        XCTAssertEqual(resolved, "m1")
    }

    func testTargetMessageIDIgnoresUnknownAndForeignTargets() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: "seq-1"), serverURL: "https://s.example")

        let unknown = try await store.targetMessageID(
            for: makeMessage(id: "evt", sequenceId: "nope", event: NtfyMessage.deleteEvent),
            serverURL: "https://s.example"
        )
        XCTAssertNil(unknown)

        let otherServer = try await store.targetMessageID(
            for: makeMessage(id: "evt", sequenceId: "seq-1", event: NtfyMessage.deleteEvent),
            serverURL: "https://other.example"
        )
        XCTAssertNil(otherServer)

        let otherTopic = try await store.targetMessageID(
            for: makeMessage(id: "evt", topic: "other", sequenceId: "seq-1", event: NtfyMessage.deleteEvent),
            serverURL: "https://s.example"
        )
        XCTAssertNil(otherTopic)
    }

    // MARK: - Search

    func testSearchFilter() async throws {
        try await store.upsert(makeMessage(id: "m1", title: "Deploy failed", message: "service crashed"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m2", title: "Backup done", message: "all good"), serverURL: "https://s.example")

        let results = try await store.messages(serverURL: "https://s.example", topic: "alerts", searchText: "deploy")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].message.id, "m1")
    }

    func testSearchFilterOnlyUnread() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m2"), serverURL: "https://s.example")
        try await store.markRead(true, serverURL: "https://s.example", topic: "alerts", messageID: "m1")

        let unread = try await store.messages(serverURL: "https://s.example", topic: "alerts", onlyUnread: true)
        XCTAssertEqual(unread.map { $0.message.id }, ["m2"])
    }

    // MARK: - Sync state

    func testSyncStateRoundtrip() async throws {
        var info = try await store.latestSyncedInfo(serverURL: "https://s.example", topic: "alerts")
        XCTAssertNil(info)

        try await store.setSyncedInfo(serverURL: "https://s.example", topic: "alerts", id: "abc", time: 1_234)
        info = try await store.latestSyncedInfo(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(info?.id, "abc")
        XCTAssertEqual(info?.time, 1_234)

        // Upsert overwrites
        try await store.setSyncedInfo(serverURL: "https://s.example", topic: "alerts", id: "def", time: 5_678)
        info = try await store.latestSyncedInfo(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(info?.id, "def")
        XCTAssertEqual(info?.time, 5_678)
    }

    // MARK: - Isolation between servers

    func testServerIsolation() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://a.example")
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://b.example")

        // Same msg_id on different servers are distinct rows
        let aCount = try await store.messageCount(serverURL: "https://a.example", topic: "alerts")
        let bCount = try await store.messageCount(serverURL: "https://b.example", topic: "alerts")
        XCTAssertEqual(aCount, 1)
        XCTAssertEqual(bCount, 1)
    }
}
