import XCTest
@testable import ntfyx

/// The menu-bar pause switch must survive a relaunch (UserDefaults-backed) and
/// default to "not paused" — otherwise every start would silently drop banners.
final class NotificationPauseTests: XCTestCase {

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "NotificationPauseTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName!)?.removePersistentDomain(forName: suiteName!)
        super.tearDown()
    }

    private func makePause() -> NotificationPause {
        NotificationPause(defaults: UserDefaults(suiteName: suiteName!)!)
    }

    func testDefaultIsNotPaused() {
        XCTAssertFalse(makePause().isPaused)
    }

    func testToggleFlipsAndReturnsNewState() {
        let pause = makePause()
        XCTAssertTrue(pause.toggle())
        XCTAssertTrue(pause.isPaused)
        XCTAssertFalse(pause.toggle())
        XCTAssertFalse(pause.isPaused)
    }

    func testPauseSurvivesRelaunch() {
        makePause().isPaused = true
        // A fresh instance over the same defaults models an app relaunch.
        XCTAssertTrue(makePause().isPaused)
    }
}
