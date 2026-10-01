import SwiftUI

/// A single notification card in the history list, mirroring ntfy web's NotificationCard:
/// priority icon + emoji-tagged title + time, body, actions row, attachment row, click link,
/// and hover operations (read toggle / copy / delete).
struct MessageCardView: View {
    let stored: StoredMessage
    let onToggleRead: () -> Void
    let onDelete: () -> Void
    let onCopy: () -> Void
    let onOpenURL: (String) -> Void
    let onAction: (NtfyMessage.NtfyAction) -> Void

    @State private var isHovered = false
    @State private var isExpanded = false

    private var message: NtfyMessage { stored.message }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Unread indicator
            Circle()
                .fill(stored.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 6) {
                headerRow
                bodyText
                clickRow
                attachmentRow
                actionsRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(stored.isRead ? Color.primary.opacity(0.03) : Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(stored.isRead ? 0.06 : 0.12), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            hoverButtons
                .padding(.trailing, 6)
                .padding(.top, 4)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .onHover { isHovered = $0 }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            if let priorityIcon = priorityIcon {
                Image(systemName: priorityIcon.symbol)
                    .foregroundStyle(priorityIcon.color)
            }

            Text(fullTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(MessageActionService.formattedTime(message.time))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }

    private var fullTitle: String {
        let emoji = EmojiTags.emojiPrefix(for: message.tags)
        let title = message.plainTextTitle ?? message.title
        if let title, !title.isEmpty {
            return emoji + title
        }
        return emoji + message.topic
    }

    private var hoverButtons: some View {
        HStack(spacing: 2) {
            cardButton(
                symbol: stored.isRead ? "envelope.open" : "envelope.badge",
                help: stored.isRead ? "标为未读" : "标为已读",
                action: onToggleRead
            )
            cardButton(symbol: "doc.on.doc", help: "复制消息内容", action: onCopy)
            cardButton(symbol: "trash", help: "删除这条消息", action: onDelete)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private func cardButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: - Body

    @ViewBuilder
    private var bodyText: some View {
        if let body = message.plainTextMessage ?? message.message, !body.isEmpty {
            // Plain text (markdown stripped) keeps rendering cost low for large histories.
            Text(body)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(isExpanded ? nil : 6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .onTapGesture { isExpanded.toggle() }
        }
    }

    // MARK: - Click URL

    @ViewBuilder
    private var clickRow: some View {
        if let click = message.click, !click.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "link")
                    .font(.caption)
                Text(click)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.link)
            .contentShape(Rectangle())
            .onTapGesture { onOpenURL(click) }
            .help("打开链接")
        }
    }

    // MARK: - Attachment

    @ViewBuilder
    private var attachmentRow: some View {
        if let attachment = message.attachment {
            HStack(spacing: 6) {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
                Text(attachment.name)
                    .font(.callout)
                    .lineLimit(1)
                if let size = attachment.size {
                    Text(MessageActionService.formattedFileSize(size))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.link)
            .contentShape(Rectangle())
            .onTapGesture { onOpenURL(attachment.url) }
            .help("下载附件")
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsRow: some View {
        if let actions = message.actions, !actions.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Button {
                        onAction(action)
                    } label: {
                        Label(action.label, systemImage: symbolForAction(action))
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(helpForAction(action))
                }
            }
        }
    }

    private func symbolForAction(_ action: NtfyMessage.NtfyAction) -> String {
        switch action.action {
        case "view": return "safari"
        case "http": return "network"
        case "copy": return "doc.on.doc"
        default: return "rectangle.portrait.on.rectangle.portrait"
        }
    }

    private func helpForAction(_ action: NtfyMessage.NtfyAction) -> String {
        switch action.action {
        case "view": return "打开 \(action.url ?? "")"
        case "http": return "发送 \(action.method ?? "POST") 请求"
        case "copy": return "复制到剪贴板"
        default: return action.action
        }
    }

    // MARK: - Priority

    private var priorityIcon: (symbol: String, color: Color)? {
        switch message.priority {
        case 5: return ("exclamationmark.triangle.fill", .red)
        case 4: return ("exclamationmark.circle.fill", .orange)
        case 2: return ("arrow.down.circle", .teal)
        case 1: return ("arrow.down.to.line", .secondary)
        default: return nil  // priority 3 / nil: no icon, like ntfy web
        }
    }
}
