import XCTest
@testable import ntfy_macos

// MARK: - Mock URLProtocol for server mark-read tests

/// Records the paths of intercepted mark-read requests and answers with a fixed
/// status, so cap and partial-failure behavior can be asserted without a server.
private final class MarkReadMockProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _paths: [String] = []
    nonisolated(unsafe) private static var _status = 200

    static var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }
    static func reset(status: Int) {
        lock.lock(); _paths = []; _status = status; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MarkReadMockProtocol.lock.lock()
        MarkReadMockProtocol._paths.append(MarkReadMockProtocol.requestPath(for: request))
        let status = MarkReadMockProtocol._status
        MarkReadMockProtocol.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func requestPath(for request: URLRequest) -> String {
        (request.url?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private func markReadMockSession(status: Int) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MarkReadMockProtocol.self]
    MarkReadMockProtocol.reset(status: status)
    return URLSession(configuration: config)
}

/// The database holds every catch-up message as unread, so without a global
/// "mark everything read" the user has to clear topics one by one. These tests
/// pin that markEverythingRead empties the unread counts locally for all topics
/// (and deliberately does not replay thousands of clear events to the server).
@MainActor
final class HistoryViewModelTests: XCTestCase {

    private func makeMessage(id: String, topic: String, time: Int = 1_700_000_000) -> NtfyMessage {
        NtfyMessage(
            id: id, time: time, event: "message", topic: topic,
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

    // MARK: - Mark-all-read server sync cap (audit 2.1)

    func testMarkAllReadCapsServerSyncToNewestTargets() async throws {
        let store = try MessageStore.inMemory()
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")
        let count = HistoryViewModel.serverMarkReadCap + 10
        for i in 0..<count {
            try await store.upsert(
                makeMessage(id: "msg\(i)", topic: "alpha", time: 1_700_000_000 + i),
                serverURL: ref.serverURL
            )
        }

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        vm.serverMarkReadSession = markReadMockSession(status: 200)

        vm.markAllRead(for: ref)

        try await waitUntil { vm.markReadSyncNotice != nil }
        let ids = MarkReadMockProtocol.paths.map { $0.components(separatedBy: "/")[1] }
        XCTAssertEqual(ids.count, HistoryViewModel.serverMarkReadCap)
        XCTAssertEqual(ids.first, "msg\(count - 1)")  // newest first
        XCTAssertFalse(ids.contains("msg0"))          // oldest stayed local-only
        XCTAssertTrue(vm.markReadSyncNotice!.contains("限速保护"))

        // Locally everything is read regardless of the cap.
        let counts = try await store.unreadCountsByTopic()
        XCTAssertTrue(counts.isEmpty)
    }

    func testMarkAllReadWithinCapSyncsEveryTargetSilently() async throws {
        let store = try MessageStore.inMemory()
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")
        for i in 0..<3 {
            try await store.upsert(makeMessage(id: "msg\(i)", topic: "alpha"), serverURL: ref.serverURL)
        }

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        vm.serverMarkReadSession = markReadMockSession(status: 200)

        vm.markAllRead(for: ref)

        try await waitUntil { MarkReadMockProtocol.paths.count == 3 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(vm.markReadSyncNotice)  // full success needs no explanation
    }

    func testMarkAllReadReportsFirstServerRejection() async throws {
        let store = try MessageStore.inMemory()
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")
        for i in 0..<3 {
            try await store.upsert(makeMessage(id: "msg\(i)", topic: "alpha"), serverURL: ref.serverURL)
        }

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        vm.serverMarkReadSession = markReadMockSession(status: 403)  // read-only token

        vm.markAllRead(for: ref)

        try await waitUntil { vm.markReadSyncNotice != nil }
        XCTAssertEqual(MarkReadMockProtocol.paths.count, 1)  // stopped at the first rejection
        XCTAssertTrue(vm.markReadSyncNotice!.contains("0/3"))

        // Rejection does not roll back the local read state.
        let counts = try await store.unreadCountsByTopic()
        XCTAssertTrue(counts.isEmpty)
    }

    // MARK: - Global search (audit 3.4)

    private func makeSearchableMessage(id: String, topic: String, message text: String, time: Int) -> NtfyMessage {
        NtfyMessage(
            id: id, time: time, event: "message", topic: topic,
            message: text, title: nil, priority: 3, tags: nil,
            click: nil, actions: nil, attachment: nil, contentType: nil, sequenceId: nil
        )
    }

    func testGlobalSearchFillsResultsAndOpenLeavesSearchMode() async throws {
        let store = try MessageStore.inMemory()
        try await store.upsert(makeSearchableMessage(id: "x1", topic: "alpha", message: "磁盘已满 disk full", time: 1), serverURL: "https://s.example")
        try await store.upsert(makeSearchableMessage(id: "x2", topic: "beta", message: "disk quiet", time: 2), serverURL: "https://s.example")
        try await store.upsert(makeSearchableMessage(id: "x3", topic: "beta", message: "无关", time: 3), serverURL: "https://s1.example")

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        vm.globalQuery = "disk"
        try await waitUntil { vm.globalResults.count == 2 }
        XCTAssertTrue(vm.isGlobalSearchActive)
        XCTAssertEqual(Set(vm.globalResults.map(\.id)), ["x1", "x2"])
        // Newest first across servers.
        XCTAssertEqual(vm.globalResults.first?.id, "x2")

        let hit = vm.globalResults[0]
        vm.openGlobalResult(hit)
        XCTAssertFalse(vm.isGlobalSearchActive)
        XCTAssertEqual(vm.selectedTopic, hit.topicRef)
    }

    func testGlobalSearchEmptyQueryClearsResults() async throws {
        let store = try MessageStore.inMemory()
        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        vm.runGlobalSearch("disk")  // generation bump without DB work
        vm.globalQuery = ""
        try await waitUntil { vm.globalResults.isEmpty && !vm.isGlobalSearching }
    }

    // MARK: - Attachment download (audit 3.5)

    func testAttachmentDownloadFailureSurfacesRetryState() async throws {
        let store = try MessageStore.inMemory()
        let attachment = NtfyMessage.NtfyAttachment(
            name: "f.txt", url: "https://s.example/file/f.txt", type: nil, size: nil, expires: nil
        )
        try await store.upsert(
            NtfyMessage(
                id: "a1", time: 1, event: "message", topic: "alpha",
                message: "m", title: nil, priority: 3, tags: nil,
                click: nil, actions: nil, attachment: attachment, contentType: nil, sequenceId: nil
            ),
            serverURL: "https://s.example"
        )
        let stored = try await store.messages(serverURL: "https://s.example", topic: "alpha")
        XCTAssertEqual(stored.count, 1)

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("att-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        vm.attachmentDirectoryOverride = dir
        vm.attachmentSession = attachmentMockSession(status: 403, body: Data())

        vm.downloadAndOpen(stored[0])
        try await waitUntil { vm.attachmentStates[attachment.url] == .downloading }
        try await waitUntil {
            guard case .failed = vm.attachmentStates[attachment.url] else { return false }
            return true
        }
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
