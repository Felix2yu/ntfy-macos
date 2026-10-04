import AppKit
import XCTest
@testable import ntfyx

/// The permission window used to be allocated with AppKit's default
/// `isReleasedWhenClosed = true`, so `finish()`'s `close()` released it once more than the
/// static reference ever claimed. The over-release only showed up later, as a wild
/// `objc_release` while the main run loop drained its autorelease pool — i.e. a crash on the
/// second click of "请求权限".
@MainActor
final class PermissionHelperWindowTests: XCTestCase {

    /// Mirrors the other AppKit-facing suites: windows created here are never released.
    nonisolated(unsafe) static var retainedWindows: [NSWindow] = []

    /// Closing the window hands the callback to a `Task`, and the deferred work must not
    /// land after the test ends.
    private func drainDeferredWork() async {
        for _ in 0..<50 {
            if !results.isEmpty { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private nonisolated(unsafe) static var results: [Bool] = []
    private var results: [Bool] { Self.results }

    func testPermissionWindowOutlivesClose() {
        _ = NSApplication.shared
        let window = PermissionHelper.makePermissionWindow()
        Self.retainedWindows.append(window)

        XCTAssertFalse(window.isReleasedWhenClosed)

        weak let weakWindow = window
        window.close()
        window.close()

        XCTAssertNotNil(weakWindow, "close() must not deallocate a window we still hold")
        XCTAssertNotNil(window.contentView)
    }

    /// A title-bar close abandons the flow, and the caller has to hear about it: main.swift
    /// only starts the clients (or exits a background service) from that callback.
    func testUserClosingTheWindowResolvesThePendingCallback() async {
        _ = NSApplication.shared
        let window = PermissionHelper.makePermissionWindow()
        window.delegate = PermissionHelperTarget.shared
        Self.retainedWindows.append(window)
        Self.results = []
        PermissionHelper.window = window
        PermissionHelper.completion = { Self.results.append($0) }

        window.close()
        await drainDeferredWork()

        XCTAssertEqual(results, [false])
        XCTAssertNil(PermissionHelper.window)
        XCTAssertNil(PermissionHelper.completion)
    }

    /// `finish()` closes the window itself, and that close must not be mistaken for the user
    /// walking away — it would flip a granted result into a denial.
    func testProgrammaticFinishKeepsItsOwnResult() async {
        _ = NSApplication.shared
        let window = PermissionHelper.makePermissionWindow()
        window.delegate = PermissionHelperTarget.shared
        Self.retainedWindows.append(window)
        Self.results = []
        PermissionHelper.window = window
        PermissionHelper.completion = { Self.results.append($0) }

        PermissionHelper.finish(granted: true)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(results, [true])
        XCTAssertNil(PermissionHelper.window)
    }
}
