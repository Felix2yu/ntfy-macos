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
            if viewModel.isGlobalSearchActive {
                globalSearchResults
            } else if let ref = viewModel.selectedTopic {
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
                TextField("全局搜索", text: $viewModel.globalQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .help("在所有主题的标题、正文与名称中搜索")
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

    // MARK: - Global search results

    private var globalSearchResults: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(viewModel.isGlobalSearching
                    ? "搜索中…"
                    : viewModel.globalResults.count >= HistoryViewModel.globalSearchCap
                        ? "前 \(viewModel.globalResults.count) 条结果"
                        : "\(viewModel.globalResults.count) 条结果")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("退出搜索") {
                    viewModel.globalQuery = ""
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if viewModel.globalResults.isEmpty {
                VStack(spacing: 8) {
                    if viewModel.isGlobalSearching {
                        ProgressView()
                    } else {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text("没有匹配的消息")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.globalResults) { hit in
                            GlobalSearchResultRow(hit: hit) {
                                viewModel.openGlobalResult(hit)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One row in the global search result list; clicking it opens the hit's topic.
private struct GlobalSearchResultRow: View {
    let hit: StoredMessage
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(hit.topic)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(hit.serverURL)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    Text(MessageActionService.formattedTime(hit.time))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let title = hit.message.title, !title.isEmpty {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                if let body = hit.message.message, !body.isEmpty {
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hit.isRead ? Color.clear : Color.accentColor.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(hit.isRead ? Color.secondary.opacity(0.15) : Color.accentColor.opacity(0.3),
                                  lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开主题「\(hit.topic)」")
    }
}
