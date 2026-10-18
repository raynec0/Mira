import Foundation
import UIKit

enum ApprovalDecision {
    case once, always, deny
}

/// 智能体执行引擎：流式调用模型 → 执行工具（含批准） → 循环，直到完成。
@MainActor
final class AgentEngine: ObservableObject {
    static let shared = AgentEngine()

    @Published private(set) var running: Set<UUID> = []
    @Published private(set) var pendingApprovals = 0

    private var tasks: [UUID: Task<String, Never>] = [:]
    private var approvals: [String: (conv: UUID, cont: CheckedContinuation<ApprovalDecision, Never>)] = [:]
    private var silentRuns: Set<UUID> = []
    private var store: AppStore { AppStore.shared }

    func isRunning(_ id: UUID) -> Bool { running.contains(id) }

    // MARK: 入口

    func send(text: String, attachments: [Attachment] = [], conversationID: UUID, replyTo: UUID? = nil) {
        var msg = ChatMessage(role: .user, text: text)
        msg.attachments = attachments
        msg.replyToID = replyTo
        store.append(msg, to: conversationID)
        if let i = store.index(of: conversationID), store.conversations[i].title.isEmpty {
            let base = text.isEmpty ? "图片" : text
            store.conversations[i].title = String(base.replacingOccurrences(of: "\n", with: " ").prefix(20))
        }
        start(conversationID)
    }

    @discardableResult
    func start(_ convID: UUID, notifyOnFinish: Bool = true) -> Task<String, Never>? {
        if running.contains(convID) { return tasks[convID] }
        running.insert(convID)
        if !notifyOnFinish { silentRuns.insert(convID) }
        let task = Task { [weak self] () -> String in
            guard let self else { return "" }
            let result = await self.runLoop(convID)
            self.running.remove(convID)
            self.tasks[convID] = nil
            self.silentRuns.remove(convID)
            return result
        }
        tasks[convID] = task
        return task
    }

    func stop(_ convID: UUID) {
        tasks[convID]?.cancel()
        for (id, entry) in approvals where entry.conv == convID {
            approvals[id] = nil
            entry.cont.resume(returning: .deny)
        }
        pendingApprovals = approvals.count
    }

    func stopAll() {
        for id in running { stop(id) }
    }

    func resolveApproval(_ callID: String, _ decision: ApprovalDecision) {
        guard let entry = approvals.removeValue(forKey: callID) else { return }
        pendingApprovals = approvals.count
        entry.cont.resume(returning: decision)
    }

    // MARK: 例程

    func runRoutine(_ routine: Routine) async {
        let convID: UUID
        if let cid = routine.conversationID, store.conversation(cid) != nil {
            convID = cid
        } else {
            convID = store.newConversation(agentID: routine.agentID, title: routine.title)
        }
        if let i = store.routines.firstIndex(where: { $0.id == routine.id }) {
            store.routines[i].lastRun = Date()
            store.routines[i].conversationID = convID
        }
        guard !running.contains(convID) else { return }
        store.append(.event("⏰ 例程「\(routine.title)」开始运行"), to: convID)
        store.append(ChatMessage(role: .user, text: routine.prompt), to: convID)
        let result = await start(convID, notifyOnFinish: false)?.value ?? ""
        if routine.notify, !result.isEmpty {
            NotificationService.post(title: "⏰ \(routine.title)", body: result.plainPreview, conversationID: convID)
        }
    }

    // MARK: 主循环

    private func runLoop(_ convID: UUID) async -> String {
        let bgID = UIApplication.shared.beginBackgroundTask(withName: "mira.agent") {
            Task { @MainActor in AgentEngine.shared.stop(convID) }
        }
        defer { if bgID != .invalid { UIApplication.shared.endBackgroundTask(bgID) } }

        guard let conv = store.conversation(convID) else { return "" }
        let agent = store.agent(for: conv.agentID)
        let config: ModelConfig
        do {
            config = try store.modelConfig(for: agent)
        } catch {
            store.append(.event("⚠️ \(error.localizedDescription)", isError: true), to: convID)
            return ""
        }
        let tools = ToolRegistry.specs(for: agent)
        var finalText = ""
        var steps = 0
        let maxSteps = max(1, agent.maxSteps)

        loop: while steps < maxSteps {
            steps += 1
            if Task.isCancelled { break }
            guard let current = store.conversation(convID) else { break }
            let history = PromptBuilder.build(current.messages, store: store)
            let system = PromptBuilder.systemPrompt(for: agent, store: store)

            var draft = ChatMessage(role: .assistant, text: "")
            draft.isStreaming = true
            let msgID = draft.id
            store.append(draft, to: convID)

            var text = ""
            var reasoning = ""
            var calls: [ToolCallRecord] = []
            var lastFlush = Date.distantPast
            var failure: Error?

            do {
                let stream = LLMClient.stream(config: config, system: system, messages: history, tools: tools)
                for try await event in stream {
                    switch event {
                    case .text(let t): text += t
                    case .reasoning(let r): reasoning += r
                    case .toolCall(let c): calls.append(c)
                    case .done: break
                    }
                    if Date().timeIntervalSince(lastFlush) > 0.05 {
                        lastFlush = Date()
                        let t = text, r = reasoning
                        store.updateMessage(msgID, in: convID) { m in
                            m.text = t
                            m.reasoning = r
                        }
                    }
                }
            } catch {
                failure = error
            }

            let cancelled = Task.isCancelled
            let finalCalls = calls.map { c -> ToolCallRecord in
                var copy = c
                copy.state = cancelled ? .cancelled : .pending
                return copy
            }
            let t = text, r = reasoning
            store.updateMessage(msgID, in: convID) { m in
                m.text = t
                m.reasoning = r
                m.isStreaming = false
                m.toolCalls = finalCalls
            }

            if cancelled || failure is CancellationError {
                if text.isEmpty && calls.isEmpty { store.deleteMessage(msgID, in: convID) }
                break loop
            }
            if let failure {
                if text.isEmpty && calls.isEmpty { store.deleteMessage(msgID, in: convID) }
                store.append(.event("⚠️ \(failure.localizedDescription)", isError: true), to: convID)
                break loop
            }
            if !text.isEmpty { finalText = text }
            if calls.isEmpty {
                if text.isEmpty {
                    store.updateMessage(msgID, in: convID) { $0.text = "（没有回复内容）" }
                }
                break loop
            }

            for call in finalCalls {
                if Task.isCancelled {
                    store.updateToolCall(call.id, messageID: msgID, convID: convID, state: .cancelled, summary: nil)
                    continue
                }
                let output = await execute(call, messageID: msgID, convID: convID, agent: agent)
                var result = ChatMessage(role: .tool, text: output.text.truncated(24000))
                result.toolCallID = call.id
                result.toolName = call.name
                result.isError = output.isError
                result.attachments = output.attachments
                store.append(result, to: convID)
            }
            if Task.isCancelled { break loop }
            if steps >= maxSteps {
                store.append(.event("已达到单次最大步数（\(maxSteps)），发送「继续」可以让我接着做。"), to: convID)
            }
        }

        finish(convID: convID, agent: agent, finalText: finalText)
        return finalText
    }

