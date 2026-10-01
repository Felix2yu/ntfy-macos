import Foundation

/// Identifies a (server, topic) pair — the key for unread counts and sync state.
struct TopicRef: Hashable, Sendable, Codable {
    let serverURL: String
    let topic: String

    static func == (lhs: TopicRef, rhs: TopicRef) -> Bool {
        lhs.serverURL == rhs.serverURL && lhs.topic == rhs.topic
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(serverURL)
        hasher.combine(topic)
    }
}

/// A message row as stored in the local history database.
struct StoredMessage: Identifiable, Sendable {
    let serverURL: String
    let topic: String
    let message: NtfyMessage
    var isRead: Bool
    var isDeleted: Bool

    var id: String { message.id }

    var topicRef: TopicRef {
        TopicRef(serverURL: serverURL, topic: topic)
    }

    /// Sort key used for time-ordered cursors.
    var time: Int { message.time }
}
