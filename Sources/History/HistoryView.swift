import SwiftUI
import AppKit

/// Root view of the notification history window:
/// sidebar with topics (grouped by server, unread badges) + message list.
struct HistoryView: View {
    @ObservedObject var viewModel: HistoryViewModel

    /// Column width to start at, read once at window creation. A stored value kept live
    /// would let SwiftUI re-assert the column while the user is dragging the divider.
    let initialSidebarWidth: Double

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: SidebarWidth.min,
                                                ideal: CGFloat(initialSidebarWidth),
                                                max: SidebarWidth.max)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            if let ref = viewModel.selectedTopic {
                TopicDetailView(viewModel: viewModel, topicRef: ref)
                    .id(ref)  // reset scroll state when switching topics
            } else {
                Text("选择一个主题查看历史消息")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .toolbar {
            // Own toggle pinned to the leading edge: the automatic one rides the
            // column divider, so it jumped to the far right when the sidebar hid.
            ToolbarItem(placement: .navigation) {
                Button {
                    NSApp.keyWindow?.firstResponder?
                        .tryToPerform(NSSelectorFromString("toggleSidebar:"), with: nil)
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("显示/隐藏侧栏")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.markEverythingRead()
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .help(viewModel.totalUnread > 0 ? "全部标记已读（\(viewModel.totalUnread) 条未读）" : "没有未读消息")
                .disabled(viewModel.totalUnread == 0)
            }
        }
        .onAppear {
            viewModel.refreshSidebar()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding<TopicRef?>(
            get: { viewModel.selectedTopic },
            set: { viewModel.selectTopic($0) }
        )) {
            if viewModel.groups.isEmpty {
                Text("未配置服务器或主题")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.groups) { group in
                Section(group.url) {
                    ForEach(group.topics) { entry in
                        topicRow(entry)
                            .tag(entry.ref)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if viewModel.totalUnread > 0 {
                    Text("\(viewModel.totalUnread) 条未读")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func topicRow(_ entry: HistoryViewModel.TopicEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: entry.iconSymbol ?? "bell")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(entry.ref.topic)
                .lineLimit(1)
            Spacer()
            if entry.unread > 0 {
                Text("\(entry.unread)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
            }
        }
    }
}
