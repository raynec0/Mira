import SwiftUI
import UIKit

struct ChatRowModel: Identifiable {
    let id: UUID
    let message: ChatMessage
    let showTimestamp: Bool
    let startsGroup: Bool
    let tail: Bool
    let status: String?

    private static func side(_ m: ChatMessage) -> Int {
        switch m.role {
        case .user: return 1
        case .event: return 0
        default: return -1
        }
    }

    static func build(_ messages: [ChatMessage], running: Bool) -> [ChatRowModel] {
        let visible = messages.filter { m in
            switch m.role {
            case .tool: return !m.attachments.isEmpty
            case .assistant: return m.isStreaming || !m.text.isEmpty || !m.toolCalls.isEmpty || !m.reasoning.isEmpty
            default: return true
            }
        }
        let lastUser = visible.lastIndex { $0.role == .user }
        var rows: [ChatRowModel] = []
        for (i, m) in visible.enumerated() {
            let prev: ChatMessage? = i > 0 ? visible[i - 1] : nil
            let next: ChatMessage? = i + 1 < visible.count ? visible[i + 1] : nil
            let showTime = prev.map {
                !Calendar.current.isDate(m.createdAt, inSameDayAs: $0.createdAt)
                    || m.createdAt.timeIntervalSince($0.createdAt) > 900
            } ?? true
            let startsGroup = showTime || (prev.map {
                side($0) != side(m) || m.createdAt.timeIntervalSince($0.createdAt) >= 120
            } ?? true)
            var tail = true
            if let next, side(next) == side(m),
               Calendar.current.isDate(next.createdAt, inSameDayAs: m.createdAt),
               next.createdAt.timeIntervalSince(m.createdAt) < 120 {
                tail = false
            }
            var status: String?
            if i == lastUser {
                let answered = visible[(i + 1)...].contains { $0.role == .assistant }
                status = answered || running ? "已读" : "已送达"
            }
            rows.append(ChatRowModel(id: m.id, message: m, showTimestamp: showTime,
                                     startsGroup: startsGroup, tail: tail, status: status))
        }
        return rows
    }
}

struct ChatActions {
    var react: (ChatMessage, String) -> Void
    var reply: (ChatMessage) -> Void
    var regenerate: (ChatMessage) -> Void
    var edit: (ChatMessage) -> Void
    var delete: (ChatMessage) -> Void
    var approve: (ToolCallRecord, ApprovalDecision) -> Void
    var inspect: (ToolCallRecord) -> Void
    var openImage: (Attachment) -> Void
    var retry: () -> Void
}

struct MessageRowView: View {
    let row: ChatRowModel
    let replied: ChatMessage?
    let actions: ChatActions

    private var message: ChatMessage { row.message }
    private static let reactionChoices = ["❤️", "👍", "👎", "😂", "‼️", "❓"]

    var body: some View {
        VStack(spacing: 3) {
            if row.showTimestamp {
                Text(RelativeTime.chatHeader(message.createdAt))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }
            Group {
                switch message.role {
                case .event: eventBody
                case .user: userBody
                case .assistant: assistantBody
                case .tool: toolBody
                }
            }
            .modifier(SwipeReplyModifier(enabled: (message.role == .user || message.role == .assistant)
                                        && !message.isStreaming,
                                        onReply: { actions.reply(message) }))
            .padding(.top, row.startsGroup && !row.showTimestamp ? 8 : 0)
        }
        .padding(.bottom, row.tail ? 6 : 0)
    }

    // MARK: 用户

    private var userBody: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let replied {
                ReplyQuote(text: replied.text.isEmpty ? "附件" : replied.text, isUser: true)
            }
            ForEach(message.attachments) { att in
                AttachmentBubble(attachment: att, isUser: true, onOpen: actions.openImage)
            }
            if !message.text.isEmpty {
                BubbleView(isUser: true, tail: row.tail) {
                    Text(message.text)
                        .font(.body)
                        .textSelection(.enabled)
                }
                .reactions(message.reactions, isUser: true)
                .contextMenu { menu }
                .onTapGesture(count: 2) { actions.react(message, "❤️") }
            }
            if let status = row.status {
                Text(status)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 56)
    }

    // MARK: 智能体

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let replied {
                ReplyQuote(text: replied.text.isEmpty ? "附件" : replied.text, isUser: false)
            }
            if !message.reasoning.isEmpty {
                ReasoningView(text: message.reasoning, active: message.isStreaming && message.text.isEmpty)
            }
            ForEach(message.toolCalls) { call in
                if call.state == .awaitingApproval {
                    ApprovalCard(call: call) { decision in actions.approve(call, decision) }
                } else {
                    ToolChip(call: call) { actions.inspect(call) }
                }
            }
            if !message.text.isEmpty {
                BubbleView(isUser: false, tail: row.tail) {
                    MarkdownText(text: message.text)
                }
                .reactions(message.reactions, isUser: false)
                .contextMenu { menu }
                .onTapGesture(count: 2) { actions.react(message, "❤️") }
            } else if message.isStreaming && message.toolCalls.isEmpty {
                TypingIndicator()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 44)
    }

    // MARK: 工具产物

    private var toolBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(message.attachments) { att in
                AttachmentBubble(attachment: att, isUser: false, onOpen: actions.openImage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 56)
    }

    // MARK: 事件

    private var eventBody: some View {
        VStack(spacing: 6) {
            Text(message.text)
                .font(.footnote)
                .foregroundStyle(message.isError ? Color.red : Color.secondary)
                .multilineTextAlignment(.center)
            if message.isError {
                Button("重试", action: actions.retry)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
    }

    // MARK: 菜单

    @ViewBuilder
    private var menu: some View {
        Menu {
            ForEach(Self.reactionChoices, id: \.self) { e in
                Button(e) { actions.react(message, e) }
            }
        } label: {
            Label("回应", systemImage: "face.smiling")
        }
        Button { actions.reply(message) } label: { Label("回复", systemImage: "arrowshape.turn.up.left") }
        Button { UIPasteboard.general.string = message.text } label: { Label("拷贝", systemImage: "doc.on.doc") }
        Button { Speaker.shared.speak(message.text) } label: { Label("朗读", systemImage: "speaker.wave.2") }
        ShareLink(item: message.text) { Label("分享", systemImage: "square.and.arrow.up") }
        if message.role == .assistant {
            Button { actions.regenerate(message) } label: { Label("重新生成", systemImage: "arrow.clockwise") }
        }
        if message.role == .user {
            Button { actions.edit(message) } label: { Label("编辑并重发", systemImage: "pencil") }
        }
        Divider()
        Button(role: .destructive) { actions.delete(message) } label: { Label("删除", systemImage: "trash") }
    }
}

// MARK: - 子组件

struct ReplyQuote: View {
    let text: String
    let isUser: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrowshape.turn.up.left.fill").font(.caption2)
            Text(text.plainPreview).lineLimit(2)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.secondary.opacity(0.35), lineWidth: 1))
        .frame(maxWidth: 260, alignment: isUser ? .trailing : .leading)
    }
}

