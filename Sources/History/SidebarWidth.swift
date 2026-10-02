import AppKit
import Foundation

/// Width policy of the notification history sidebar.
///
/// A divider drag is only visible on the AppKit side, so `HistoryWindowController` reads
/// the column off the split view SwiftUI builds for `NavigationSplitView` and stores it;
/// `navigationSplitViewColumnWidth`'s `ideal` then provides that width at launch.
@MainActor
enum SidebarWidth {
    static let key = AppSettings.historySidebarWidthKey

    /// Band the column is allowed to be dragged within. Wide enough that any width the
    /// user can reach with the divider is also one that can be remembered.
    static let min: CGFloat = 160
    static let max: CGFloat = 600

    /// Column width before the user has dragged one.
    static let fallback: Double = 260

    /// Widths a visible column can plausibly have. Hiding the sidebar collapses the
    /// column to ~0, and a stale or corrupt entry can be anything, so only a value in
    /// this band is taken for a width the user chose.
    static let plausibleRange: ClosedRange<Double> = 100...600

    static func saved(in defaults: UserDefaults = .standard) -> Double? {
        let width = defaults.double(forKey: key)
        return plausibleRange.contains(width) ? width : nil
    }

    // MARK: - Reading and writing the live split view

    /// Every `NSSplitView` below `root`, outermost first.
    static func splitViews(in root: NSView?) -> [NSSplitView] {
        guard let root else { return [] }
        var found: [NSSplitView] = []
        var queue: [NSView] = [root]
        while let view = queue.first {
            queue.removeFirst()
            if let split = view as? NSSplitView { found.append(split) }
            queue.append(contentsOf: view.subviews)
        }
        return found
    }

    /// The split view holding the sidebar column: the outermost one with at least two
    /// panes. `arrangedSubviews` are the panes, while `subviews` also mixes in dividers,
    /// shadows and collapse handles — and in a different order, which makes it useless
    /// for telling which pane is the sidebar.
    static func sidebarSplit(in root: NSView?) -> NSSplitView? {
        splitViews(in: root).first { $0.arrangedSubviews.count >= 2 }
    }

    static func columnWidth(of split: NSSplitView?) -> Double? {
        guard let split, split.arrangedSubviews.count >= 2,
              let pane = split.arrangedSubviews.first,
              !split.isSubviewCollapsed(pane) else { return nil }
        let width = Double(pane.frame.width)
        return plausibleRange.contains(width) ? width : nil
    }

    /// Moves the divider that follows the sidebar pane to `width` and reports whether the
    /// column actually ended up there.
    @discardableResult
    static func restore(_ width: Double, to split: NSSplitView?) -> Bool {
        guard let split, split.arrangedSubviews.count >= 2 else { return false }
        split.setPosition(CGFloat(width), ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        guard let applied = columnWidth(of: split) else { return false }
        return abs(applied - width) < 1.5
    }

    static func describe(_ split: NSSplitView) -> String {
        let panes = split.arrangedSubviews.map { String(format: "%.0f", $0.frame.width) }
            .joined(separator: ",")
        return "\(type(of: split)) panes=[\(panes)]"
    }
}
