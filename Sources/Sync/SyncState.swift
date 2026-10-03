import Foundation

/// What one Mac remembers about the shared configuration between launches: the state every
/// device last agreed on (the merge ancestor), and the marker that says whether the cloud
/// file moved since the previous pass.
struct SyncState: Codable, Equatable {
    var base: SyncDocument?
    var lastCloudFingerprint: String?
    var lastSyncedAt: Date?
}

/// `~/Library/Application Support/ntfyx/sync-state.json`, next to the history database.
enum SyncStateStore {
    static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("ntfyx", isDirectory: true)
            .appendingPathComponent("sync-state.json")
    }

    static func load() -> SyncState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(SyncState.self, from: data) else {
            return SyncState(base: nil, lastCloudFingerprint: nil, lastSyncedAt: nil)
        }
        return state
    }

    static func save(_ state: SyncState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
