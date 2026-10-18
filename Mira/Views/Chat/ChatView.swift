import SwiftUI

struct ChatView: View {
    let conversationID: UUID

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: AgentEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var input = ""
    @State private var pending: [Attachment] = []
    @State private var replyTo: ChatMessage?
    @State private var editingAgent: AgentProfile?
    @State private var inspecting: ToolCallRecord?
    @State private var viewing: Attachment?
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmClear = false
    @State private var followsLatest = true
    @State private var isNearBottom = true
    @State private var viewportHeight: CGFloat = 0
    @State private var scrollRequest = 0
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let conv = store.conversation(conversationID) {
                chat(conv)
            } else {
                ContentUnavailableView("对话已删除", systemImage: "bubble.left.and.exclamationmark.bubble.right")
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            store.activeConversationID = conversationID
            store.markRead(conversationID)
            if input.isEmpty { input = store.conversation(conversationID)?.draft ?? "" }
        }
        .onDisappear {
            if store.activeConversationID == conversationID { store.activeConversationID = nil }
            store.setDraft(input, for: conversationID)
        }
    }

    @ViewBuilder
    private func chat(_ conv: Conversation) -> some View {
        let agent = store.agent(for: conv.agentID)
        let running = engine.isRunning(conv.id)
        let rows = ChatRowModel.build(conv.messages, running: running)
        let acts = actions()

        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVStack(spacing: 2) {
                        if rows.isEmpty { emptyHeader(agent) }
                        ForEach(rows) { row in
                            MessageRowView(row: row,
                                           replied: row.message.replyToID.flatMap { rid in conv.messages.first { $0.id == rid } },
                                           actions: acts)
                                .id(row.id)
                        }
                    }
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    Color.clear.frame(height: 1)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: ChatBottomKey.self,
                                    value: geometry.frame(in: .named("chatScroll")).maxY)
                            }
                        }
                        .id("bottom")
                }
            }
            .coordinateSpace(name: "chatScroll")
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ChatViewportKey.self, value: geometry.size.height)
                }
            }
            .onPreferenceChange(ChatViewportKey.self) { viewportHeight = $0 }
            .onPreferenceChange(ChatBottomKey.self) { bottom in
                isNearBottom = bottom <= viewportHeight + 80
                if isNearBottom { followsLatest = true }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 12)
                .onChanged { value in
                    // Stop following as soon as the reader drags toward older messages.
                    if value.translation.height > 8 { followsLatest = false }
                }
                .onEnded { _ in followsLatest = isNearBottom })
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: scrollKey(conv)) { _, _ in
                guard followsLatest else { return }
                // Do not start a new spring for every token of a streaming response.
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: scrollRequest) { _, _ in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: focused) { _, isFocused in
                guard isFocused, followsLatest else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard followsLatest else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest && !isNearBottom {
                    Button {
                        followsLatest = true
                        scrollRequest += 1
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glass(Circle(), interactive: true)
                    .padding(16)
                    .accessibilityLabel("回到最新消息")
                }
            }
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            InputBar(text: $input, attachments: $pending, replyTo: $replyTo, focus: $focused,
                     isRunning: running, onSend: send, onStop: { engine.stop(conversationID) })
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { editingAgent = agent } label: {
                    HStack(spacing: 8) {
                        AgentAvatar(agent: agent, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 2) {
                                Text(agent.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.primary)
                            if running {
                                Text("正在处理…").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看 \(agent.name) 的资料")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { newTitle = conv.title; renaming = true } label: { Label("重命名", systemImage: "pencil") }
                    Menu {
                        ForEach(store.agents) { a in
                            Button { store.setAgent(a.id, for: conversationID) } label: { Text("\(a.emoji) \(a.name)") }
                        }
                    } label: { Label("切换智能体", systemImage: "person.2") }
                    Button { store.togglePin(conversationID) } label: {
                        Label(conv.pinned ? "取消置顶" : "置顶", systemImage: conv.pinned ? "pin.slash" : "pin")
                    }
                    Button { store.toggleMute(conversationID) } label: {
                        Label(conv.muted ? "取消静音" : "静音通知", systemImage: conv.muted ? "bell" : "bell.slash")
                    }
                    ShareLink(item: store.transcript(conversationID)) { Label("导出文字记录", systemImage: "square.and.arrow.up") }
                    Divider()
                    Button(role: .destructive) { confirmClear = true } label: { Label("清空对话", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("对话选项")
            }
        }
        .sheet(item: $editingAgent) { a in
            NavigationStack { AgentEditorView(agent: a) }
        }
        .sheet(item: $inspecting) { call in
            ToolInspectorView(call: call, result: conv.messages.first { $0.toolCallID == call.id })
        }
        .fullScreenCover(item: $viewing) { att in
            ImageViewer(attachment: att)
        }
        .alert("重命名对话", isPresented: $renaming) {
            TextField("标题", text: $newTitle)
            Button("取消", role: .cancel) {}
            Button("保存") { store.rename(conversationID, newTitle) }
        }
        .confirmationDialog("清空这个对话的所有消息？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                engine.stop(conversationID)
                store.clearMessages(conversationID)
            }
        }
    }

    private func emptyHeader(_ agent: AgentProfile) -> some View {
        VStack(spacing: 10) {
            AgentAvatar(agent: agent, size: 72)
            Text(agent.name).font(.title3.weight(.semibold))
            Text("发一条信息，让\(agent.name)帮你把事情办好。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 30)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    suggestion("帮我安排今天")
                    suggestion("你能帮我做什么？")
                }
                VStack(spacing: 10) {
                    suggestion("帮我安排今天")
                    suggestion("你能帮我做什么？")
                }
            }
            .padding(.top, 14)
        }
        .padding(.top, 40)
        .padding(.bottom, 20)
    }

    private func suggestion(_ text: String) -> some View {
        Button {
            input = text
            focused = true
        } label: {
            Text(text).font(.subheadline)
                .padding(.horizontal, 16).frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.iMessageBlue)
        .glass(Capsule(), interactive: true)
    }

    private func scrollKey(_ conv: Conversation) -> String {
        guard let last = conv.messages.last else { return "empty" }
        let states = last.toolCalls.map { "\($0.id):\($0.state.rawValue)" }.joined(separator: ",")
        return "\(last.id):\(conv.messages.count):\(last.text.count):\(last.reasoning.count):\(last.attachments.count):\(last.isStreaming):\(states)"
    }

    // MARK: 动作

    private func send() {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty || !pending.isEmpty, !engine.isRunning(conversationID) else { return }
        let text = ShortcutExpander.expand(raw, shortcuts: store.shortcuts)
        followsLatest = true
        engine.send(text: text, attachments: pending, conversationID: conversationID, replyTo: replyTo?.id)
        scrollRequest += 1
        input = ""
        pending = []
        replyTo = nil
        store.setDraft("", for: conversationID)
        Haptics.tap()
    }

    private func actions() -> ChatActions {
        let id = conversationID
        return ChatActions(
            react: { m, emoji in
                store.react(emoji, to: m.id, in: id)
                Haptics.tap()
            },
            reply: { m in
                replyTo = m
                focused = true
            },
            regenerate: { m in
                guard !engine.isRunning(id), let conv = store.conversation(id),
                      let idx = conv.messages.firstIndex(where: { $0.id == m.id }),
                      let userIdx = conv.messages[..<idx].lastIndex(where: { $0.role == .user }) else { return }
                store.truncate(id, from: userIdx + 1)
                engine.start(id)
            },
            edit: { m in
                guard !engine.isRunning(id), let conv = store.conversation(id),
                      let idx = conv.messages.firstIndex(where: { $0.id == m.id }) else { return }
                input = m.text
                pending = m.attachments
                store.truncate(id, from: idx)
                focused = true
            },
            delete: { m in
                store.deleteMessage(m.id, in: id)
            },
            approve: { call, decision in
                engine.resolveApproval(call.id, decision)
                Haptics.tap()
            },
            inspect: { call in
                inspecting = call
            },
            openImage: { att in
                viewing = att
            },
            retry: {
                guard !engine.isRunning(id), let conv = store.conversation(id) else { return }
                if let last = conv.messages.last, last.role == .event, last.isError {
                    store.deleteMessage(last.id, in: id)
                }
                engine.start(id)
            }
        )
    }
}

private struct ChatBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ChatViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
