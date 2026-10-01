import AppKit
import SwiftUI

/// Window controller for the notification history window.
/// Singleton with a persistent window: created once, reused thereafter
/// (visible or hidden). The window frame (position + size) is persisted
/// explicitly via WindowFramePersistence — setFrameAutosaveName is unreliable
/// here because a stale window object keeps the autosave name claimed.
@MainActor
class HistoryWindowController: NSObject, NSWindowDelegate {
    static let shared = HistoryWindowController()
    private static let frameKey = "HistoryWindowFrame"

    private var window: NSWindow?
    private var viewModel: HistoryViewModel?
    private var store: MessageStore?
    private var syncService: HistorySyncService?

    override private init() {
        super.init()
    }

    /// Registers the dependencies created at app startup.
    func configure(store: MessageStore, syncService: HistorySyncService) {
        self.store = store
        self.syncService = syncService
    }

    func showHistory(selectingTopic topic: String? = nil) {
        // Reuse the persistent window (visible or hidden)
        if let window {
            if let viewModel {
                viewModel.refreshSidebar()
                if let topic, let ref = findRef(forTopic: topic) {
                    viewModel.selectTopic(ref)
                }
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let store, let syncService else {
            Log.error("History window opened before configure(store:syncService:)")
            return
        }

        let vm = HistoryViewModel(store: store, syncService: syncService)
        if let topic, let ref = findRef(forTopic: topic) {
            vm.selectTopic(ref)
        }
        self.viewModel = vm

        let hostingController = NSHostingController(rootView: HistoryView(viewModel: vm))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 950, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "通知历史"
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.minSize = NSSize(width: 720, height: 480)
        window.delegate = self
        WindowFramePersistence.restore(window, key: Self.frameKey)

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func findRef(forTopic topicName: String) -> TopicRef? {
        guard let config = ConfigManager.shared.config else { return nil }
        for server in config.servers {
            if let topic = server.topics.first(where: { $0.name == topicName }) {
                return TopicRef(serverURL: server.url, topic: topic.name)
            }
        }
        return nil
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            WindowFramePersistence.save(window, key: Self.frameKey)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            WindowFramePersistence.save(window, key: Self.frameKey)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            WindowFramePersistence.save(window, key: Self.frameKey)
        }
        AppMode.demoteToAccessoryIfNeeded()
    }
}
