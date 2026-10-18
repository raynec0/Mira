import Foundation

// MARK: - 记忆

struct RememberTool: AgentTool {
    let name = "remember"
    let title = "记住"
    let icon = "brain.head.profile"
    let description = "把关于用户的长期有效信息（偏好、习惯、重要的人和事）存入记忆，之后的对话都会参考。不要存密码、证件号等敏感信息。"
    var schema: JSONValue {
        Schema.object(["content": Schema.string("要记住的内容，一句话"),
                       "category": Schema.string("分类，如 偏好 / 工作 / 生活 / 人物")], required: ["content"])
    }
    let defaultRisk = ToolRisk.safe

    func summary(for args: JSONValue) -> String { "记住：\(args.str("content") ?? "")" }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let content = try args.require("content")
        let item = MemoryItem(content: content, category: args.str("category") ?? "通用")
        context.store.memories.append(item)
        return ToolOutput(text: "已记住（ID \(item.id.uuidString.prefix(8))）：\(content)")
    }
}

struct RecallMemoryTool: AgentTool {
    let name = "recall_memories"
    let title = "回忆"
    let icon = "sparkle.magnifyingglass"
    let description = "检索记忆中关于用户的信息。可按关键词过滤，留空返回全部。"
    var schema: JSONValue { Schema.object(["query": Schema.string("关键词")]) }
    let defaultRisk = ToolRisk.safe

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        var items = context.store.memories
        if let q = args.str("query")?.lowercased() {
            items = items.filter { $0.content.lowercased().contains(q) || $0.category.lowercased().contains(q) }
        }
        if items.isEmpty { return ToolOutput(text: "没有相关记忆。") }
        return ToolOutput(text: items.map { "- [\($0.id.uuidString.prefix(8))] (\($0.category)) \($0.content)" }.joined(separator: "\n"))
    }
}

struct ForgetMemoryTool: AgentTool {
    let name = "forget_memory"
    let title = "忘记"
    let icon = "eraser"
    let description = "删除一条记忆。传入记忆 ID（前 8 位即可）或内容关键词。"
    var schema: JSONValue {
        Schema.object(["memory_id": Schema.string("记忆 ID"), "query": Schema.string("或者：内容关键词")])
    }
    let defaultRisk = ToolRisk.safe

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let store = context.store
        var removed: [MemoryItem] = []
        if let id = args.str("memory_id")?.uppercased() {
            removed = store.memories.filter { $0.id.uuidString.hasPrefix(id) }
        } else if let q = args.str("query")?.lowercased() {
            removed = store.memories.filter { $0.content.lowercased().contains(q) }
        }
        guard !removed.isEmpty else { return ToolOutput(text: "没有找到匹配的记忆。", isError: true) }
        let ids = Set(removed.map { $0.id })
        store.memories.removeAll { ids.contains($0.id) }
        return ToolOutput(text: "已忘记 \(removed.count) 条：\n" + removed.map { "- \($0.content)" }.joined(separator: "\n"))
    }
}

// MARK: - 任务

@MainActor
private func findTask(_ key: String, in store: AppStore) -> Int? {
    let k = key.trimmingCharacters(in: .whitespaces)
    if let i = store.tasks.firstIndex(where: { $0.id.uuidString.hasPrefix(k.uppercased()) }) { return i }
    return store.tasks.firstIndex { $0.title == k } ?? store.tasks.firstIndex { $0.title.contains(k) }
}

@MainActor
private func describeTask(_ t: AgentTaskItem) -> String {
    var lines = ["任务 [\(t.id.uuidString.prefix(8))] \(t.title) — \(t.status.title)（\(t.progressText)）"]
    if !t.detail.isEmpty { lines.append("说明：\(t.detail)") }
    if let due = t.dueDate { lines.append("截止：\(DateParser.describe(due))") }
    for (i, s) in t.steps.enumerated() { lines.append("\(s.done ? "✅" : "⬜️") \(i + 1). \(s.title)") }
    if let note = t.notes.last { lines.append("最新进展：\(note)") }
    return lines.joined(separator: "\n")
}

struct CreateTaskTool: AgentTool {
    let name = "create_task"
    let title = "创建任务"
    let icon = "checklist.unchecked"
    let description = "为一个多步骤目标创建任务，并列出执行步骤。任务会显示在「任务」页，用户和你都可以持续推进。"
    var schema: JSONValue {
        Schema.object(["title": Schema.string("任务标题"),
                       "detail": Schema.string("目标说明"),
                       "steps": Schema.stringArray("执行步骤"),
                       "due": Schema.string("截止时间，可选")], required: ["title"])
    }
    let defaultRisk = ToolRisk.safe

