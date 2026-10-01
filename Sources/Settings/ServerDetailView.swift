import SwiftUI

// MARK: - TextField Style Modifier

struct LockedTextFieldModifier: ViewModifier {
    let isLocked: Bool
    
    func body(content: Content) -> some View {
        if isLocked {
            content.textFieldStyle(.plain)
        } else {
            content.textFieldStyle(.roundedBorder)
        }
    }
}

struct ServerDetailView: View {
    @Binding var server: EditableServer
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showTokenSheet = false

    private var isLocked: Bool { viewModel.isLocked }

    var body: some View {
        Form {
            Section("服务器") {
                HStack {
                    Text("URL")
                        .foregroundStyle(.secondary)
                    TextField("", text: $server.url)
                        .modifier(LockedTextFieldModifier(isLocked: isLocked))
                        .disabled(isLocked)
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
                    .disabled(isLocked)
                }

                Toggle("重连时拉取错过的消息", isOn: $server.fetchMissed)
                    .foregroundStyle(.secondary)
                    .disabled(isLocked)
            }

            Section {
                ForEach($server.topics) { $topic in
                    TopicRowView(topic: $topic, isLocked: isLocked) {
                        server.topics.removeAll { $0.id == topic.id }
                    }
                }

                if !isLocked {
                    Button {
                        viewModel.addTopic(to: server.id)
                    } label: {
                        Label("添加主题", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                HStack {
                    Text("主题")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("拉取")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .sheet(isPresented: $showTokenSheet) {
            TokenSheetView(server: $server)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if let error = viewModel.saveError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(1)
                }

                Spacer()

                if !viewModel.isLocked {
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
            }
            .padding(12)
        }
        .background(.bar)
    }
}

// MARK: - Token Management Sheet

struct TokenSheetView: View {
    @Binding var server: EditableServer
    @Environment(\.dismiss) private var dismiss

    @State private var tokenText: String = ""
    @State private var storageChoice: TokenStorage = .keychain

    enum TokenStorage: String, CaseIterable {
        case keychain = "钥匙串（推荐）"
        case configFile = "配置文件"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if !server.token.isEmpty {
                        HStack {
                            Label(
                                server.storeInKeychain ? "当前存于钥匙串" : "当前存于配置文件",
                                systemImage: server.storeInKeychain ? "key.fill" : "doc.text"
                            )
                            Spacer()
                            Button {
                                server.token = ""
                                server.storeInKeychain = false
                                dismiss()
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("删除令牌")
                        }
                    }
                } header: {
                    Text("当前状态")
                }

                Section {
                    SecureField("输入令牌", text: $tokenText)

                    Picker("存储位置", selection: $storageChoice) {
                        ForEach(TokenStorage.allCases, id: \.self) { storage in
                            Text(storage.rawValue).tag(storage)
                        }
                    }
                } header: {
                    Text(server.token.isEmpty ? "添加令牌" : "替换令牌")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("保存令牌") {
                    server.token = tokenText
                    server.storeInKeychain = (storageChoice == .keychain)
                    dismiss()
                }
                .disabled(tokenText.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(12)
        }
        .frame(width: 420, height: 280)
        .onAppear {
            storageChoice = server.storeInKeychain ? .keychain : .configFile
        }
    }
}
