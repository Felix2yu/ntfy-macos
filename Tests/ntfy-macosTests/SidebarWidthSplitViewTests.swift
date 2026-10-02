import AppKit
import SwiftUI
import XCTest
@testable import ntfy_macos

/// The remembered width has to be applied to the split view SwiftUI builds for
/// `NavigationSplitView` — not to a wrapper around it — and it has to survive SwiftUI's
/// next layout pass. `NSSplitView.subviews` on that split view holds panes, dividers,
/// shadows and collapse handles in an order that does not match the layout, which is what
/// made an earlier attempt read and set the wrong pane.
@MainActor
final class SidebarWidthSplitViewTests: XCTestCase {

    /// XCTest's post-scope object check crashes on AppKit windows released during a test,
    /// so the windows these tests create outlive the run.
    nonisolated(unsafe) static var retainedWindows: [NSWindow] = []

    private struct Probe: View {
        let width: Double

        var body: some View {
            NavigationSplitView {
                Text("sidebar")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationSplitViewColumnWidth(min: SidebarWidth.min,
                                                    ideal: width,
                                                    max: SidebarWidth.max)
            } detail: {
                Text("detail").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 860, minHeight: 560)
        }
    }

    private func hostColumn(idealWidth: Double) throws -> NSSplitView {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 950, height: 620),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: Probe(width: idealWidth))
        Self.retainedWindows.append(window)
        window.orderFront(nil)
        window.layoutIfNeeded()
        let split = try XCTUnwrap(SidebarWidth.sidebarSplit(in: window.contentView),
                                  "no split view with two panes was laid out")
        window.orderOut(nil)
        return split
    }

    func testRememberedIdealDecidesTheLaunchColumn() throws {
        let split = try hostColumn(idealWidth: 402)
        XCTAssertEqual(SidebarWidth.columnWidth(of: split), 402)
    }

    func testRestoreMovesTheRealColumn() throws {
        let split = try hostColumn(idealWidth: 260)
        XCTAssertEqual(SidebarWidth.columnWidth(of: split), 260)

        XCTAssertTrue(SidebarWidth.restore(402, to: split))
        XCTAssertEqual(SidebarWidth.columnWidth(of: split), 402)
    }

    /// SwiftUI must not pull the column back to `ideal` on the next layout pass, or the
    /// restore would undo itself as soon as a message arrived.
    func testRestoredColumnSurvivesLayout() throws {
        let split = try hostColumn(idealWidth: 260)
        XCTAssertTrue(SidebarWidth.restore(198, to: split))

        split.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(SidebarWidth.columnWidth(of: split), 198)
    }
}