    func summary(for args: JSONValue) -> String { "创建任务「\(args.str("title") ?? "")」" }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        var task = AgentTaskItem(title: try args.require("title"))
        task.detail = args.str("detail") ?? ""
        task.steps = (args["steps"]?.stringArray ?? []).map { TaskStep(title: $0) }
        task.dueDate = DateParser.parse(args.str("due"))
        task.conversationID = context.conversationID
        task.status = .inProgress
        context.store.tasks.insert(task, at: 0)
        return ToolOutput(text: "已创建。\n" + describeTask(task))
    }
}

struct UpdateTaskTool: AgentTool {
    let name = "update_task"
    let title = "更新任务"
    let icon = "arrow.triangle.2.circlepath"
    let description = "更新任务进度：修改状态、勾选完成的步骤（从 1 开始的序号）、追加步骤或记录进展。"
    var schema: JSONValue {
        Schema.object(["task_id": Schema.string("任务 ID（前 8 位即可）或标题"),
                       "status": Schema.string("新状态", options: ["todo", "in_progress", "blocked", "done"]),
                       "complete_steps": Schema.integerArray("已完成的步骤序号"),
                       "add_steps": Schema.stringArray("要追加的步骤"),
                       "note": Schema.string("进展记录")], required: ["task_id"])
    }
    let defaultRisk = ToolRisk.safe

    func summary(for args: JSONValue) -> String { "更新任务进度" }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let store = context.store
        guard let i = findTask(try args.require("task_id"), in: store) else { throw ToolError("找不到这个任务") }
        var t = store.tasks[i]
        if let s = args.str("status"), let status = TaskStatus(rawValue: s) { t.status = status }
        for n in args["complete_steps"]?.intArray ?? [] where n >= 1 && n <= t.steps.count {
            t.steps[n - 1].done = true
        }
        for s in args["add_steps"]?.stringArray ?? [] { t.steps.append(TaskStep(title: s)) }
        if let note = args.str("note") { t.notes.append("\(RelativeTime.fmt("M/d HH:mm", Date())) \(note)") }
        if !t.steps.isEmpty, t.steps.allSatisfy({ $0.done }), args.str("status") == nil { t.status = .done }
        t.updatedAt = Date()
        store.tasks[i] = t
        return ToolOutput(text: "已更新。\n" + describeTask(t))
    }
}

struct ListTasksTool: AgentTool {
    let name = "list_tasks"
    let title = "查看任务"
    let icon = "list.bullet.rectangle"
    let description = "列出任务及其进度。"
    var schema: JSONValue {
        Schema.object(["status": Schema.string("按状态过滤", options: ["todo", "in_progress", "blocked", "done", "active"])])
    }
    let defaultRisk = ToolRisk.safe

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        var tasks = context.store.tasks
        switch args.str("status") {
        case "active"?: tasks = tasks.filter { $0.status != .done }
        case let s?: if let st = TaskStatus(rawValue: s) { tasks = tasks.filter { $0.status == st } }
        case nil: break
        }
        if tasks.isEmpty { return ToolOutput(text: "没有任务。") }
        return ToolOutput(text: tasks.prefix(30).map { describeTask($0) }.joined(separator: "\n\n"))
    }
}

// MARK: - 例程

struct CreateRoutineTool: AgentTool {
    let name = "create_routine"
    let title = "创建例程"
    let icon = "alarm"
    let description = "创建定时例程：在每周指定的日子和时间，自动让智能体执行一段指令（例如每天早上的简报），完成后推送通知。"
    var schema: JSONValue {
        Schema.object(["title": Schema.string("例程名称"),
                       "prompt": Schema.string("到时要执行的指令"),
                       "time": Schema.string("时间，24 小时制 HH:mm"),
                       "weekdays": Schema.integerArray("星期，1=周一 … 7=周日，默认每天")], required: ["title", "prompt", "time"])
    }
    let defaultRisk = ToolRisk.action

    func summary(for args: JSONValue) -> String { "每天 \(args.str("time") ?? "") 运行「\(args.str("title") ?? "")」" }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let time = try args.require("time").split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard time.count >= 2, (0...23).contains(time[0]), (0...59).contains(time[1]) else { throw ToolError("时间格式应为 HH:mm") }
        var days = (args["weekdays"]?.intArray ?? []).filter { (1...7).contains($0) }
        if days.isEmpty { days = [1, 2, 3, 4, 5, 6, 7] }
        var routine = Routine(title: try args.require("title"), prompt: try args.require("prompt"),
                              agentID: context.agent.id, hour: time[0], minute: time[1], weekdays: days)
        routine.lastRun = Date() // 不补跑今天已经过去的时间点
        routine.conversationID = context.conversationID
        context.store.routines.append(routine)
        await RoutineScheduler.shared.reschedule()
        return ToolOutput(text: "已创建例程「\(routine.title)」：\(routine.weekdayText) \(routine.timeText)。可在「任务 › 例程」中修改。")
    }
}
