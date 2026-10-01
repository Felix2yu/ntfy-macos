import AppKit

/// Distinguishes the two ways this binary can run:
/// - Dock app: launched by double-click / `open`, shows windows and owns the menu bar.
/// - Background service: launched with a CLI subcommand (`serve`, `test-notify`, …) or
///   by launchd, so it must stay out of the Dock.
enum AppMode {
    // Written once at launch, on the main queue, before any reader starts.
    nonisolated(unsafe) private(set) static var isDockApp = false

    /// The only argument of a bare launch is the executable path itself.
    static func isDockLaunch(arguments: [String]) -> Bool {
        arguments.count < 2
    }

    @MainActor
    static func configure(arguments: [String] = CommandLine.arguments) {
        isDockApp = isDockLaunch(arguments: arguments)
        NSApp.setActivationPolicy(isDockApp ? .regular : .accessory)
        if isDockApp {
            MainMenu.install()
        }
    }

    /// A background service has no Dock icon to keep it alive, so closing its last window
    /// must demote the app to menu-bar-only. A Dock app keeps running.
    @MainActor
    static func demoteToAccessoryIfNeeded() {
        guard !isDockApp else { return }
        _ = NSApp.setActivationPolicy(.accessory)
    }
}
