import SwiftUI
import AppKit

/// Single-page grouped settings form: 通用 / ntfy 服务器 / 本地通知服务,
/// servers rendered as collapsible rows so one or two servers stay compact.
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var copiedCommand: String?
    @State private var statusTimer: Timer?

    @AppStorage(AppSettings.expandMessagesByDefaultKey) private var expandByDefault = false
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    private var isLocalServerEnabled: Bool {
        !viewModel.localServerPort.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            generalSection
            serversSection
            localServerSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 460, idealHeight: 600)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onAppear {
            viewModel.refreshConnectionStates()
            startStatusTimer()
            launchAtLogin = LoginItem.isEnabled
        }
        .onDisappear {
            stopStatusTimer()
        }
    }

    // MARK: - 通用

    private var generalSection: some View {
        Section {
            Toggle("开机时启动", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    if let error = LoginItem.setEnabled(newValue) {
                        loginError = error
                        return
                    }
                    loginError = nil
                    launchAtLogin = newValue
                }
            ))
            .help("登录后自动在菜单栏运行 ntfy-macos")

            if let loginError {
                Text(loginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Toggle("默认展开消息全文", isOn: $expandByDefault)
                .help("长消息进入通知历史时即完整显示；单条仍可点击「收起」折回")
        } header: {
            Text("通用")
        }
    }

    // MARK: - 服务器

    private var serversSection: some View {
        Section {
            ForEach($viewModel.servers) { $server in
                ServerRowView(server: $server, viewModel: viewModel)
            }

            Button {
                viewModel.addServer()
            } label: {
                Label("添加服务器", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            HStack {
                Text("ntfy 服务器")
                if viewModel.hasUnsavedChanges {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                        .help("有未保存的更改")
                }
            }
        }
    }

    // MARK: - 本地通知服务

    private var localServerSection: some View {
        Section {
            HStack {
                Text("端口")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("留空以禁用", text: $viewModel.localServerPort)
                    .frame(width: 120)
                    .multilineTextAlignment(.trailing)
            }

            Text("端口范围须为 1024–65535；留空表示禁用本地通知服务。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isLocalServerEnabled {
                commandRow(
                    label: "curl",
                    command: "curl -X POST http://127.0.0.1:\(viewModel.localServerPort)/notify -H \"Content-Type: application/json\" -d '{\"title\": \"Hello\", \"message\": \"Hello from ntfy-macos!\"}'"
                )
            }
        } header: {
            Text("本地通知服务")
        }
    }

    private func commandRow(label: String, command: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .font(.caption)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )

            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copiedCommand = command

                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if copiedCommand == command {
                        copiedCommand = nil
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copiedCommand == command ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.caption)
                    Text(copiedCommand == command ? "已拷贝" : "拷贝")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(copiedCommand == command ? .green : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(copiedCommand == command ? Color.green.opacity(0.2) : Color.accentColor)
                )
            }
            .buttonStyle(.plain)
            .help("拷贝到剪贴板")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.blue.opacity(0.08),
                            Color.cyan.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.blue.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: ConfigManager.defaultConfigPath))
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.borderless)
                .help("在编辑器中打开配置文件")

                if let error = viewModel.saveError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button("取消") {
                    viewModel.cancel()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("保存") {
                    viewModel.save()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!viewModel.hasUnsavedChanges)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .background(.bar)
    }

    // MARK: - Status refresh timer

    private func startStatusTimer() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor in
                viewModel.refreshConnectionStates()
            }
        }
    }

    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }
}

// MARK: - Server row (collapsible)

private struct ServerRowView: View {
    @Binding var server: EditableServer
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showTokenSheet = false
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 10) {
                HStack {
                    Text("URL")
                        .foregroundStyle(.secondary)
                    TextField("", text: $server.url)
                }

                HStack {
                    if server.token.isEmpty {
                        Text("令牌：未配置")
                            .foregroundStyle(.secondary)
                    } else if server.storeInKeychain {
                        Label("令牌存储于钥匙串", systemImage: "key.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("令牌存储于配置文件", systemImage: "doc.text")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("管理…") {
                        showTokenSheet = true
                    }
                }

                Toggle("重连时拉取错过的消息", isOn: $server.fetchMissed)
                    .foregroundStyle(.secondary)

                Divider()

                ForEach($server.topics) { $topic in
                    TopicRowView(topic: $topic) {
                        server.topics.removeAll { $0.id == topic.id }
                    }
                }

                HStack {
                    Button {
                        viewModel.addTopic(to: server.id)
                    } label: {
                        Label("添加主题", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button(role: .destructive) {
                        viewModel.removeServer(server)
                    } label: {
                        Text("删除此服务器")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(connectionColor(for: server.url))
                    .frame(width: 8, height: 8)
                Text(server.url.isEmpty ? "新服务器" : server.url)
                    .fontWeight(.medium)
                Spacer()
                Text("\(server.topics.count) 个主题")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .sheet(isPresented: $showTokenSheet) {
            TokenSheetView(server: $server)
        }
    }

    private func connectionColor(for url: String) -> Color {
        guard !url.isEmpty, let state = viewModel.serverConnectionStates[url] else { return .gray }
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        }
    }
}
