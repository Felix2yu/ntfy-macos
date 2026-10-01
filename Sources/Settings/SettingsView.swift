import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var copiedCommand: String?
    @State private var statusTimer: Timer?

    private var isLocalServerEnabled: Bool {
        !viewModel.localServerPort.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 700, idealWidth: 800, minHeight: 500, idealHeight: 600)
        .onAppear {
            viewModel.refreshConnectionStates()
            startStatusTimer()
        }
        .onDisappear {
            stopStatusTimer()
        }
    }

    // MARK: - Status Refresh Timer

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

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $viewModel.selectedServerID) {
            Section {
                localServerSection
            } header: {
                Text("本地服务器")
                    .foregroundStyle(.secondary)
            }

            Section("服务器") {
                ForEach(viewModel.servers) { server in
                    HStack {
                        Label(
                            server.url.isEmpty ? "新服务器" : server.url
                                .replacingOccurrences(of: "https://", with: "")
                                .replacingOccurrences(of: "http://", with: ""),
                            systemImage: "server.rack"
                        )
                        .foregroundStyle(.secondary)

                        Spacer()

                        // Connection status indicator
                        if !server.url.isEmpty, let state = viewModel.serverConnectionStates[server.url] {
                            Circle()
                                .fill(connectionColor(for: state))
                                .frame(width: 8, height: 8)
                                .help(connectionTooltip(for: state))
                        }
                    }
                    .tag(server.id)
                }
                .onDelete { indexSet in
                    guard !viewModel.isLocked else { return }
                    for index in indexSet {
                        viewModel.removeServer(viewModel.servers[index])
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
    }

    // MARK: - Connection State Helpers

    private func connectionColor(for state: StatusBarController.ConnectionState) -> Color {
        switch state {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .red
        }
    }

    private func connectionTooltip(for state: StatusBarController.ConnectionState) -> String {
        switch state {
        case .connected:
            return "已连接"
        case .connecting:
            return "连接中…"
        case .disconnected:
            return "已断开"
        }
    }

    // MARK: - Local Server Section

    private var localServerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Port configuration
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("端口")
                        .foregroundStyle(.secondary)

                    Spacer()

                    TextField("如 9292", text: $viewModel.localServerPort)
                        .modifier(LockedTextFieldModifier(isLocked: viewModel.isLocked))
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                        .disabled(viewModel.isLocked)
                }

                Text("端口范围须为 1024–65535")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Usage example (shown when port is configured)
            if isLocalServerEnabled {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("试一试：")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // curl example with copy
                    commandRow(
                        label: "curl",
                        command: "curl -X POST http://127.0.0.1:\(viewModel.localServerPort)/notify -H \"Content-Type: application/json\" -d '{\"title\": \"Hello\", \"message\": \"Hello from ntfy-macos!\"}'"
                    )
                }
            }
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

                // Reset after 2 seconds
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

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Button {
                viewModel.isLocked.toggle()
            } label: {
                Image(systemName: viewModel.isLocked ? "lock.fill" : "lock.open.fill")
            }
            .buttonStyle(.plain)
            .help(viewModel.isLocked ? "点击解锁编辑" : "锁定编辑")

            Divider()
                .frame(height: 16)

            Button(action: viewModel.addServer) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isLocked)

            if let selectedID = viewModel.selectedServerID,
               let server = viewModel.servers.first(where: { $0.id == selectedID }) {
                Button(action: { viewModel.removeServer(server) }) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isLocked)
            }

            Spacer()

            if viewModel.hasUnsavedChanges {
                Circle()
                    .fill(.orange)
                    .frame(width: 8, height: 8)
                    .help("有未保存的更改")
            }

            Button {
                let path = ConfigManager.defaultConfigPath
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } label: {
                Image(systemName: "doc.text")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isLocked)
            .help("在编辑器中打开配置文件")
        }
        .padding(8)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let index = viewModel.selectedServerIndex() {
            ServerDetailView(
                server: $viewModel.servers[index],
                viewModel: viewModel
            )
            .id(viewModel.servers[index].id)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "server.rack")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("选择或添加一个服务器")
                    .foregroundStyle(.secondary)
                Button("添加服务器") {
                    viewModel.isLocked = false
                    viewModel.addServer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
