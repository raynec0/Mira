import Foundation
import SwiftUI

// MARK: - 服务商

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case openai, anthropic
    var id: String { rawValue }
    var title: String { self == .openai ? "OpenAI 兼容" : "Anthropic Claude" }
}

// MARK: - 智能体

struct AgentProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var emoji: String
    var colorHex: String
    var systemPrompt: String
    var provider: ProviderKind? = nil
    var model: String? = nil
    var temperature: Double? = nil
    var disabledTools: [String] = []
    var maxSteps: Int = 15

    static var blank: AgentProfile {
        AgentProfile(name: "新智能体", emoji: "🤖", colorHex: "5E5CE6",
                     systemPrompt: "你是一个乐于助人的 AI 智能体。")
    }
}

// MARK: - 消息

enum MessageRole: String, Codable {
    case user, assistant, tool, event
}

enum ToolCallState: String, Codable {
    case pending, awaitingApproval, running, done, failed, denied, cancelled

    var title: String {
        switch self {
        case .pending: return "排队中"
        case .awaitingApproval: return "等待批准"
        case .running: return "进行中"
        case .done: return "完成"
        case .failed: return "失败"
        case .denied: return "已拒绝"
        case .cancelled: return "已取消"
        }
    }

    var color: Color {
        switch self {
        case .done: return .green
        case .failed: return .red
        case .denied, .cancelled: return .secondary
        case .awaitingApproval: return .orange
        default: return .blue
        }
    }
}

struct ToolCallRecord: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var arguments: String
    var state: ToolCallState = .pending
    var summary: String? = nil
}

enum AttachmentKind: String, Codable {
    case image, file
}

struct Attachment: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: AttachmentKind
    var fileName: String
    var mimeType: String
    var storedName: String
}

struct ChatMessage: Identifiable, Codable, Hashable {
    var id = UUID()
    var role: MessageRole
    var text: String
    var reasoning: String = ""
    var createdAt = Date()
    var attachments: [Attachment] = []
    var toolCalls: [ToolCallRecord] = []
    var toolCallID: String? = nil
    var toolName: String? = nil
    var isError = false
    var reactions: [String] = []
    var replyToID: UUID? = nil
    var isStreaming = false

    static func event(_ text: String, isError: Bool = false) -> ChatMessage {
        var m = ChatMessage(role: .event, text: text)
        m.isError = isError
        return m
    }
}

struct Conversation: Identifiable, Codable, Hashable {
    var id = UUID()
    var agentID: UUID
    var title: String = ""
    var messages: [ChatMessage] = []
    var pinned = false
    var muted = false
    var unread = false
    var updatedAt = Date()
    var draft = ""
}

// MARK: - 任务

enum TaskStatus: String, Codable, CaseIterable, Identifiable {
    case inProgress = "in_progress"
    case todo
    case blocked
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inProgress: return "进行中"
        case .todo: return "待办"
        case .blocked: return "受阻"
        case .done: return "已完成"
        }
    }

    var color: Color {
        switch self {
        case .inProgress: return .blue
        case .todo: return .gray
        case .blocked: return .orange
        case .done: return .green
        }
    }

    var icon: String {
        switch self {
        case .inProgress: return "circle.dotted.circle"
        case .todo: return "circle"
        case .blocked: return "exclamationmark.circle"
        case .done: return "checkmark.circle.fill"
        }
    }
}

struct TaskStep: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var done = false
}

struct AgentTaskItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var detail: String = ""
    var status: TaskStatus = .todo
    var steps: [TaskStep] = []
    var notes: [String] = []
    var dueDate: Date? = nil
    var conversationID: UUID? = nil
    var createdAt = Date()
    var updatedAt = Date()

    var progress: Double {
        if steps.isEmpty { return status == .done ? 1 : 0 }
        return Double(steps.filter { $0.done }.count) / Double(steps.count)
    }

    var progressText: String {
        steps.isEmpty ? status.title : "\(steps.filter { $0.done }.count)/\(steps.count) 步"
    }
}

// MARK: - 例程

struct Routine: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var prompt: String
    var agentID: UUID
    var hour: Int = 8
    var minute: Int = 0
    /// ISO 星期：1 = 周一 … 7 = 周日
    var weekdays: [Int] = [1, 2, 3, 4, 5, 6, 7]
    var enabled = true
    var notify = true
    var lastRun: Date? = nil
    var conversationID: UUID? = nil

    var timeText: String { String(format: "%02d:%02d", hour, minute) }

    var weekdayText: String {
        let set = Set(weekdays)
        if set.count == 7 { return "每天" }
        if set == [1, 2, 3, 4, 5] { return "工作日" }
        if set == [6, 7] { return "周末" }
        if set.isEmpty { return "不重复" }
        let names = ["一", "二", "三", "四", "五", "六", "日"]
        return "每周" + weekdays.sorted().compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }.joined(separator: "、")
    }
}

// MARK: - 记忆 / 审计 / 连接器 / 快捷指令

struct MemoryItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var content: String
    var category: String = "通用"
    var createdAt = Date()
}

struct AuditEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var date = Date()
    var conversationID: UUID?
    var agentName: String
    var toolName: String
    var toolTitle: String
    var summary: String
    var arguments: String
    var result: String
    var status: ToolCallState
}

struct Connector: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var summary: String
    var baseURL: String
    var enabled = true
}

struct PromptShortcut: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var prompt: String
}

// MARK: - 设置

enum ToolPermission: String, Codable, CaseIterable, Identifiable {
    case auto, ask, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "自动允许"
        case .ask: return "每次询问"
        case .off: return "禁用"
        }
    }
}

struct AppSettings: Codable, Hashable {
    var defaultProvider: ProviderKind = .openai
    var openAIBaseURL = "https://api.openai.com/v1"
    var openAIModel = "gpt-4o-mini"
    var anthropicBaseURL = "https://api.anthropic.com"
    var anthropicModel = "claude-sonnet-5-5"
    var anthropicMaxTokens = 8192
    var imageBaseURL = ""
    var imageModel = "gpt-image-1"
    var imageSize = "1024x1024"
    var userName = ""
    var aboutMe = ""
    var toolPermissions: [String: ToolPermission] = [:]
    var biometricLock = false
    var hapticsEnabled = true
    var autoSpeak = false
    var injectMemories = true
}

enum AppTab: String, Hashable {
    case messages, tasks, activity, settings
}

enum KeyName {
    static let openAI = "openai_key"
    static let anthropic = "anthropic_key"
    static let tavily = "tavily_key"
    static let image = "image_key"
    static func connector(_ id: UUID) -> String { "connector_\(id.uuidString)" }
}
