import Foundation
import SwiftUI
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
    @Published var hasMoreMessages = false
    @Published var isLoadingOlder = false
    @Published var confirmClearTopic: TopicRef?

    // MARK: - Dependencies

    private let store: MessageStore
    let syncService: HistorySyncService
    private var searchTask: Task<Void, Never>?
    private var loadGeneration = 0
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
                    beforeTime: nil,
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

    /// Loads older messages (cursor pagination).
    func loadOlder() {
        guard let ref = selectedTopic,
              !isLoadingOlder,
              hasMoreMessages,
              let oldestTime = messages.last?.time else { return }

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
                    beforeTime: oldestTime,
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
        await MessageActionService.markAllReadOnServer(
            serverURL: ref.serverURL,
            topic: ref.topic,
            targets: targets,
            authToken: ConfigManager.shared.getAuthToken(forServer: ref.serverURL)
        )
    }

    /// Non-deleted messages of a topic, paged by time cursor.
    private func messageTargets(for ref: TopicRef, onlyUnread: Bool) async -> [(sequenceID: String?, messageID: String)] {
        var targets: [(sequenceID: String?, messageID: String)] = []
        var seen: Set<String> = []
        var cursor: Int?
        while true {
            let page = (try? await store.messages(
                serverURL: ref.serverURL, topic: ref.topic,
                limit: Self.pageSize, beforeTime: cursor, onlyUnread: onlyUnread
            )) ?? []
            for stored in page where seen.insert(stored.message.id).inserted {
                targets.append((stored.message.sequenceId, stored.message.id))
            }
            guard page.count == Self.pageSize, let oldest = page.last?.message.time else { break }
            cursor = oldest
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

    func openURL(_ urlString: String, topic: String) {
        guard let url = URL(string: urlString) else { return }
        MessageActionService.openSecurely(url, forTopic: topic)
    }

    func execute(action: NtfyMessage.NtfyAction, topic: String) {
        MessageActionService.execute(action: action, topic: topic)
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
