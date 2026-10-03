import XCTest
@testable import ntfyx

final class AppModeTests: XCTestCase {

    func testBareLaunchIsDockApp() {
        // Double-click / `open`: the executable path is the only argument.
        XCTAssertTrue(AppMode.isDockLaunch(arguments: ["/Applications/ntfyx.app/Contents/MacOS/ntfyx"]))
    }

    func testCLISubcommandsAreBackgroundService() {
        let exe = "/usr/local/bin/ntfyx"
        for subcommand in ["serve", "auth", "init", "test-notify", "help"] {
            XCTAssertFalse(AppMode.isDockLaunch(arguments: [exe, subcommand]), subcommand)
        }
    }

    func testSubcommandWithFlagsStaysBackgroundService() {
        XCTAssertFalse(AppMode.isDockLaunch(arguments: ["/usr/local/bin/ntfyx", "serve", "--config", "/tmp/c.yml"]))
    }
}
