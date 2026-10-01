import Foundation

/// Orchestrates history synchronization between the server cache and the local store.
/// - Auto incremental sync: `since=<last synced message id>` (falls back to timestamp,
///   or a 90-day window on first sync) — triggered when a topic is opened.
/// - Manual full sync: `since=all` — user-initiated, with progress reporting.
/// Re-entrant calls for the same topic are ignored.
@MainActor
final class HistorySyncService: ObservableObject {

    enum SyncPhase: Equatable {
        case idle
        case syncing
        case rateLimited(retryAfter: TimeInterval)
        case failed(String)
        case completed(count: Int)
    }

    struct SyncProgress: Equatable {
        var phase: SyncPhase = .idle
        var receivedCount = 0
    }

    private let store: MessageStore
    private var syncingTopics: Set<TopicRef> = []

    @Published var progress: [TopicRef: SyncProgress] = [:]

    init(store: MessageStore) {
        self.store = store
    }

    /// Whether a topic sync is currently running.
    func isSyncing(_ ref: TopicRef) -> Bool {
        syncingTopics.contains(ref)
    }

    func progress(for ref: TopicRef) -> SyncProgress {
        progress[ref] ?? SyncProgress()
    }

    /// Incremental sync — called when a topic is selected in the history window.
    func syncIncremental(_ ref: TopicRef) async {
        await sync(ref, full: false)
    }

    /// Full history sync (`since=all`) — user-initiated.
    func syncFull(_ ref: TopicRef) async {
        await sync(ref, full: true)
    }

    private func sync(_ ref: TopicRef, full: Bool) async {
        guard !syncingTopics.contains(ref) else { return }
        syncingTopics.insert(ref)
        defer { syncingTopics.remove(ref) }

        progress[ref] = SyncProgress(phase: .syncing, receivedCount: 0)

        do {
            let since = try await resolveSince(ref: ref, full: full)
            Log.info("History sync \(full ? "(full)" : "(incremental)") for \(ref.topic)@\(ref.serverURL): since=\(since)")

            let token = ConfigManager.shared.getAuthToken(forServer: ref.serverURL)
            let store = self.store
            let result = try await NtfyPollClient.poll(
                serverURL: ref.serverURL,
                topic: ref.topic,
                since: since,
                authToken: token,
                onMessage: { message in
                    try await store.upsert(message, serverURL: ref.serverURL)
                },
                onActionEvent: { event in
                    try await store.applyActionEvent(event, serverURL: ref.serverURL)
                    // A replayed clear/delete also has to withdraw the banner the message
                    // left on screen — Notification Center is not part of the history store.
                    if let messageID = try await store.targetMessageID(for: event, serverURL: ref.serverURL) {
                        NotificationManager.shared.revoke(messageIDs: [messageID])
                    }
                }
            )

            // Advance sync state to the newest message seen. The server replays `since`
            // in ascending time order, so action events land after their target message.
            if let newest = result.newestMessage {
                try await store.setSyncedInfo(
                    serverURL: ref.serverURL, topic: ref.topic,
                    id: newest.id, time: newest.time
                )
            }

            Log.info("History sync done for \(ref.topic): \(result.messageCount) messages, \(result.actionEventCount) action events")
            progress[ref] = SyncProgress(phase: .completed(count: result.messageCount), receivedCount: result.messageCount)
        } catch let error as NtfyPollClient.PollError {
            if let retryAfter = error.retryAfter {
                Log.error("History sync rate limited for \(ref.topic): retry after \(Int(retryAfter))s")
                progress[ref] = SyncProgress(phase: .rateLimited(retryAfter: retryAfter), receivedCount: progress[ref]?.receivedCount ?? 0)
            } else {
                Log.error("History sync failed for \(ref.topic): \(error.localizedDescription)")
                progress[ref] = SyncProgress(phase: .failed(error.localizedDescription), receivedCount: 0)
            }
        } catch {
            Log.error("History sync failed for \(ref.topic): \(error)")
            progress[ref] = SyncProgress(phase: .failed(error.localizedDescription), receivedCount: 0)
        }
    }

    /// Determines the `since` parameter for a sync run.
    private func resolveSince(ref: TopicRef, full: Bool) async throws -> String {
        if full {
            return "all"
        }
        if let info = try await store.latestSyncedInfo(serverURL: ref.serverURL, topic: ref.topic) {
            // Prefer message id (immune to clock skew); fall back to timestamp.
            if let id = info.id, !id.isEmpty {
                return id
            }
            if info.time > 0 {
                return String(info.time)
            }
        }
        // First sync: limit to a recent window instead of replaying the entire cache.
        let window: TimeInterval = 90 * 24 * 3600
        return String(Int(Date().timeIntervalSince1970 - window))
    }
}
