import Foundation

enum ToolRisk {
    /// 只读或无副作用：默认自动执行
    case safe
    /// 会改变数据：默认需要批准
    case action
    /// 涉及隐私或对外发送：默认需要批准
    case sensitive
}

struct ToolContext {
    let conversationID: UUID
    let agent: AgentProfile
    let store: AppStore
}

struct ToolOutput {
    var text: String
    var attachments: [Attachment] = []
    var isError = false
}

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
protocol AgentTool {
    var name: String { get }
    var title: String { get }
    var icon: String { get }
    var description: String { get }
    var schema: JSONValue { get }
    var defaultRisk: ToolRisk { get }
    var isAvailable: Bool { get }
    func risk(for args: JSONValue) -> ToolRisk
    func summary(for args: JSONValue) -> String
    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput
}

extension AgentTool {
    var isAvailable: Bool { true }
    func risk(for args: JSONValue) -> ToolRisk { defaultRisk }
    func summary(for args: JSONValue) -> String { title }
}

struct ToolInfo: Identifiable {
    let name: String
    let title: String
    let icon: String
    let defaultPermission: ToolPermission
    var id: String { name }
}

@MainActor
enum ToolRegistry {
    static let all: [any AgentTool] = [
        // 信息
        WebSearchTool(), FetchURLTool(), DateTimeTool(), WeatherTool(), LocationTool(),
        // 日历 / 提醒 / 通讯录
        CalendarListTool(), CalendarCreateTool(), CalendarDeleteTool(),
        RemindersListTool(), RemindersCreateTool(), RemindersCompleteTool(),
        ContactsSearchTool(),
        // 通信与系统
        SendEmailTool(), SendMessageTool(), NotificationTool(), ClipboardReadTool(), ClipboardWriteTool(), OpenURLTool(),
        // 记忆 / 任务 / 例程
        RememberTool(), RecallMemoryTool(), ForgetMemoryTool(),
        CreateTaskTool(), UpdateTaskTool(), ListTasksTool(), CreateRoutineTool(),
        // 创作与计算
        RunJavaScriptTool(), CreateDocumentTool(), ListDocumentsTool(), ReadDocumentTool(), GenerateImageTool(),
        // 连接器
        ConnectorTool()
    ]

    static func tool(named name: String) -> (any AgentTool)? {
        all.first { $0.name == name }
    }

    static func title(for name: String) -> String {
        tool(named: name)?.title ?? name
    }

    static func icon(for name: String) -> String {
        tool(named: name)?.icon ?? "wrench.and.screwdriver"
    }

    static var infos: [ToolInfo] {
        all.map { ToolInfo(name: $0.name, title: $0.title, icon: $0.icon,
                           defaultPermission: $0.defaultRisk == .safe ? .auto : .ask) }
    }

    static func specs(for agent: AgentProfile) -> [ToolSpec] {
        let store = AppStore.shared
        return all.filter { tool in
            if agent.disabledTools.contains(tool.name) { return false }
            if store.settings.toolPermissions[tool.name] == .off { return false }
            return tool.isAvailable
        }
        .map { ToolSpec(name: $0.name, description: $0.description, schema: $0.schema) }
    }
}
