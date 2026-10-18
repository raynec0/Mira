import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published var conversations: [Conversation] = [] { didSet { scheduleSave() } }
    @Published var agents: [AgentProfile] = [] { didSet { scheduleSave() } }
    @Published var tasks: [AgentTaskItem] = [] { didSet { scheduleSave() } }
    @Published var routines: [Routine] = [] { didSet { scheduleSave() } }
    @Published var memories: [MemoryItem] = [] { didSet { scheduleSave() } }
    @Published var audit: [AuditEntry] = [] { didSet { scheduleSave() } }
    @Published var connectors: [Connector] = [] { didSet { scheduleSave() } }
    @Published var shortcuts: [PromptShortcut] = [] { didSet { scheduleSave() } }
    @Published var settings = AppSettings() { didSet { scheduleSave() } }

    @Published var selectedTab: AppTab = .messages
    @Published var openConversationRequest: UUID?
    var activeConversationID: UUID?
    var isForeground = true

    let supportDir: URL
    let attachmentsDir: URL
    let filesDir: URL

    private var isLoaded = false
    private var saveTask: Task<Void, Never>?
    private let imageCache = NSCache<NSString, UIImage>()
    private let ioQueue = DispatchQueue(label: "com.raynec.mira.io")
    private var stateURL: URL { supportDir.appendingPathComponent("state.json") }

    struct Snapshot: Codable {
        var conversations: [Conversation]
        var agents: [AgentProfile]
        var tasks: [AgentTaskItem]
        var routines: [Routine]
        var memories: [MemoryItem]
        var audit: [AuditEntry]
        var connectors: [Connector]
        var shortcuts: [PromptShortcut]
        var settings: AppSettings
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mira", isDirectory: true)
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        supportDir = support
        attachmentsDir = support.appendingPathComponent("Attachments", isDirectory: true)
        filesDir = docs.appendingPathComponent("Mira 文件", isDirectory: true)
        for dir in [support, attachmentsDir, filesDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        load()
        if agents.isEmpty { seedDefaults() }
        isLoaded = true
        saveNow()
    }

    // MARK: 持久化

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let snap = try? Self.decoder.decode(Snapshot.self, from: data) else { return }
        apply(snap)
        sanitize()
    }

    private func apply(_ s: Snapshot) {
        conversations = s.conversations
        agents = s.agents
        tasks = s.tasks
        routines = s.routines
        memories = s.memories
        audit = s.audit
        connectors = s.connectors
        shortcuts = s.shortcuts
        settings = s.settings
    }

    /// App 被杀掉时可能遗留“进行中”状态，启动时统一收尾。
    private func sanitize() {
        for i in conversations.indices {
            for j in conversations[i].messages.indices {
                conversations[i].messages[j].isStreaming = false
                for k in conversations[i].messages[j].toolCalls.indices {
                    let state = conversations[i].messages[j].toolCalls[k].state
                    if state == .pending || state == .running || state == .awaitingApproval {
                        conversations[i].messages[j].toolCalls[k].state = .cancelled
                    }
                }
            }
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(conversations: conversations, agents: agents, tasks: tasks, routines: routines,
                 memories: memories, audit: audit, connectors: connectors, shortcuts: shortcuts, settings: settings)
    }

    func scheduleSave() {
        guard isLoaded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let data = try? Self.encoder.encode(snapshot()) else { return }
        let url = stateURL
        ioQueue.async { try? data.write(to: url, options: .atomic) }
    }

    func exportBackup() -> URL? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(snapshot()) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mira备份-\(RelativeTime.fmt("yyyyMMdd-HHmm", Date())).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    func importBackup(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let snap = try Self.decoder.decode(Snapshot.self, from: data)
        apply(snap)
        sanitize()
        if agents.isEmpty { seedDefaults() }
        saveNow()
    }

    // MARK: 对话

    func index(of id: UUID) -> Int? { conversations.firstIndex { $0.id == id } }

    func conversation(_ id: UUID) -> Conversation? { conversations.first { $0.id == id } }

    func agent(for id: UUID) -> AgentProfile {
        agents.first { $0.id == id } ?? agents.first ?? AgentProfile.blank
    }

    @discardableResult
    func newConversation(agentID: UUID, title: String = "") -> UUID {
        let conv = Conversation(agentID: agentID, title: title)
        conversations.insert(conv, at: 0)
        return conv.id
    }

    func append(_ message: ChatMessage, to convID: UUID) {
        guard let i = index(of: convID) else { return }
        conversations[i].messages.append(message)
        conversations[i].updatedAt = Date()
    }

    func updateMessage(_ msgID: UUID, in convID: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let i = index(of: convID),
              let j = conversations[i].messages.firstIndex(where: { $0.id == msgID }) else { return }
        change(&conversations[i].messages[j])
    }

    func updateToolCall(_ callID: String, messageID: UUID, convID: UUID, state: ToolCallState, summary: String?) {
        updateMessage(messageID, in: convID) { m in
            if let k = m.toolCalls.firstIndex(where: { $0.id == callID }) {
                m.toolCalls[k].state = state
                if let summary { m.toolCalls[k].summary = summary }
            }
        }
    }

    func deleteMessage(_ msgID: UUID, in convID: UUID) {
        guard let i = index(of: convID) else { return }
        guard let msg = conversations[i].messages.first(where: { $0.id == msgID }) else { return }
        var removeIDs: Set<UUID> = [msgID]
        // 删除助手消息时一并删除其工具结果，保证上下文成对。
        if msg.role == .assistant {
            let callIDs = Set(msg.toolCalls.map { $0.id })
            for m in conversations[i].messages where m.role == .tool {
                if let cid = m.toolCallID, callIDs.contains(cid) { removeIDs.insert(m.id) }
            }
        }
        conversations[i].messages.removeAll { removeIDs.contains($0.id) }
    }

    /// 删除从 index 开始的所有消息。
    func truncate(_ convID: UUID, from index: Int) {
        guard let i = self.index(of: convID), index < conversations[i].messages.count else { return }
        conversations[i].messages.removeSubrange(max(0, index)...)
    }

    func deleteConversation(_ id: UUID) {
        if let conv = conversation(id) {
            for m in conv.messages {
                for a in m.attachments { try? FileManager.default.removeItem(at: url(for: a)) }
            }
        }
        conversations.removeAll { $0.id == id }
    }

    func clearMessages(_ id: UUID) {
        guard let i = index(of: id) else { return }
        conversations[i].messages.removeAll()
    }

    func togglePin(_ id: UUID) { if let i = index(of: id) { conversations[i].pinned.toggle() } }
    func toggleMute(_ id: UUID) { if let i = index(of: id) { conversations[i].muted.toggle() } }
    func toggleUnread(_ id: UUID) { if let i = index(of: id) { conversations[i].unread.toggle() } }

    func markRead(_ id: UUID) {
        if let i = index(of: id), conversations[i].unread { conversations[i].unread = false }
    }

    func markAllRead() {
        for i in conversations.indices where conversations[i].unread { conversations[i].unread = false }
    }

    func rename(_ id: UUID, _ title: String) {
        if let i = index(of: id) { conversations[i].title = title.trimmingCharacters(in: .whitespaces) }
    }

    func setDraft(_ draft: String, for id: UUID) {
        if let i = index(of: id), conversations[i].draft != draft { conversations[i].draft = draft }
    }

    func setAgent(_ agentID: UUID, for convID: UUID) {
        if let i = index(of: convID) { conversations[i].agentID = agentID }
    }

    func react(_ emoji: String, to msgID: UUID, in convID: UUID) {
        updateMessage(msgID, in: convID) { m in
            if m.reactions.contains(emoji) { m.reactions.removeAll { $0 == emoji } } else { m.reactions = [emoji] }
        }
    }

    var unreadCount: Int { conversations.filter { $0.unread }.count }

    func transcript(_ id: UUID) -> String {
        guard let conv = conversation(id) else { return "" }
        let agent = self.agent(for: conv.agentID)
        var lines: [String] = ["# \(conv.title.isEmpty ? agent.name : conv.title)", ""]
        for m in conv.messages {
            switch m.role {
            case .user: lines.append("【我 \(RelativeTime.fmt("MM-dd HH:mm", m.createdAt))】\n\(m.text)\n")
            case .assistant where !m.text.isEmpty: lines.append("【\(agent.name) \(RelativeTime.fmt("MM-dd HH:mm", m.createdAt))】\n\(m.text)\n")
            case .event: lines.append("— \(m.text) —\n")
            default: break
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 智能体

    func upsertAgent(_ agent: AgentProfile) {
        if let i = agents.firstIndex(where: { $0.id == agent.id }) { agents[i] = agent } else { agents.append(agent) }
    }

    func deleteAgent(_ id: UUID) {
        guard agents.count > 1 else { return }
        agents.removeAll { $0.id == id }
        let fallback = agents[0].id
        for i in conversations.indices where conversations[i].agentID == id { conversations[i].agentID = fallback }
        for i in routines.indices where routines[i].agentID == id { routines[i].agentID = fallback }
    }

    // MARK: 任务 / 例程 / 审计

    func setTaskStatus(_ id: UUID, _ status: TaskStatus) {
        if let i = tasks.firstIndex(where: { $0.id == id }) {
            tasks[i].status = status
            tasks[i].updatedAt = Date()
        }
    }

    func deleteTask(_ id: UUID) { tasks.removeAll { $0.id == id } }

    func upsertRoutine(_ r: Routine) {
        if let i = routines.firstIndex(where: { $0.id == r.id }) { routines[i] = r } else { routines.append(r) }
    }

    func addAudit(_ entry: AuditEntry) {
        audit.insert(entry, at: 0)
        if audit.count > 600 { audit.removeLast(audit.count - 600) }
    }

    func permission(for toolName: String, risk: ToolRisk) -> ToolPermission {
        if let p = settings.toolPermissions[toolName] { return p }
        return risk == .safe ? .auto : .ask
    }

    // MARK: 附件

    func storeAttachment(data: Data, fileName: String, mime: String, kind: AttachmentKind) -> Attachment? {
        let ext = (fileName as NSString).pathExtension
        let stored = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        do {
            try data.write(to: attachmentsDir.appendingPathComponent(stored), options: .atomic)
            return Attachment(kind: kind, fileName: fileName, mimeType: mime, storedName: stored)
        } catch {
            return nil
        }
    }

    func url(for attachment: Attachment) -> URL {
        attachmentsDir.appendingPathComponent(attachment.storedName)
    }

    func image(for attachment: Attachment) -> UIImage? {
        let key = attachment.storedName as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let img = UIImage(contentsOfFile: url(for: attachment).path) else { return nil }
        imageCache.setObject(img, forKey: key)
        return img
    }

    // MARK: 模型配置

    func modelConfig(for agent: AgentProfile) throws -> ModelConfig {
        let provider = agent.provider ?? settings.defaultProvider
        switch provider {
        case .openai:
            let model = (agent.model?.isEmpty == false ? agent.model! : settings.openAIModel)
            guard !settings.openAIBaseURL.isEmpty, !model.isEmpty else {
                throw LLMError("请先在「设置 › 模型服务」中填写 OpenAI 兼容接口的地址和模型。")
            }
            return ModelConfig(provider: .openai, baseURL: settings.openAIBaseURL, apiKey: Keychain.get(KeyName.openAI),
                               model: model, temperature: agent.temperature, maxTokens: settings.anthropicMaxTokens)
        case .anthropic:
            let key = Keychain.get(KeyName.anthropic)
            guard !key.isEmpty else { throw LLMError("请先在「设置 › 模型服务」中填写 Anthropic API Key。") }
            let model = (agent.model?.isEmpty == false ? agent.model! : settings.anthropicModel)
            return ModelConfig(provider: .anthropic, baseURL: settings.anthropicBaseURL, apiKey: key,
                               model: model, temperature: agent.temperature, maxTokens: settings.anthropicMaxTokens)
        }
    }

    // MARK: 默认数据

    private func seedDefaults() {
        let mira = AgentProfile(
            name: "Mira", emoji: "✨", colorHex: "5E5CE6",
            systemPrompt: """
            你是 Mira，用户的私人 AI 智能体。你不只是聊天——你会用工具真正把事情办完：搜索和阅读网页、查天气、管理日历和提醒事项、起草并发送邮件和短信、记住用户的偏好、把复杂目标拆成任务并持续推进、创建文档和图片、运行代码、调用用户接入的 API。
            风格：像发 iMessage 一样自然、简洁、温暖；先给结论，必要时再展开。用用户使用的语言回复。
            """)
        let researcher = AgentProfile(
            name: "研究员", emoji: "🔎", colorHex: "0A84FF",
            systemPrompt: """
            你是一名严谨的研究员。面对问题时，先拆解成若干子问题，多次使用 web_search 与 fetch_url 交叉核实信息，优先采用一手来源（官网、论文、政府网站）。最后给出结构清晰的结论，并在末尾列出来源链接。不确定的地方要明确说明。
            """)
        let planner = AgentProfile(
            name: "日程管家", emoji: "📅", colorHex: "FF9F0A",
            systemPrompt: """
            你是用户的日程管家，擅长管理日历、提醒事项、任务和例程。安排时间前先查看已有日程避免冲突；创建日程时确认时间、地点；把长期目标拆成可执行的步骤并用任务跟踪；对需要每天/每周做的事建议建立例程。
            """)
        let writer = AgentProfile(
            name: "写作助手", emoji: "✍️", colorHex: "FF375F",
            systemPrompt: """
            你是专业的中英双语写作与翻译助手，擅长技术文档、商务邮件、报告和润色。翻译时保留术语准确性与原文语气；润色时说明主要改动。需要时可用 create_document 生成可分享的文档。
            """)
        let coder = AgentProfile(
            name: "代码助手", emoji: "💻", colorHex: "30D158",
            systemPrompt: """
            你是一名资深工程师。回答编程问题时给出可运行的代码；需要计算、数据处理或验证逻辑时，使用 run_javascript 实际运行代码并根据结果作答。
            """)
        agents = [mira, researcher, planner, writer, coder]

        shortcuts = [
            PromptShortcut(name: "翻译", prompt: "把下面的内容翻译成英文（如果原文是英文就翻译成中文），保持语气和专业术语准确：\n{{input}}"),
            PromptShortcut(name: "润色", prompt: "润色下面这段文字，让它更清晰、专业，并简要说明主要修改：\n{{input}}"),
            PromptShortcut(name: "总结", prompt: "用要点总结下面的内容：\n{{input}}"),
            PromptShortcut(name: "早报", prompt: "给我今天的早间简报：当地天气、今天的日程、未完成的提醒事项和进行中的任务，最后给一句今日建议。"),
            PromptShortcut(name: "研究", prompt: "深入研究这个主题，多方搜索并交叉核实，给出结论与来源：\n{{input}}")
        ]

        routines = [
            Routine(title: "早间简报", prompt: "给我今天的早间简报：当地天气、今天的日程、未完成的提醒事项和进行中的任务，最后给一句今日建议。",
                    agentID: mira.id, hour: 7, minute: 30, weekdays: [1, 2, 3, 4, 5], enabled: false)
        ]

        var welcome = Conversation(agentID: mira.id)
        welcome.messages = [
            ChatMessage(role: .assistant, text: """
            嗨，我是 **Mira** ✨ 你的私人 AI 智能体。

            我能帮你：
            - 🔎 搜索、阅读网页并整理结论
            - 📅 查看/创建日程和提醒事项
            - ✉️ 起草并发送邮件、短信（发送前会请你批准）
            - 🧠 记住你的偏好，越用越懂你
            - ✅ 把大目标拆成任务，持续推进
            - ⏰ 定时例程，比如每天早上的简报
            - 📄 生成文档、图片，运行代码，调用你接入的 API

            先去「设置 › 模型服务」填好 API Key，然后直接跟我说要做什么吧。
            """)
        ]
        welcome.pinned = true
        conversations = [welcome]
    }
}
