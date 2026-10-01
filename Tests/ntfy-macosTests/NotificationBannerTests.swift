import XCTest
@testable import ntfy_macos

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
}
