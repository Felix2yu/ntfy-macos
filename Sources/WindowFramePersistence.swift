import AppKit

/// Explicit window-frame persistence in UserDefaults.
///
/// Replaces NSWindow.setFrameAutosaveName, which silently fails in this app:
/// windows here live for the app's lifetime and are recreated by their
/// controllers; a stale window object keeps the autosave name claimed, so
/// subsequent setFrameAutosaveName calls return false with no restore and no save.
@MainActor
enum WindowFramePersistence {
    /// Restores a previously saved frame if it is valid and intersects a
    /// currently attached screen; otherwise centers the window.
    static func restore(_ window: NSWindow, key: String) {
        guard
            let raw = UserDefaults.standard.string(forKey: key),
            !raw.isEmpty
        else {
            window.center()
            return
        }

        let frame = NSRectFromString(raw)
        guard frame != .zero else {
            window.center()
            return
        }

        // Guard against displays that no longer exist (e.g. unplugged monitor).
        let onVisibleScreen = NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(frame)
        }
        if onVisibleScreen {
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
    }

    /// Persists the window's current frame as a string rect.
    static func save(_ window: NSWindow, key: String) {
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: key)
    }
}
