import AppKit
import XCTest
@testable import ntfyx

/// The history sidebar has to come back at the width the user dragged it to. Two things
/// made every drag look forgotten: a narrow drag being discarded as implausible, and the
/// remembered width being applied to a split view that does not hold the column.
@MainActor
final class SidebarWidthTests: XCTestCase {

    /// XCTest releases everything created inside a test scope, and its post-scope object
    /// check segfaults on AppKit windows. Leaving them retained until the process ends
    /// keeps the assertion out of the way of what these tests are actually about.
    nonisolated(unsafe) static var retainedWindows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        // NSWindow needs AppKit initialized; a test process does not do that on its own.
        _ = NSApplication.shared
    }

    private func makeDefaults() -> (String, UserDefaults) {
        let suiteName = "SidebarWidthTests-\(UUID().uuidString)"
        return (suiteName, UserDefaults(suiteName: suiteName)!)
    }

    /// A vertical split view with the given pane widths, in a window so the frames mean
    /// something. A split view lays its panes out evenly until the divider is moved.
    private func makeSplit(paneWidths: [CGFloat], total: CGFloat = 900) -> NSSplitView {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: total, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: total, height: 400))
        split.isVertical = true
        split.dividerStyle = .thin
        for width in paneWidths {
            let pane = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
            split.addArrangedSubview(pane)
        }
        window.contentView = split
        window.layoutIfNeeded()
        if paneWidths.count > 1 {
            split.setPosition(paneWidths[0], ofDividerAt: 0)
            window.layoutIfNeeded()
        }
        Self.retainedWindows.append(window)
        return split
    }

    // MARK: - Stored value policy

    func testDraggedWidthIsRemembered() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(300, forKey: SidebarWidth.key)
        XCTAssertEqual(SidebarWidth.saved(in: defaults), 300)
    }

    /// A drag past the column's declared minimum is still the width the user chose.
    func testNarrowDragIsRememberedInsteadOfBeingDiscarded() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(144, forKey: SidebarWidth.key)
        XCTAssertEqual(SidebarWidth.saved(in: defaults), 144)
    }

    /// A hidden sidebar leaves a collapsed column behind; that is not a chosen width, and
    /// neither is a stale or corrupt entry.
    func testCollapsedOrCorruptEntryIsIgnored() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(SidebarWidth.saved(in: defaults))
        for width in [0.0, 40.0, 5_000.0] {
            defaults.set(width, forKey: SidebarWidth.key)
            XCTAssertNil(SidebarWidth.saved(in: defaults), "width \(width)")
        }
    }

    // MARK: - Split view

    /// `NavigationSplitView` also builds wrapper split views with a single pane; the one
    /// holding the column is the outermost with at least two panes.
    func testSidebarSplitSkipsSinglePaneWrappers() throws {
        let wrapper = makeSplit(paneWidths: [900])
        guard let host = wrapper.subviews.first else { return XCTFail("wrapper has no pane") }

        let column = makeSplit(paneWidths: [260, 640])
        host.addSubview(column)
        wrapper.window?.layoutIfNeeded()

        XCTAssertEqual(SidebarWidth.sidebarSplit(in: wrapper), column)
        XCTAssertNil(SidebarWidth.columnWidth(of: wrapper), "a one-pane split view has no column")
    }

    func testColumnWidthIsTheSidebarPane() throws {
        let split = makeSplit(paneWidths: [260, 640])

        XCTAssertEqual(SidebarWidth.columnWidth(of: split), 260)

        split.setPosition(144, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        XCTAssertEqual(SidebarWidth.columnWidth(of: split), 144)
    }

    /// A hidden sidebar collapses the column to ~0; reading that back as a width would
    /// forget the user's choice the first time they toggle the sidebar off.
    func testCollapsedColumnHasNoWidth() throws {
        let split = makeSplit(paneWidths: [260, 640])

        split.setPosition(0, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        XCTAssertNil(SidebarWidth.columnWidth(of: split))
    }

    func testRestoreMovesTheDividerAndReadsBack() throws {
        let split = makeSplit(paneWidths: [260, 640])

        XCTAssertTrue(SidebarWidth.restore(402, to: split))
        XCTAssertEqual(SidebarWidth.columnWidth(of: split), 402)
    }

    func testRestoreNeedsARealColumn() throws {
        let split = makeSplit(paneWidths: [900])

        XCTAssertFalse(SidebarWidth.restore(402, to: split))
        XCTAssertFalse(SidebarWidth.restore(402, to: nil))
    }
}
