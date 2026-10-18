#if DEBUG
import SwiftUI

/// Local-only preview data; sending here never calls an API or changes a conversation.
private struct ChatStylePreview: View {
    @State private var text = ""
    @State private var attachments: [Attachment] = []
    @State private var reply: ChatMessage?
    @FocusState private var focused: Bool
    @State private var messages: [ChatMessage] = [
        ChatMessage(role: .user, text: "周末想去海边走走，帮我安排一下。"),
        ChatMessage(role: .assistant, text: "当然。想轻松一点的话，可以上午出发，沿着海边散步，再找一家喜欢的咖啡店。"),
        ChatMessage(role: .assistant, text: "你想当天往返，还是住一晚？"),
        ChatMessage(role: .user, text: "当天往返就好 ☀️", reactions: ["👍"])
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(ChatRowModel.build(messages, running: false)) { row in
                        MessageRowView(row: row, replied: nil, actions: actions)
                    }
                    HStack { TypingIndicator(); Spacer() }.padding(.top, 10)
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                InputBar(text: $text, attachments: $attachments, replyTo: $reply, focus: $focused,
                         isRunning: false, onSend: {
                    messages.append(ChatMessage(role: .user, text: text, replyToID: reply?.id))
                    text = ""
                    reply = nil
                }, onStop: {})
            }
            .navigationTitle("Mira")
            .navigationBarTitleDisplayMode(.inline)
        }
        .environmentObject(AppStore.shared)
    }

    private var actions: ChatActions {
        ChatActions(react: { message, emoji in
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index].reactions = [emoji]
            }
        }, reply: { reply = $0; focused = true }, regenerate: { _ in }, edit: { text = $0.text },
                    delete: { message in messages.removeAll { $0.id == message.id } },
                    approve: { _, _ in }, inspect: { _ in }, openImage: { _ in }, retry: {})
    }
}

#Preview("信息 · 浅色") {
    ChatStylePreview().preferredColorScheme(.light)
}

#Preview("信息 · 深色") {
    ChatStylePreview().preferredColorScheme(.dark)
}

#Preview("信息 · 大字体") {
    ChatStylePreview()
        .environment(\.dynamicTypeSize, .accessibility2)
    // Reduce Transparency and Reduce Motion are read-only environment values.
    // Exercise those modes through the simulator or device Accessibility settings.
}
#endif
