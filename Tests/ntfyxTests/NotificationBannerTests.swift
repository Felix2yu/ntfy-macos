import XCTest
@testable import ntfyx

/// Banners are keyed by the ntfy message id so a read or delete on any device can withdraw
/// them. Talking to User Notifications needs a real app bundle, so these tests cover the
/// pure identifier mapping the revocation path depends on.
final class NotificationBannerTests: XCTestCase {

    func testIdentifierIsDerivedFromMessageID() {
        XCTAssertEqual(NotificationManager.identifier(forMessageID: "abc123"), "ntfy:abc123")
    }

    func testDistinctMessagesGetDistinctIdentifiers() {
        XCTAssertNotEqual(
            NotificationManager.identifier(forMessageID: "abc123"),
            NotificationManager.identifier(forMessageID: "xyz789")
        )
    }

    // MARK: - Priority handling (audit 1.5)

    func testMinPriorityIsSuppressed() {
        XCTAssertEqual(NotificationManager.priorityHandling(for: 1), .suppressed)
        XCTAssertEqual(NotificationManager.priorityHandling(for: 0), .suppressed)
    }

    func testLowPriorityIsPassive() {
        XCTAssertEqual(NotificationManager.priorityHandling(for: 2), .passive)
    }

    func testDefaultAndHighPrioritiesAreNormal() {
        XCTAssertEqual(NotificationManager.priorityHandling(for: nil), .normal)
        XCTAssertEqual(NotificationManager.priorityHandling(for: 3), .normal)
        XCTAssertEqual(NotificationManager.priorityHandling(for: 4), .normal)
        XCTAssertEqual(NotificationManager.priorityHandling(for: 5), .normal)
    }
}