    private func finish(convID: UUID, agent: AgentProfile, finalText: String) {
        guard let i = store.index(of: convID) else { return }
        let viewing = store.isForeground && store.activeConversationID == convID
        if !viewing { store.conversations[i].unread = true }
        let muted = store.conversations[i].muted
        if !store.isForeground, !muted, !finalText.isEmpty, !silentRuns.contains(convID) {
            NotificationService.post(title: agent.name, body: finalText.plainPreview, conversationID: convID)
        }
        if viewing {
            if store.settings.autoSpeak, !finalText.isEmpty { Speaker.shared.speak(finalText) }
            Haptics.notify(.success)
        }
    }

    // MARK: 工具执行

    private func execute(_ call: ToolCallRecord, messageID: UUID, convID: UUID, agent: AgentProfile) async -> ToolOutput {
        func setState(_ state: ToolCallState, _ summary: String? = nil) {
            store.updateToolCall(call.id, messageID: messageID, convID: convID, state: state, summary: summary)
        }
        func log(_ status: ToolCallState, _ summary: String, _ result: String) {
            store.addAudit(AuditEntry(conversationID: convID, agentName: agent.name, toolName: call.name,
                                      toolTitle: ToolRegistry.title(for: call.name), summary: summary,
                                      arguments: call.arguments, result: String(result.prefix(4000)), status: status))
        }

        guard let tool = ToolRegistry.tool(named: call.name) else {
            setState(.failed, "未知工具")
            return ToolOutput(text: "错误：不存在名为 \(call.name) 的工具。", isError: true)
        }
        let raw = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let args = raw.isEmpty ? JSONValue.object([:]) : JSONValue.parse(raw) else {
            setState(.failed, "参数格式错误")
            return ToolOutput(text: "错误：参数不是合法 JSON：\(raw.prefix(300))", isError: true)
        }

        let summary = tool.summary(for: args)
        var permission = store.permission(for: tool.name, risk: tool.risk(for: args))
        if agent.disabledTools.contains(tool.name) { permission = .off }

        if permission == .off {
            setState(.denied, summary)
            log(.denied, summary, "工具已禁用")
            return ToolOutput(text: "该工具已被用户禁用，请换一种方式完成。", isError: true)
        }

        if permission == .ask {
            if Task.isCancelled {
                setState(.cancelled, summary)
                return ToolOutput(text: "已取消", isError: true)
            }
            setState(.awaitingApproval, summary)
            if !store.isForeground {
                NotificationService.post(title: "\(agent.name) 需要你的批准", body: summary, conversationID: convID)
            }
            Haptics.notify(.warning)
            let decision: ApprovalDecision = await withCheckedContinuation { cont in
                approvals[call.id] = (convID, cont)
                pendingApprovals = approvals.count
            }
            switch decision {
            case .deny:
                setState(.denied, summary)
                log(.denied, summary, "用户拒绝")
                return ToolOutput(text: "用户拒绝了这个操作。除非用户另有指示，不要再次尝试。", isError: true)
            case .always:
                store.settings.toolPermissions[tool.name] = .auto
            case .once:
                break
            }
        }

        if Task.isCancelled {
            setState(.cancelled, summary)
            return ToolOutput(text: "已取消", isError: true)
        }

        setState(.running, summary)
        let context = ToolContext(conversationID: convID, agent: agent, store: store)
        do {
            let output = try await tool.run(args, context: context)
            setState(output.isError ? .failed : .done, summary)
            log(output.isError ? .failed : .done, summary, output.text)
            return output
        } catch {
            setState(.failed, summary)
            log(.failed, summary, error.localizedDescription)
            return ToolOutput(text: "错误：\(error.localizedDescription)", isError: true)
        }
    }
}
