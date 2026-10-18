import SwiftUI

struct ConversationListView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: AgentEngine
    @State private var path: [UUID] = []
    @State private var search = ""
    @State private var showNew = false
    @State private var unreadOnly = false
    @State private var editingAgent: AgentProfile?

    private var sorted: [Conversation] {
        store.conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var pinned: [Conversation] { sorted.filter { $0.pinned } }

    private var listed: [Conversation] {
        sorted.filter { conv in
            if unreadOnly && !conv.unread { return false }
            if !search.isEmpty { return matches(conv) }
            if unreadOnly { return conv.unread }
            return !conv.pinned
        }
    }

    private func matches(_ conv: Conversation) -> Bool {
        let q = search.lowercased()
        let name = store.agent(for: conv.agentID).name.lowercased()
        return conv.title.lowercased().contains(q) || name.contains(q)
            || conv.messages.contains { $0.text.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if search.isEmpty && !unreadOnly && !pinned.isEmpty {
                    PinnedGrid(conversations: pinned) { id in path.append(id) }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 10, trailing: 14))
                }
                ForEach(listed) { conv in
                    NavigationLink(value: conv.id) {
                        ConversationRow(conversation: conv)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { store.toggleUnread(conv.id) } label: {
                            Label(conv.unread ? "已读" : "未读", systemImage: conv.unread ? "message" : "message.badge")
                        }
                        .tint(.blue)
                        Button { store.togglePin(conv.id) } label: {
                            Label(conv.pinned ? "取消置顶" : "置顶", systemImage: conv.pinned ? "pin.slash.fill" : "pin.fill")
                        }
                        .tint(.yellow)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            engine.stop(conv.id)
                            store.deleteConversation(conv.id)
                        } label: {
                            Label("删除", systemImage: "trash.fill")
                        }
                        Button { store.toggleMute(conv.id) } label: {
                            Label(conv.muted ? "提醒" : "静音", systemImage: conv.muted ? "bell.fill" : "bell.slash.fill")
                        }
                        .tint(.indigo)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if store.conversations.isEmpty {
                    ContentUnavailableView("没有对话", systemImage: "message",
                                           description: Text("点右上角，开始和智能体聊天"))
                } else if !search.isEmpty && listed.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else if unreadOnly && listed.isEmpty {
                    ContentUnavailableView("没有未读信息", systemImage: "checkmark.message",
                                           description: Text("所有对话都已读完"))
                }
            }
            .navigationTitle(unreadOnly ? "未读信息" : "信息")
            .searchable(text: $search, prompt: "搜索")
            .navigationDestination(for: UUID.self) { id in
                ChatView(conversationID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle(isOn: $unreadOnly) { Label("仅显示未读", systemImage: "message.badge") }
                        Button { store.markAllRead() } label: { Label("全部标为已读", systemImage: "checkmark.message") }
                        Section("智能体") {
                            ForEach(store.agents) { a in
                                Button { editingAgent = a } label: { Text("\(a.emoji) \(a.name)") }
                            }
                            Button { editingAgent = AgentProfile.blank } label: { Label("新建智能体", systemImage: "plus") }
                        }
                    } label: {
                        Image(systemName: unreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel("筛选信息")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("新建对话")
                }
            }
            .sheet(isPresented: $showNew) {
                NewChatSheet { agentID in
                    showNew = false
                    let id = store.newConversation(agentID: agentID)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { path.append(id) }
                }
            }
            .sheet(item: $editingAgent) { a in
                NavigationStack { AgentEditorView(agent: a) }
            }
            .onChange(of: store.openConversationRequest) { _, id in openRequested(id) }
            .onAppear { openRequested(store.openConversationRequest) }
        }
    }

    private func openRequested(_ id: UUID?) {
        guard let id, store.conversation(id) != nil else { return }
        store.openConversationRequest = nil
        if path.last != id { path = [id] }
    }
}

struct PinnedGrid: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: AgentEngine
    let conversations: [Conversation]
    let open: (UUID) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 14) {
            ForEach(conversations) { conv in
                let agent = store.agent(for: conv.agentID)
                Button { open(conv.id) } label: {
                    VStack(spacing: 6) {
                        AgentAvatar(agent: agent, size: 72)
                            .overlay(alignment: .topLeading) {
                                if conv.unread {
                                    Circle().fill(Color.iMessageBlue).frame(width: 14, height: 14)
                                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                                }
                            }
                            .overlay(alignment: .bottomTrailing) {
                                if engine.isRunning(conv.id) {
                                    ProgressView().controlSize(.small)
                                        .padding(4)
                                        .background(Circle().fill(Color(.systemBackground)))
                                }
                            }
                        Text(conv.title.isEmpty ? agent.name : conv.title)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { store.togglePin(conv.id) } label: { Label("取消置顶", systemImage: "pin.slash") }
                    Button(role: .destructive) {
                        engine.stop(conv.id)
                        store.deleteConversation(conv.id)
                    } label: { Label("删除", systemImage: "trash") }
                }
            }
        }
    }
}

struct ConversationRow: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: AgentEngine
    let conversation: Conversation

    private var preview: String {
        guard let last = conversation.messages.last(where: { $0.role != .tool || !$0.attachments.isEmpty }) else {
            return "暂无消息"
        }
        switch last.role {
        case .tool: return last.attachments.first?.kind == .image ? "图片" : "文件"
        case .event: return last.text
        case .assistant where last.text.isEmpty:
            if let call = last.toolCalls.last {
                return call.state == .awaitingApproval ? "⚠️ 等待你的批准" : "🔧 \(call.summary ?? ToolRegistry.title(for: call.name))"
            }
            return "…"
        default:
            if last.text.isEmpty, let a = last.attachments.first { return a.kind == .image ? "图片" : a.fileName }
            return last.text.plainPreview
        }
    }

    var body: some View {
        let agent = store.agent(for: conversation.agentID)
        HStack(spacing: 10) {
            Circle()
                .fill(conversation.unread ? Color.iMessageBlue : Color.clear)
                .frame(width: 10, height: 10)
            AgentAvatar(agent: agent, size: 54)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(conversation.title.isEmpty ? agent.name : conversation.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if conversation.muted {
                        Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(RelativeTime.listString(conversation.updatedAt))
                        .font(.subheadline)
                        .foregroundStyle(conversation.unread ? Color.iMessageBlue : Color.secondary)
                }
                Group {
                    if !conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("草稿：").foregroundColor(.red) + Text(conversation.draft)
                    } else if engine.isRunning(conversation.id) {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text(engine.pendingApprovals > 0 && preview.contains("批准") ? "等待你的批准" : "\(agent.name) 正在处理…")
                        }
                    } else {
                        Text(preview)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, -8)
    }
}

struct NewChatSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let onPick: (UUID) -> Void
    @State private var creating: AgentProfile?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.agents) { a in
                        Button { onPick(a.id) } label: {
                            HStack(spacing: 12) {
                                AgentAvatar(agent: a, size: 42)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.name).foregroundStyle(.primary)
                                    Text(a.systemPrompt.plainPreview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                } header: {
                    Text("收件人")
                }
                Section {
                    Button { creating = AgentProfile.blank } label: {
                        Label("新建智能体", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
            .navigationTitle("新信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .sheet(item: $creating) { a in
                NavigationStack { AgentEditorView(agent: a) }
            }
        }
    }
}
