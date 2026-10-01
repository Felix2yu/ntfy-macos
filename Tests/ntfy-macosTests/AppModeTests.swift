import XCTest
@testable import ntfy_macos

final class AppModeTests: XCTestCase {

    func testBareLaunchIsDockApp() {
        // Double-click / `open`: the executable path is the only argument.
        XCTAssertTrue(AppMode.isDockLaunch(arguments: ["/Applications/ntfy-macos.app/Contents/MacOS/ntfy-macos"]))
    }

    func testCLISubcommandsAreBackgroundService() {
        let exe = "/usr/local/bin/ntfy-macos"
        for subcommand in ["serve", "auth", "init", "test-notify", "help"] {
            XCTAssertFalse(AppMode.isDockLaunch(arguments: [exe, subcommand]), subcommand)
        }
    }

    func testSubcommandWithFlagsStaysBackgroundService() {
        XCTAssertFalse(AppMode.isDockLaunch(arguments: ["/usr/local/bin/ntfy-macos", "serve", "--config", "/tmp/c.yml"]))
    }
}
