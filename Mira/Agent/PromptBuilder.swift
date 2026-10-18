import Foundation

@MainActor
enum PromptBuilder {
    static let maxHistory = 80

    /// 把对话转换成发送给模型的消息，并修补未完成的工具调用。
    static func build(_ all: [ChatMessage], store: AppStore) -> [LLMMessage] {
        // 截取最近的消息，并从一条用户消息开始，避免拆散工具调用对。
        var messages = all.filter { $0.role != .event }
        if messages.count > maxHistory {
            var start = messages.count - maxHistory
            while start < messages.count, messages[start].role != .user { start += 1 }
            messages = Array(messages[start...])
        }
        let recentImageCutoff = max(0, messages.count - 12)

        var issued = Set<String>()
        var answered = Set<String>()
        for m in messages where m.role == .tool {
            if let id = m.toolCallID { answered.insert(id) }
        }

        var out: [LLMMessage] = []
        for (index, m) in messages.enumerated() {
            switch m.role {
            case .event:
                continue
            case .user:
                var text = m.text
                if let rid = m.replyToID, let quoted = all.first(where: { $0.id == rid }) {
                    text = "（引用回复：「\(quoted.text.prefix(200))」）\n" + text
                }
                var images: [LLMImage] = []
                for a in m.attachments {
                    let url = store.url(for: a)
                    if a.kind == .image {
                        if index >= recentImageCutoff, let data = try? Data(contentsOf: url) {
                            images.append(LLMImage(mime: a.mimeType.isEmpty ? "image/jpeg" : a.mimeType, base64: data.base64EncodedString()))
                        } else {
                            text += "\n[图片：\(a.fileName)]"
                        }
                    } else if let content = FileText.extract(url: url, mime: a.mimeType) {
                        text += "\n\n[附件：\(a.fileName)]\n```\n\(content.truncated(40000))\n```"
                    } else {
                        text += "\n\n[附件：\(a.fileName)（无法读取文本内容）]"
                    }
                }
                if text.isEmpty && images.isEmpty { text = "（空消息）" }
                out.append(LLMMessage(role: .user, text: text, images: images))
            case .assistant:
                if m.text.isEmpty && m.toolCalls.isEmpty { continue }
                out.append(LLMMessage(role: .assistant, text: m.text, toolCalls: m.toolCalls))
                for c in m.toolCalls {
                    issued.insert(c.id)
                    if !answered.contains(c.id) {
                        out.append(LLMMessage(role: .tool, text: "（此工具调用已被取消，未执行）", toolCallID: c.id, isError: true))
                    }
                }
            case .tool:
                guard let id = m.toolCallID, issued.contains(id) else { continue }
                var text = m.text
                if !m.attachments.isEmpty {
                    text += "\n（已向用户展示 \(m.attachments.count) 个附件）"
                }
                out.append(LLMMessage(role: .tool, text: text, toolCallID: id, isError: m.isError))
            }
        }
        return out
    }

    static func systemPrompt(for agent: AgentProfile, store: AppStore) -> String {
        let now = Date()
        var lines: [String] = [agent.systemPrompt, "", "# 当前环境"]
        lines.append("- 时间：\(RelativeTime.fmt("yyyy年M月d日 EEEE HH:mm", now))（时区 \(TimeZone.current.identifier)）")
        lines.append("- 设备：iPhone 上的 App「Mira」，界面类似 iMessage")
        let s = store.settings
        if !s.userName.isEmpty { lines.append("- 用户称呼：\(s.userName)") }
        if !s.aboutMe.isEmpty { lines.append("- 关于用户：\(s.aboutMe)") }

        if s.injectMemories, !store.memories.isEmpty {
            lines.append("")
            lines.append("# 关于用户的记忆（用 remember / forget_memory 维护）")
            for m in store.memories.suffix(60) {
                lines.append("- [\(m.id.uuidString.prefix(8))] (\(m.category)) \(m.content)")
            }
        }

        let active = store.tasks.filter { $0.status != .done }.prefix(15)
        if !active.isEmpty {
            lines.append("")
            lines.append("# 进行中的任务（用 update_task 更新）")
            for t in active {
                lines.append("- [\(t.id.uuidString.prefix(8))] \(t.title) — \(t.status.title)，\(t.progressText)")
            }
        }

        if !store.connectors.filter({ $0.enabled }).isEmpty {
            lines.append("")
            lines.append("# 已接入的连接器（通过 call_connector 调用）")
            for c in store.connectors where c.enabled { lines.append("- \(c.name)：\(c.summary)") }
        }

        lines.append("")
        lines.append("""
        # 行动准则
        1. 需要信息或执行操作时直接调用工具，不要假装已经做完；可以连续多次调用工具，直到把事情办完。
        2. 发送、删除、写入等敏感操作，系统会自动向用户请求批准，你只需正常调用工具；如果被拒绝，不要重复尝试。
        3. 多步骤或需要较长时间的目标，先用 create_task 建立任务并列出步骤，推进过程中用 update_task 更新进度。
        4. 用户透露长期有效的偏好或个人信息时，用 remember 记下来；不要记录密码、证件号等敏感信息。
        5. 需要定期做的事情，用 create_routine 建立例程。
        6. 使用网页信息时附上来源链接；不确定时如实说明。
        7. 回复适合在手机上阅读：简洁、分段，必要时使用列表和粗体。
        """)
        return lines.joined(separator: "\n")
    }
}
