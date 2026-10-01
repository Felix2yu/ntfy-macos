import SwiftUI

struct TopicRowView: View {
    @Binding var topic: EditableTopic
    var isLocked: Bool
    var onDelete: (() -> Void)?

    var body: some View {
        HStack {
            if !isLocked, let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("删除主题")
            }

            Image(systemName: "number")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("", text: $topic.name, prompt: Text("主题"))
                .modifier(LockedTextFieldModifier(isLocked: isLocked))
                .disabled(isLocked)

            Spacer()

            Toggle("拉取", isOn: Binding(
                get: { topic.fetchMissed ?? false },
                set: { topic.fetchMissed = $0 ? true : nil }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(isLocked)
        }
    }
}
