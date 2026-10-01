import AppKit
import SwiftUI

@MainActor
class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private static let frameKey = "SettingsWindowFrame"

    private var window: NSWindow?
    private var viewModel: SettingsViewModel?

    override private init() {
        super.init()
    }

    func showSettings() {
        // Reuse the persistent window (visible or hidden)
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vm = SettingsViewModel()
        vm.loadFromConfig()
        self.viewModel = vm

        let hostingController = NSHostingController(rootView: SettingsView(viewModel: vm))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ntfy-macos 设置"
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.minSize = NSSize(width: 560, height: 460)
        window.delegate = self
        WindowFramePersistence.restore(window, key: Self.frameKey)

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    /// 有未保存的更改时，关闭窗口前弹出确认，避免静默丢失配置
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            guard let vm = viewModel, vm.hasUnsavedChanges else { return true }

            let alert = NSAlert()
            alert.messageText = "有未保存的更改"
            alert.informativeText = "关闭窗口将丢失未保存的配置更改。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "保存并关闭")
            alert.addButton(withTitle: "不保存关闭")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                vm.save()
                if let error = vm.saveError {
                    let errAlert = NSAlert()
                    errAlert.messageText = "保存失败"
                    errAlert.informativeText = error
                    errAlert.alertStyle = .critical
                    errAlert.addButton(withTitle: "好")
                    errAlert.runModal()
                    return false
                }
                return true
            case .alertSecondButtonReturn:
                return true
            default:
                return false
            }
        }
    }
}
