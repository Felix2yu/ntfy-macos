import Foundation
import SwiftUI
import AppKit
import Combine

extension Notification.Name {
    /// Posted (on any queue) after the history store changed for a topic.
    /// userInfo["topicRef"] holds the affected TopicRef.
    static let historyStoreDidChange = Notification.Name("historyStoreDidChange")
}

/// View model for the notification history window.
@MainActor
final class HistoryViewModel: ObservableObject {

    struct TopicEntry: Identifiable, Hashable {
        let ref: TopicRef
        let iconSymbol: String?
        var unread: Int
        var id: String { "\(ref.serverURL)|\(ref.topic)" }
    }

    struct ServerGroup: Identifiable {
        let url: String
        var topics: [TopicEntry]
        var id: String { url }
    }

    static let pageSize = 100
    static let globalSearchCap = 200

    /// Upper bound for server requests in a single mark-all-read: every `/read` call
    /// publishes a `message_clear` broadcast and counts against the server's per-visitor
    /// rate limit, so a huge unread set must not replay one request per message.
    static let serverMarkReadCap = 50

    // MARK: - Published state

    @Published var groups: [ServerGroup] = []
    @Published var selectedTopic: TopicRef? {
        didSet {
            guard oldValue != selectedTopic else { return }
            handleSelectionChange()
        }
    }
    @Published var messages: [StoredMessage] = []
    @Published var unreadCounts: [TopicRef: Int] = [:]
    @Published var onlyUnread = false
    @Published var searchText = ""

    // MARK: - Global search state (across all topics; replaces the detail pane)

    @Published var globalQuery = ""
    @Published var globalResults: [StoredMessage] = []
    @Published var isGlobalSearching = false

    @Published var hasMoreMessages = false
    @Published var isLoadingOlder = false
    @Published var confirmClearTopic: TopicRef?
    /// Explains partial server sync after a capped/rejected mark-all-read; shown in the footer.
    @Published var markReadSyncNotice: String?
    /// Per-attachment download state, keyed by attachment URL.
    enum AttachmentState: Equatable {
        case downloading
        case failed(reason: String)
    }
    @Published var attachmentStates: [String: AttachmentState] = [:]

    // MARK: - Dependencies

    private let store: MessageStore
    let syncService: HistorySyncService
    /// Test seam: session used for server mark-read requests.
    var serverMarkReadSession: URLSession = .shared
    private var searchTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var globalSearchGeneration = 0
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    init(store: MessageStore, syncService: HistorySyncService) {
        self.store = store
        self.syncService = syncService

        // Live updates: the service layer posts store changes; refresh relevant parts.
        NotificationCenter.default.publisher(for: .historyStoreDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleStoreChange(notification)
            }
            .store(in: &cancellables)

        // Debounced search.
        $searchText
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadMessages()
            }
            .store(in: &cancellables)

