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

    /// SwiftUI's split view for the sidebar column, once found. The remembered width is
    /// applied to it directly, and divider drags are read back from it.
    private var trackedSplitView: NSSplitView?
    private var sidebarWidthPending = false

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
            trackSidebarWidth(in: window)
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

        let hostingController = NSHostingController(
            rootView: HistoryView(viewModel: vm,
                                  initialSidebarWidth: SidebarWidth.saved() ?? SidebarWidth.fallback)
        )

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
        // The window is created once for this singleton, so this observer goes in once.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidUpdateForSidebarWidth),
            name: NSWindow.didUpdateNotification, object: window
        )
        trackSidebarWidth(in: window)
    }

    // MARK: - Sidebar width

    /// Points the sidebar column of `window` at the stored width and starts reading drags
    /// back off it.
    ///
    /// The column has to be set on the `NSSplitView` SwiftUI builds for
    /// `NavigationSplitView`: a divider drag never reaches SwiftUI's state, so AppKit is
    /// the only place that knows what width the user ended up with.
    private func trackSidebarWidth(in window: NSWindow) {
        guard trackedSplitView?.window !== window else { return }
        untrackSplitView()
        resolveSidebarSplit(in: window, retries: 3)
    }

    /// SwiftUI lays the split view out on its own schedule and can replace it, and the
    /// window posts updates as that happens.
    @objc private func windowDidUpdateForSidebarWidth() {
        guard let window, trackedSplitView?.window !== window else { return }
        untrackSplitView()
        resolveSidebarSplit(in: window, retries: 0)
    }

    private func untrackSplitView() {
        guard let old = trackedSplitView else { return }
        NotificationCenter.default.removeObserver(self, name: NSSplitView.didResizeSubviewsNotification,
                                                 object: old)
        trackedSplitView = nil
    }

    private func resolveSidebarSplit(in window: NSWindow, retries: Int) {
        guard trackedSplitView == nil else { return }
        guard let split = SidebarWidth.sidebarSplit(in: window.contentView) else {
            guard retries > 0 else { return }
            // Cover an idle window, which may not post an update at all.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak window] in
                guard let self, let window else { return }
                self.resolveSidebarSplit(in: window, retries: retries - 1)
            }
            return
        }
        trackedSplitView = split
        NotificationCenter.default.addObserver(
            self, selector: #selector(sidebarColumnResized),
            name: NSSplitView.didResizeSubviewsNotification, object: split
        )
        Log.info("History sidebar split view found: \(SidebarWidth.describe(split))")
        applySavedSidebarWidth(split)
    }

    private func applySavedSidebarWidth(_ split: NSSplitView) {
        guard let saved = SidebarWidth.saved() else { return }
        if let current = SidebarWidth.columnWidth(of: split), abs(current - saved) < 1 { return }
        if SidebarWidth.restore(saved, to: split) {
            Log.info("History sidebar width restored to \(saved)")
        } else {
            Log.info("History sidebar width \(saved) not applied, column is at "
                + "\(SidebarWidth.columnWidth(of: split) ?? -1)")
        }
    }

    @objc private func sidebarColumnResized() {
        // Fires for every pixel of a divider drag; store only the settled width.
        guard !sidebarWidthPending else { return }
        sidebarWidthPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sidebarWidthPending = false
            self?.persistSidebarWidth()
        }
    }

    private func persistSidebarWidth() {
        guard let width = SidebarWidth.columnWidth(of: trackedSplitView),
              SidebarWidth.saved() != width else { return }
        UserDefaults.standard.set(width, forKey: SidebarWidth.key)
        Log.info("History sidebar width saved: \(width)")
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
        // Resizing the window can re-clamp the column, so store what it settled at.
        persistSidebarWidth()
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            WindowFramePersistence.save(window, key: Self.frameKey)
        }
        AppMode.demoteToAccessoryIfNeeded()
    }
}
