import Foundation

struct LLMError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct LLMImage {
    var mime: String
    var base64: String
}

/// 与服务商无关的统一消息格式。
struct LLMMessage {
    enum Role { case user, assistant, tool }
    var role: Role
    var text: String
    var images: [LLMImage] = []
    var toolCalls: [ToolCallRecord] = []
    var toolCallID: String? = nil
    var isError = false
}

struct ToolSpec {
    let name: String
    let description: String
    let schema: JSONValue
}

struct ModelConfig {
    var provider: ProviderKind
    var baseURL: String
    var apiKey: String
    var model: String
    var temperature: Double?
    var maxTokens: Int
}

enum StreamEvent {
    case text(String)
    case reasoning(String)
    case toolCall(ToolCallRecord)
    case done(String?)
}

enum LLMClient {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 180
        c.timeoutIntervalForResource = 1200
        return URLSession(configuration: c)
    }()

    static func stream(config: ModelConfig, system: String, messages: [LLMMessage], tools: [ToolSpec]) -> AsyncThrowingStream<StreamEvent, Error> {
        switch config.provider {
        case .openai: return OpenAIProvider.stream(config: config, system: system, messages: messages, tools: tools)
        case .anthropic: return AnthropicProvider.stream(config: config, system: system, messages: messages, tools: tools)
        }
    }

    /// 拼接 base URL 与路径；如果 base 已经是完整端点则原样使用。
    static func endpoint(_ base: String, _ path: String) throws -> URL {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        let full = b.hasSuffix(path) ? b : b + "/" + path
        guard let url = URL(string: full), url.scheme != nil else { throw LLMError("无效的接口地址：\(base)") }
        return url
    }

    static func anthropicEndpoint(_ base: String, _ path: String) throws -> URL {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        if !b.hasSuffix("/v1") { b += "/v1" }
        return try endpoint(b, path)
    }

    /// 打开流式请求；非 2xx 时读出错误信息并抛出。
    static func open(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError("无效的响应") }
        if !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 4000 { break }
            }
            throw LLMError("HTTP \(http.statusCode)：\(errorMessage(from: body))")
        }
        return bytes
    }

    static func errorMessage(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
            if let msg = obj["error"] as? String { return msg }
            if let msg = obj["message"] as? String { return msg }
        }
        return body.isEmpty ? "未知错误" : String(body.prefix(500))
    }

    static func parseJSONLine(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 拉取模型列表。
    static func listModels(provider: ProviderKind, baseURL: String, apiKey: String) async throws -> [String] {
        var req: URLRequest
        switch provider {
        case .openai:
            req = URLRequest(url: try endpoint(baseURL, "models"))
            if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        case .anthropic:
            req = URLRequest(url: try anthropicEndpoint(baseURL, "models?limit=100"))
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError("HTTP \(status)：\(errorMessage(from: String(decoding: data, as: UTF8.self)))")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { throw LLMError("无法解析模型列表") }
        return list.compactMap { $0["id"] as? String }.sorted()
    }
}

// MARK: - OpenAI 兼容

enum OpenAIProvider {
    private struct PartialCall {
        var id = ""
        var name = ""
        var args = ""
    }

    static func encode(system: String, messages: [LLMMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = [["role": "system", "content": system]]
        for m in messages {
            switch m.role {
            case .user:
                if m.images.isEmpty {
                    out.append(["role": "user", "content": m.text])
                } else {
                    var parts: [[String: Any]] = []
                    if !m.text.isEmpty { parts.append(["type": "text", "text": m.text]) }
                    for img in m.images {
                        parts.append(["type": "image_url", "image_url": ["url": "data:\(img.mime);base64,\(img.base64)"]])
                    }
                    out.append(["role": "user", "content": parts])
                }
            case .assistant:
                var d: [String: Any] = ["role": "assistant", "content": m.text]
                if !m.toolCalls.isEmpty {
                    d["tool_calls"] = m.toolCalls.map { c -> [String: Any] in
                        ["id": c.id, "type": "function", "function": ["name": c.name, "arguments": c.arguments.isEmpty ? "{}" : c.arguments]]
                    }
                }
                out.append(d)
            case .tool:
                out.append(["role": "tool", "tool_call_id": m.toolCallID ?? "", "content": m.text.isEmpty ? "（空）" : m.text])
            }
        }
        return out
    }

    static func stream(config: ModelConfig, system: String, messages: [LLMMessage], tools: [ToolSpec]) -> AsyncThrowingStream<StreamEvent, Error> {
        let encoded = encode(system: system, messages: messages)
        let toolDefs: [[String: Any]] = tools.map { t -> [String: Any] in
            ["type": "function", "function": ["name": t.name, "description": t.description, "parameters": t.schema.any]]
        }
        var body: [String: Any] = ["model": config.model, "messages": encoded, "stream": true]
        if !toolDefs.isEmpty { body["tools"] = toolDefs }
        if let t = config.temperature { body["temperature"] = t }
        let bodyData = try? JSONSerialization.data(withJSONObject: body)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: try LLMClient.endpoint(config.baseURL, "chat/completions"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if !config.apiKey.isEmpty { req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
                    req.httpBody = bodyData
                    let bytes = try await LLMClient.open(req)

                    var partial: [Int: PartialCall] = [:]
                    var finish: String?
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line.hasPrefix("data:"), line.contains("[DONE]") { break }
                        guard let obj = LLMClient.parseJSONLine(line) else { continue }
                        if let err = obj["error"] as? [String: Any] {
                            throw LLMError(err["message"] as? String ?? "接口返回错误")
                        }
                        guard let choices = obj["choices"] as? [[String: Any]], let choice = choices.first else { continue }
                        if let delta = choice["delta"] as? [String: Any] {
                            if let c = delta["content"] as? String, !c.isEmpty { continuation.yield(.text(c)) }
                            if let r = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !r.isEmpty {
                                continuation.yield(.reasoning(r))
                            }
                            if let calls = delta["tool_calls"] as? [[String: Any]] {
                                for (offset, tc) in calls.enumerated() {
                                    let idx = (tc["index"] as? Int) ?? offset
                                    var entry = partial[idx] ?? PartialCall()
                                    if let id = tc["id"] as? String, !id.isEmpty { entry.id = id }
                                    if let fn = tc["function"] as? [String: Any] {
                                        if let n = fn["name"] as? String, !n.isEmpty {
                                            if entry.name.isEmpty { entry.name = n } else if entry.name != n { entry.name += n }
                                        }
                                        if let a = fn["arguments"] as? String { entry.args += a }
                                    }
                                    partial[idx] = entry
                                }
                            }
                        }
                        if let f = choice["finish_reason"] as? String { finish = f }
                    }
                    for idx in partial.keys.sorted() {
                        guard let e = partial[idx], !e.name.isEmpty else { continue }
                        let id = e.id.isEmpty ? "call_\(UUID().uuidString.prefix(12))" : e.id
                        continuation.yield(.toolCall(ToolCallRecord(id: id, name: e.name, arguments: e.args.isEmpty ? "{}" : e.args)))
                    }
                    continuation.yield(.done(finish))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Anthropic

enum AnthropicProvider {
    private struct Block {
        var type: String
        var id = ""
        var name = ""
        var json = ""
    }

    static func encode(messages: [LLMMessage]) -> [[String: Any]] {
        var out: [(role: String, blocks: [[String: Any]])] = []
        for m in messages {
            var role = "user"
            var blocks: [[String: Any]] = []
            switch m.role {
            case .user:
                for img in m.images {
                    blocks.append(["type": "image", "source": ["type": "base64", "media_type": img.mime, "data": img.base64]])
                }
                if !m.text.isEmpty { blocks.append(["type": "text", "text": m.text]) }
                if blocks.isEmpty { blocks.append(["type": "text", "text": "（空消息）"]) }
            case .assistant:
                role = "assistant"
                let trimmed = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { blocks.append(["type": "text", "text": trimmed]) }
                for c in m.toolCalls {
                    let input = JSONValue.parse(c.arguments)?.object.map { JSONValue.object($0).any } ?? [String: Any]()
                    blocks.append(["type": "tool_use", "id": c.id, "name": c.name, "input": input])
                }
                if blocks.isEmpty { continue }
            case .tool:
                blocks.append(["type": "tool_result", "tool_use_id": m.toolCallID ?? "",
                               "content": m.text.isEmpty ? "（空）" : m.text, "is_error": m.isError])
            }
            if let last = out.last, last.role == role {
                out[out.count - 1].blocks.append(contentsOf: blocks)
            } else {
                out.append((role, blocks))
            }
        }
        // 第一条必须是 user。
        while let first = out.first, first.role != "user" { out.removeFirst() }
        return out.map { ["role": $0.role, "content": $0.blocks] }
    }

    static func stream(config: ModelConfig, system: String, messages: [LLMMessage], tools: [ToolSpec]) -> AsyncThrowingStream<StreamEvent, Error> {
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "system": system,
            "messages": encode(messages: messages),
            "stream": true
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { t -> [String: Any] in
                ["name": t.name, "description": t.description, "input_schema": t.schema.any]
            }
        }
        if let t = config.temperature { body["temperature"] = min(t, 1) }
        let bodyData = try? JSONSerialization.data(withJSONObject: body)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: try LLMClient.anthropicEndpoint(config.baseURL, "messages"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    req.httpBody = bodyData
                    let bytes = try await LLMClient.open(req)

                    var blocks: [Int: Block] = [:]
                    var stop: String?
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let obj = LLMClient.parseJSONLine(line) else { continue }
                        let type = (obj["type"] as? String) ?? ""
                        let idx = (obj["index"] as? Int) ?? 0
                        switch type {
                        case "content_block_start":
                            if let cb = obj["content_block"] as? [String: Any] {
                                var b = Block(type: (cb["type"] as? String) ?? "")
                                b.id = (cb["id"] as? String) ?? ""
                                b.name = (cb["name"] as? String) ?? ""
                                blocks[idx] = b
                                if b.type == "text", let t = cb["text"] as? String, !t.isEmpty {
                                    continuation.yield(.text(t))
                                }
                            }
                        case "content_block_delta":
                            if let d = obj["delta"] as? [String: Any] {
                                switch (d["type"] as? String) ?? "" {
                                case "text_delta":
                                    if let t = d["text"] as? String { continuation.yield(.text(t)) }
                                case "input_json_delta":
                                    blocks[idx]?.json += (d["partial_json"] as? String) ?? ""
                                case "thinking_delta":
                                    if let t = d["thinking"] as? String { continuation.yield(.reasoning(t)) }
                                default:
                                    break
                                }
                            }
                        case "content_block_stop":
                            if let b = blocks[idx], b.type == "tool_use" {
                                continuation.yield(.toolCall(ToolCallRecord(id: b.id, name: b.name, arguments: b.json.isEmpty ? "{}" : b.json)))
                            }
                        case "message_delta":
                            if let d = obj["delta"] as? [String: Any], let s = d["stop_reason"] as? String { stop = s }
                        case "error":
                            let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "Anthropic 接口错误"
                            throw LLMError(msg)
                        default:
                            break
                        }
                    }
                    continuation.yield(.done(stop))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