struct ReasoningView: View {
    let text: String
    let active: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    if active {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "brain")
                    }
                    Text(active ? "思考中…" : "思考过程")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemFill)))
            }
        }
        .padding(.leading, 4)
    }
}

struct ToolChip: View {
    let call: ToolCallRecord
    let onTap: () -> Void

    private var label: String {
        let title = call.summary ?? ToolRegistry.title(for: call.name)
        switch call.state {
        case .running: return title + "…"
        case .pending: return title
        default: return title
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if call.state == .running {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: ToolRegistry.icon(for: call.name))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.iMessageBlue)
                }
                Text(label)
                    .font(.footnote)
                    .lineLimit(1)
                    .foregroundStyle(Color.primary.opacity(0.8))
                statusIcon
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(.tertiarySystemFill)))
        }
        .buttonStyle(.plain)
        .padding(.leading, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch call.state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
        case .denied: Image(systemName: "hand.raised.fill").foregroundStyle(.secondary).font(.caption)
        case .cancelled: Image(systemName: "slash.circle").foregroundStyle(.secondary).font(.caption)
        case .pending: Image(systemName: "clock").foregroundStyle(.secondary).font(.caption)
        default: EmptyView()
        }
    }
}

struct ApprovalCard: View {
    let call: ToolCallRecord
    let onDecision: (ApprovalDecision) -> Void

    private var prettyArgs: String {
        JSONValue.parse(call.arguments)?.jsonString(pretty: true) ?? call.arguments
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: ToolRegistry.icon(for: call.name))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange))
                VStack(alignment: .leading, spacing: 1) {
                    Text("需要你的批准").font(.subheadline.weight(.semibold))
                    Text(ToolRegistry.title(for: call.name)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let summary = call.summary {
                Text(summary).font(.callout)
            }
            ScrollView {
                Text(prettyArgs)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.tertiarySystemFill)))
            HStack(spacing: 8) {
                Button(role: .destructive) { onDecision(.deny) } label: { Text("拒绝").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                Button { onDecision(.always) } label: { Text("始终允许").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                Button { onDecision(.once) } label: { Text("允许").bold().frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: 320)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.agentBubble))
        .padding(.leading, 2)
    }
}

struct AttachmentBubble: View {
    @EnvironmentObject private var store: AppStore
    let attachment: Attachment
    let isUser: Bool
    let onOpen: (Attachment) -> Void

    private var fileIcon: String {
        let ext = (attachment.fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext.fill"
        case "md", "txt": return "doc.text.fill"
        case "csv", "xlsx", "numbers": return "tablecells.fill"
        case "html", "json", "js", "swift", "py": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.fill"
        }
    }

    private var sizeText: String {
        let size = (try? store.url(for: attachment).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var body: some View {
        if attachment.kind == .image, let image = store.image(for: attachment) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 230, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onTapGesture { onOpen(attachment) }
                .contextMenu {
                    ShareLink(item: store.url(for: attachment)) { Label("分享", systemImage: "square.and.arrow.up") }
                    Button { UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil) } label: {
                        Label("存储到相册", systemImage: "square.and.arrow.down")
                    }
                }
        } else {
            ShareLink(item: store.url(for: attachment)) {
                HStack(spacing: 10) {
                    Image(systemName: fileIcon)
                        .font(.title2)
                        .foregroundStyle(Color.iMessageBlue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.fileName).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(sizeText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "square.and.arrow.up").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(width: 240)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.agentBubble))
            }
            .buttonStyle(.plain)
        }
    }
}

struct ToolInspectorView: View {
    let call: ToolCallRecord
    let result: ChatMessage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("工具", value: ToolRegistry.title(for: call.name))
                    LabeledContent("状态") {
                        Text(call.state.title).foregroundStyle(call.state.color)
                    }
                    if let s = call.summary { Text(s) }
                }
                Section("参数") {
                    Text(JSONValue.parse(call.arguments)?.jsonString(pretty: true) ?? call.arguments)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let result {
                    Section("结果") {
                        Text(result.text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(ToolRegistry.title(for: call.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ImageViewer: View {
    let attachment: Attachment
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = store.image(for: attachment) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { scale = max(1, $0) }
                                .onEnded { _ in withAnimation(.spring) { scale = 1 } }
                        )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: store.url(for: attachment)) { Image(systemName: "square.and.arrow.up") }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}