        $globalQuery
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] query in
                self?.runGlobalSearch(query)
            }
            .store(in: &cancellables)

        refreshSidebar()
    }

    // MARK: - Sidebar

    func refreshSidebar() {
        Task { [weak self] in
            guard let self else { return }
            let counts = (try? await self.store.unreadCountsByTopic()) ?? [:]
            self.unreadCounts = counts

            var newGroups: [ServerGroup] = []
            if let config = ConfigManager.shared.config {
                for server in config.servers {
                    let entries = server.topics.map { topic in
                        TopicEntry(
                            ref: TopicRef(serverURL: server.url, topic: topic.name),
                            iconSymbol: topic.iconSymbol,
                            unread: counts[TopicRef(serverURL: server.url, topic: topic.name)] ?? 0
                        )
                    }
                    newGroups.append(ServerGroup(url: server.url, topics: entries))
                }
            }
            self.groups = newGroups
        }
    }

    var totalUnread: Int {
        unreadCounts.values.reduce(0, +)
    }

    func unread(for ref: TopicRef) -> Int {
        unreadCounts[ref] ?? 0
    }

    // MARK: - Selection & messages

    func selectTopic(_ ref: TopicRef?) {
        selectedTopic = ref
    }

    private func handleSelectionChange() {
        markReadSyncNotice = nil
        reloadMessages()
        if let ref = selectedTopic {
            Task { [weak self] in
                guard let self else { return }
                await self.syncService.syncIncremental(ref)
                self.refreshSidebar()
                self.reloadMessages()
            }
        }
    }

    func reloadMessages() {
        guard let ref = selectedTopic else {
            messages = []
            hasMoreMessages = false
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        let onlyUnread = self.onlyUnread
        let searchText = self.searchText
        Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.store.messages(
                    serverURL: ref.serverURL,
                    topic: ref.topic,
                    limit: Self.pageSize,
                    before: nil,
                    onlyUnread: onlyUnread,
                    searchText: searchText.isEmpty ? nil : searchText
                )
                guard generation == self.loadGeneration else { return }  // stale response
                self.messages = page
                self.hasMoreMessages = page.count >= Self.pageSize
            } catch {
                Log.error("History: failed to load messages: \(error)")
            }
        }
    }

    // MARK: - Global search

    var isGlobalSearchActive: Bool { !globalQuery.isEmpty }

    func runGlobalSearch(_ query: String) {
        globalSearchGeneration += 1
        let generation = globalSearchGeneration
        guard !query.isEmpty else {
            globalResults = []
            isGlobalSearching = false
            return
        }
        isGlobalSearching = true
        Task { [weak self] in
            guard let self else { return }
            let results = (try? await self.store.searchAll(query: query, limit: Self.globalSearchCap)) ?? []
            guard generation == self.globalSearchGeneration else { return }  // stale response
            self.globalResults = results
            self.isGlobalSearching = false
        }
    }

    /// Jumps to the hit's topic and leaves search mode.
    func openGlobalResult(_ stored: StoredMessage) {
        globalQuery = ""
        selectTopic(stored.topicRef)
    }

    /// Loads older messages (cursor pagination).
    func loadOlder() {
        guard let ref = selectedTopic,
              !isLoadingOlder,
              hasMoreMessages,
              let oldest = messages.last else { return }
        let olderCursor = oldest.cursor

        isLoadingOlder = true
        let onlyUnread = self.onlyUnread
        let searchText = self.searchText
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoadingOlder = false }
            do {
                let older = try await self.store.messages(
                    serverURL: ref.serverURL,
                    topic: ref.topic,
                    limit: Self.pageSize,
                    before: olderCursor,
                    onlyUnread: onlyUnread,
                    searchText: searchText.isEmpty ? nil : searchText
                )
                self.messages.append(contentsOf: older)
                self.hasMoreMessages = older.count >= Self.pageSize
            } catch {
                Log.error("History: failed to load older messages: \(error)")
            }
        }
    }

    /// Re-fetch after a full sync.
    func loadFullHistory() {
        guard let ref = selectedTopic else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.syncService.syncFull(ref)
            self.refreshSidebar()
            self.reloadMessages()
        }
    }

    /// Manual retry entry for failed/rate-limited syncs (audit 2.5).
    func retrySync() {
        guard let ref = selectedTopic else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.syncService.syncIncremental(ref)
            self.refreshSidebar()
            self.reloadMessages()
        }
    }

    // MARK: - Actions

    func toggleRead(_ stored: StoredMessage) {
        let ref = stored.topicRef
        let target = !stored.isRead
        let sequenceID = stored.message.sequenceId
        let messageID = stored.message.id
        Task { [weak self] in
            guard let self else { return }
            try? await self.store.markRead(target, serverURL: ref.serverURL, topic: ref.topic, messageID: messageID)
            self.postStoreChange(for: ref)
            guard target else { return }
            // Reading a message here takes its banner off, same as the web and phone apps do.
            NotificationManager.shared.revoke(messageIDs: [messageID])
            // There is no "mark unread" endpoint; marking read asks the server to
            // broadcast message_clear so other devices converge too.
            await MessageActionService.markReadOnServer(
                serverURL: ref.serverURL,
                topic: ref.topic,
                sequenceID: sequenceID,
                messageID: messageID,
                authToken: ConfigManager.shared.getAuthToken(forServer: ref.serverURL)
            )
        }
    }

    func markAllRead(for ref: TopicRef) {
        Task { [weak self] in
            guard let self else { return }
            await markTopicRead(for: ref, syncToServer: true)
        }
    }

    /// Clears unread across every topic at once. Local-only on purpose: replaying a
    /// server mark for thousands of catch-up messages would publish one clear event per
    /// message and flood every other device. Per-topic actions still sync to the server.
    func markEverythingRead() {
        let refs = unreadCounts.filter { $0.value > 0 }.map(\.key)
        guard !refs.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            for ref in refs {
                await markTopicRead(for: ref, syncToServer: false)
            }
        }
    }

    private func markTopicRead(for ref: TopicRef, syncToServer: Bool) async {
        // Collect the unread set first: after markAllRead it is gone.
        let targets = await messageTargets(for: ref, onlyUnread: true)
        try? await store.markAllRead(serverURL: ref.serverURL, topic: ref.topic)
        postStoreChange(for: ref)
        NotificationManager.shared.revoke(messageIDs: targets.map { $0.messageID })
        guard syncToServer else { return }

        // Sync at most the newest `serverMarkReadCap` targets; older unread messages on
        // other devices converge when the user reads them individually there.
        let synced = await MessageActionService.markAllReadOnServer(
            serverURL: ref.serverURL,
            topic: ref.topic,
            targets: Array(targets.prefix(Self.serverMarkReadCap)),
            authToken: ConfigManager.shared.getAuthToken(forServer: ref.serverURL),
            session: serverMarkReadSession
        )
        let total = targets.count
        guard synced < total else {
            markReadSyncNotice = nil
            return
        }
        if total > Self.serverMarkReadCap {
            markReadSyncNotice = "本地已全部标为已读；服务器仅同步最近 \(synced) 条（限速保护，单次上限 \(Self.serverMarkReadCap) 条）。"
        } else {
            markReadSyncNotice = "本地已全部标为已读；服务器同步在 \(synced)/\(total) 处停止（离线或无写入权限）。"
        }
    }

    /// Non-deleted messages of a topic, paged by time cursor.
    private func messageTargets(for ref: TopicRef, onlyUnread: Bool) async -> [(sequenceID: String?, messageID: String)] {
        var targets: [(sequenceID: String?, messageID: String)] = []
        var seen: Set<String> = []
        var cursor: PageCursor?
        while true {
            let page = (try? await store.messages(
                serverURL: ref.serverURL, topic: ref.topic,
                limit: Self.pageSize, before: cursor, onlyUnread: onlyUnread
            )) ?? []
            for stored in page where seen.insert(stored.message.id).inserted {
                targets.append((stored.message.sequenceId, stored.message.id))
            }
            guard page.count == Self.pageSize, let oldest = page.last else { break }
            cursor = oldest.cursor
        }
        return targets
    }

    func delete(_ stored: StoredMessage) {
        let ref = stored.topicRef
        Task { [weak self] in
            guard let self else { return }
            // 1. Local tombstone first (authoritative for the UI).
            try? await self.store.tombstoneMessage(
                serverURL: ref.serverURL, topic: ref.topic, messageID: stored.message.id
            )
            NotificationManager.shared.revoke(messageIDs: [stored.message.id])
            // 2. Best-effort server delete (silent on failure).
            await MessageActionService.deleteOnServer(
                serverURL: ref.serverURL,
                topic: ref.topic,
                sequenceID: stored.message.sequenceId,
                messageID: stored.message.id,
                authToken: ConfigManager.shared.getAuthToken(forServer: ref.serverURL)
            )
            self.postStoreChange(for: ref)
        }
    }

    func clearTopic(_ ref: TopicRef) {
        Task { [weak self] in
            guard let self else { return }
            let targets = await messageTargets(for: ref, onlyUnread: false)
            try? await self.store.tombstoneAll(serverURL: ref.serverURL, topic: ref.topic)
            self.confirmClearTopic = nil
            self.postStoreChange(for: ref)
            NotificationManager.shared.revoke(messageIDs: targets.map { $0.messageID })
        }
    }

    func copyMessage(_ stored: StoredMessage) {
        let text = stored.message.message ?? ""
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openURL(_ urlString: String, serverURL: String) {
        guard let url = URL(string: urlString) else { return }
        MessageActionService.openSecurely(url, serverBaseURL: serverURL)
    }

    // MARK: - Attachments (audit 3.5)

    /// Test seam for attachment downloads.
    var attachmentDirectoryOverride: URL?
    var attachmentSession: URLSession = .shared

    /// Downloads the attachment (or reuses the cached file) and opens it with the
    /// default application; clicking again after a failure retries.
    func downloadAndOpen(_ stored: StoredMessage) {
        guard let attachment = stored.message.attachment,
              attachmentStates[attachment.url] != .downloading else { return }
        attachmentStates[attachment.url] = .downloading
        let serverURL = stored.serverURL
        Task { [weak self] in
            guard let self else { return }
            do {
                let fileURL = try await AttachmentService.download(
                    attachment: attachment,
                    serverURL: serverURL,
                    authToken: ConfigManager.shared.getAuthToken(forServer: serverURL),
                    to: self.attachmentDirectoryOverride,
                    session: self.attachmentSession
                )
                self.attachmentStates[attachment.url] = nil
                NSWorkspace.shared.open(fileURL)
            } catch let error as AttachmentService.AttachmentError {
                self.attachmentStates[attachment.url] = .failed(reason: error.errorDescription ?? "下载失败")
            } catch {
                self.attachmentStates[attachment.url] = .failed(reason: error.localizedDescription)
            }
        }
    }

    func execute(action: NtfyMessage.NtfyAction, serverURL: String) {
        MessageActionService.execute(action: action, serverURL: serverURL)
    }

    // MARK: - Live updates

    private func handleStoreChange(_ notification: Notification) {
        refreshSidebar()
        if let ref = notification.userInfo?["topicRef"] as? TopicRef, ref == selectedTopic {
            reloadMessages()
        }
    }

    private func postStoreChange(for ref: TopicRef) {
        NotificationCenter.default.post(
            name: .historyStoreDidChange,
            object: nil,
            userInfo: ["topicRef": ref]
        )
    }
}
