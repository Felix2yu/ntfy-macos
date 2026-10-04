import AppKit
import XCTest
@testable import ntfyx

/// Reopening About used to check `isVisible`, so a closed window was kept alive by
/// `aboutWindow` *and* replaced by a new one, along with another `willClose` observer per
/// reopen. The window is now reused, the way the settings window is.
@MainActor
final class StatusBarAboutWindowTests: XCTestCase {

    private func visibleAboutWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "关于 ntfyx" && $0.isVisible }
    }

    func testReopeningAboutReusesTheSameWindow() throws {
        _ = NSApplication.shared

        StatusBarController.shared.showAbout()
        let first = try XCTUnwrap(visibleAboutWindow())

        first.close()
        StatusBarController.shared.showAbout()
        let second = try XCTUnwrap(visibleAboutWindow())

        XCTAssertTrue(first === second, "About must be reopened, not rebuilt on every call")
    }
}
