import Foundation
import Combine

/// Keeps this Mac's configuration file and the shared iCloud Drive file in step: local
/// edits are merged into the cloud copy, cloud edits are merged into the local file, and
/// the app's own config reload picks the result up. Messages are deliberately not part of
/// this — the history is fetched from the ntfy server, which already tracks read and
/// deleted state across devices.
@MainActor
final class ConfigSyncService: ObservableObject {
    static let shared = ConfigSyncService()

    enum Status: Equatable {
        case off
        case waiting
        case syncing
        case synced(Date)
        case failed(String)
    }

    @Published private(set) var status: Status = .off

    /// Status for whoever wants to display it (the menu bar item, the settings window).
    var statusPublisher: AnyPublisher<Status, Never> {
        $status.eraseToAnyPublisher()
    }

    /// A hand-edit of the config file lands here one save at a time; a second later the
    /// watcher is quiet and one merge covers the whole edit.
    static let localChangeDebounce: TimeInterval = 2
    static let pollInterval: TimeInterval = 45

    let store = CloudConfigStore()
    private var state = SyncState(base: nil, lastCloudFingerprint: nil, lastSyncedAt: nil)
    private var pendingLocalChange: Task<Void, Never>?
    private var pollTimer: Timer?
    private var isSyncing = false
    private var lastCycleSucceeded = true

    private init() {
        refreshSettings()
    }

    // MARK: - Settings

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppSettings.iCloudSyncEnabledKey)
    }

    /// Custom sync folder; empty means iCloud Drive.
    var directoryOverride: String {
        UserDefaults.standard.string(forKey: AppSettings.iCloudSyncDirectoryKey) ?? ""
    }

    var syncDirectory: String {
        refreshSettings()
        return store.rootDirectory
    }

    private func refreshSettings() {
        store.directoryOverride = directoryOverride.isEmpty ? nil : directoryOverride
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        UserDefaults.standard.set(enabled, forKey: AppSettings.iCloudSyncEnabledKey)
        if enabled {
            start()
        } else {
            stop()
            status = .off
            Log.info("配置同步已关闭")
        }
    }

    func setDirectory(_ path: String) {
        guard path != directoryOverride else { return }
        UserDefaults.standard.set(path.isEmpty ? nil : path, forKey: AppSettings.iCloudSyncDirectoryKey)
        refreshSettings()
        // A new folder has no agreed ancestor on this Mac; the merge starts over against it.
        state.base = nil
        state.lastCloudFingerprint = nil
        SyncStateStore.save(state)
        if isEnabled { syncNow() }
    }

    // MARK: - Lifecycle

    /// Called once the service has a loaded configuration.
    func start() {
        guard isEnabled else {
            status = .off
            return
        }
        refreshSettings()
        state = SyncStateStore.load()
        status = .waiting
        beginPolling()
        // Let the app finish launching (and load its config) before the first merge.
        DispatchQueue.main.async { [weak self] in
            self?.synchronize()
        }
        Log.info("配置同步已开启：\(store.rootDirectory)")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        pendingLocalChange?.cancel()
        pendingLocalChange = nil
    }

    private func beginPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollCloud()
            }
        }
    }

    // MARK: - Triggers

    /// ConfigWatcher's signal: the file on disk changed, so the cloud copy may need it.
    func noteLocalConfigChanged() {
        guard isEnabled else { return }
        pendingLocalChange?.cancel()
        pendingLocalChange = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.localChangeDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.synchronize()
        }
    }

    /// "立即同步" — ignores the debounce and the change markers.
    func syncNow() {
        pendingLocalChange?.cancel()
        synchronize()
    }

    private func pollCloud() {
        guard isEnabled, !isSyncing else { return }
        // Nothing moved and the last pass finished cleanly: a merge would be pure rework.
        // After a failed pass the poll is the retry, so it must not be skipped.
        if lastCycleSucceeded, state.lastCloudFingerprint == store.cloudFingerprint() { return }
        synchronize()
    }

    // MARK: - The cycle

    private func synchronize() {
        guard isEnabled, !isSyncing else { return }
        guard let local = ConfigManager.shared.config else { return }
        guard ConfigManager.shared.activePath == ConfigManager.defaultConfigPath else {
            // A `serve --config <PATH>` instance owns a file this feature was never meant
            // to publish; syncing it would push one machine's private config onto everyone.
            status = .failed("配置同步只作用于默认配置文件 \(ConfigManager.defaultConfigPath)")
            lastCycleSucceeded = false
            return
        }

        isSyncing = true
        status = .syncing
        defer { isSyncing = false }

        do {
            try runCycle(local: local)
            lastCycleSucceeded = true
        } catch {
            lastCycleSucceeded = false
            let message = error.localizedDescription
            Log.error("配置同步失败：\(message)")
            status = .failed(message)
        }
    }

    private func runCycle(local: AppConfig) throws {
        // No ancestor yet means this Mac is joining: what it already has is its newest edit,
        // while everything only the cloud has is adopted as-is.
        let resolution: ConfigMerger.ConflictResolution = state.base == nil ? .preferLocal : .stableFingerprint

        let outcome = try ConfigSyncEngine.run(
            local: local,
            base: state.base ?? .empty,
            resolution: resolution,
            store: store
        )

        if outcome.conflictCopiesMerged > 0 {
            Log.info("已合并并清理 \(outcome.conflictCopiesMerged) 个 iCloud 冲突副本")
        }
        if outcome.wroteLocal {
            Log.info("已按云端配置更新本地文件")
            // ConfigWatcher reloads the file, and the reloaded config is exactly the merged
            // document, so the debounced pass that follows writes nothing.
        }

        state.base = outcome.merged
        state.lastCloudFingerprint = outcome.cloudFingerprint
        state.lastSyncedAt = Date()
        SyncStateStore.save(state)
        status = .synced(state.lastSyncedAt ?? Date())
        Log.info("配置同步完成：\(outcome.servers) 个服务器、\(outcome.topics) 个主题")
    }
}
