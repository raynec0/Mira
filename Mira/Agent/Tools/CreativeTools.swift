import Foundation
import JavaScriptCore
import UniformTypeIdentifiers

// MARK: - JavaScript

private final class LogBox {
    var lines: [String] = []
    var error: String?
}

struct RunJavaScriptTool: AgentTool {
    let name = "run_javascript"
    let title = "运行代码"
    let icon = "chevron.left.forwardslash.chevron.right"
    let description = "在本地沙盒中运行 JavaScript（无网络、无 DOM），用于精确计算、数据处理、日期推算等。用 console.log 输出，最后一个表达式的值也会返回。"
    var schema: JSONValue { Schema.object(["code": Schema.string("JavaScript 代码")], required: ["code"]) }
    let defaultRisk = ToolRisk.safe

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let code = try args.require("code")
        let result = await Task.detached(priority: .userInitiated) { () -> (String, Bool) in
            Self.evaluate(code)
        }.value
        return ToolOutput(text: result.0, isError: result.1)
    }

    nonisolated static func evaluate(_ code: String) -> (String, Bool) {
        guard let ctx = JSContext() else { return ("无法创建 JavaScript 环境", true) }
        let box = LogBox()
        let log: @convention(block) (String) -> Void = { line in box.lines.append(line) }
        ctx.setObject(log, forKeyedSubscript: "__mira_log" as NSString)
        ctx.exceptionHandler = { _, exception in box.error = exception?.toString() }
        ctx.evaluateScript("""
        var console = { log: function() {
            __mira_log(Array.prototype.map.call(arguments, function(a) {
                try { return (typeof a === 'object') ? JSON.stringify(a) : String(a); } catch (e) { return String(a); }
            }).join(' '));
        } };
        console.error = console.log; console.warn = console.log; console.info = console.log;
        """)
        let value = ctx.evaluateScript(code)
        var out = box.lines.joined(separator: "\n")
        if let err = box.error {
            return ((out.isEmpty ? "" : out + "\n") + "异常：\(err)", true)
        }
        if let v = value, !v.isUndefined, !v.isNull {
            var desc = v.toString() ?? ""
            if v.isObject, let json = ctx.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [v, NSNull(), 2]),
               !json.isUndefined {
                desc = json.toString() ?? desc
            }
            out += (out.isEmpty ? "" : "\n") + "返回值：\(desc)"
        }
        return (out.isEmpty ? "（运行完成，没有输出）" : out.truncated(20000), false)
    }
}

// MARK: - 文档

enum DocumentFiles {
    @MainActor
    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "文档.md" : cleaned
    }

    @MainActor
    static func uniqueURL(for name: String, in dir: URL) -> URL {
        var url = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }
}

struct CreateDocumentTool: AgentTool {
    let name = "create_document"
    let title = "创建文档"
    let icon = "doc.richtext"
    let description = "生成一个文件（Markdown、TXT、HTML、CSV、JSON 等），保存在「文件」App 的 Mira 文件夹中，并以附件形式发给用户，方便分享。"
    var schema: JSONValue {
        Schema.object(["filename": Schema.string("文件名，带扩展名，如 周报.md"),
                       "content": Schema.string("完整文件内容")], required: ["filename", "content"])
    }
    let defaultRisk = ToolRisk.safe

    func summary(for args: JSONValue) -> String { "创建 \(args.str("filename") ?? "文档")" }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        var name = DocumentFiles.sanitize(try args.require("filename"))
        if (name as NSString).pathExtension.isEmpty { name += ".md" }
        let content = args["content"]?.string ?? ""
        let data = Data(content.utf8)
        let url = DocumentFiles.uniqueURL(for: name, in: context.store.filesDir)
        try data.write(to: url, options: .atomic)
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "text/plain"
        guard let att = context.store.storeAttachment(data: data, fileName: url.lastPathComponent, mime: mime, kind: .file) else {
            throw ToolError("保存附件失败")
        }
        return ToolOutput(text: "已创建「\(url.lastPathComponent)」（\(content.count) 字符），已发送给用户，并保存在 文件 App › Mira › Mira 文件。",
                          attachments: [att])
    }
}

struct ListDocumentsTool: AgentTool {
    let name = "list_documents"
    let title = "查看文件"
    let icon = "folder"
    let description = "列出 Mira 文件夹中已保存的文档。"
    var schema: JSONValue { Schema.object([:]) }
    let defaultRisk = ToolRisk.safe

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: context.store.filesDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        if urls.isEmpty { return ToolOutput(text: "文件夹是空的。") }
        let lines = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url -> String in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
            let date = values?.contentModificationDate.map { DateParser.describe($0) } ?? ""
            return "- \(url.lastPathComponent)（\(size)，\(date)）"
        }
        return ToolOutput(text: lines.joined(separator: "\n"))
    }
}

struct ReadDocumentTool: AgentTool {
    let name = "read_document"
    let title = "读取文件"
    let icon = "doc.text.magnifyingglass"
    let description = "读取 Mira 文件夹中某个文档的内容（支持文本与 PDF）。"
    var schema: JSONValue { Schema.object(["filename": Schema.string("文件名")], required: ["filename"]) }
    let defaultRisk = ToolRisk.safe

    func summary(for args: JSONValue) -> String { "读取 \(args.str("filename") ?? "")" }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let name = try args.require("filename")
        let url = context.store.filesDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("找不到文件 \(name)") }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ""
        guard let text = FileText.extract(url: url, mime: mime) else { throw ToolError("无法读取这个文件的文本内容") }
        return ToolOutput(text: text.truncated(30000))
    }
}

// MARK: - 图像生成

struct GenerateImageTool: AgentTool {
    let name = "generate_image"
    let title = "生成图片"
    let icon = "photo.artframe"
    let description = "根据文字描述生成图片，并直接展示给用户。描述越具体越好。"
    var schema: JSONValue {
        Schema.object(["prompt": Schema.string("图片描述（建议用英文，细节丰富）"),
                       "size": Schema.string("尺寸", options: ["1024x1024", "1024x1536", "1536x1024"])], required: ["prompt"])
    }
    let defaultRisk = ToolRisk.safe

    func summary(for args: JSONValue) -> String { "生成图片：\(args.str("prompt")?.prefix(40) ?? "")" }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let s = context.store.settings
        let base = s.imageBaseURL.isEmpty ? s.openAIBaseURL : s.imageBaseURL
        var key = Keychain.get(KeyName.image)
        if key.isEmpty { key = Keychain.get(KeyName.openAI) }
        guard !key.isEmpty else { throw ToolError("请先在「设置 › 图像生成」中配置 API Key") }
        let prompt = try args.require("prompt")
        var req = URLRequest(url: try LLMClient.endpoint(base, "images/generations"))
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": s.imageModel, "prompt": prompt, "n": 1, "size": args.str("size") ?? s.imageSize
        ] as [String: Any])
        let (data, resp) = try await HTTP.send(req)
        guard (200..<300).contains(resp.statusCode) else {
            throw ToolError("HTTP \(resp.statusCode)：\(LLMClient.errorMessage(from: String(decoding: data, as: UTF8.self)))")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (obj["data"] as? [[String: Any]])?.first else { throw ToolError("无法解析图片结果") }
        var downloaded: Data?
        if let b64 = first["b64_json"] as? String {
            downloaded = Data(base64Encoded: b64)
        } else if let urlString = first["url"] as? String, let url = URL(string: urlString) {
            downloaded = try await HTTP.get(url).0
        }
        guard let imageData = downloaded,
              let att = context.store.storeAttachment(data: imageData, fileName: "image.png", mime: "image/png", kind: .image) else {
            throw ToolError("没有拿到图片数据")
        }
        var text = "图片已生成并展示给用户。"
        if let revised = first["revised_prompt"] as? String { text += "\n实际使用的描述：\(revised)" }
        return ToolOutput(text: text, attachments: [att])
    }
}

// MARK: - 连接器

enum ConnectorHeaders {
    static func load(_ id: UUID) -> [String: String] {
        let raw = Keychain.get(KeyName.connector(id))
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return dict
    }

    static func save(_ headers: [String: String], for id: UUID) {
        guard let data = try? JSONSerialization.data(withJSONObject: headers),
              let s = String(data: data, encoding: .utf8) else { return }
        Keychain.set(headers.isEmpty ? "" : s, for: KeyName.connector(id))
    }
}

struct ConnectorTool: AgentTool {
    let name = "call_connector"
    let title = "调用连接器"
    let icon = "point.3.connected.trianglepath.dotted"
    var description: String {
        let list = AppStore.shared.connectors.filter { $0.enabled }
            .map { "- \($0.name)：\($0.summary)（Base URL：\($0.baseURL)）" }.joined(separator: "\n")
        return "调用用户接入的 HTTP API。认证信息会自动附加，不需要你提供。可用连接器：\n" + list
    }
    var schema: JSONValue {
        Schema.object(["connector": Schema.string("连接器名称"),
                       "method": Schema.string("HTTP 方法", options: ["GET", "POST", "PUT", "PATCH", "DELETE"]),
                       "path": Schema.string("路径，如 /v1/items"),
                       "query": Schema.freeObject("查询参数（键值对）"),
                       "body": Schema.freeObject("JSON 请求体")], required: ["connector", "path"])
    }
    let defaultRisk = ToolRisk.action
    var isAvailable: Bool { AppStore.shared.connectors.contains { $0.enabled } }

    func risk(for args: JSONValue) -> ToolRisk {
        (args.str("method") ?? "GET").uppercased() == "GET" ? .safe : .action
    }

    func summary(for args: JSONValue) -> String {
        "\((args.str("method") ?? "GET").uppercased()) \(args.str("connector") ?? "")\(args.str("path") ?? "")"
    }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let name = try args.require("connector").lowercased()
        guard let connector = context.store.connectors.first(where: { $0.enabled && $0.name.lowercased() == name }) else {
            throw ToolError("找不到连接器 \(name)")
        }
        var base = connector.baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        var path = args.str("path") ?? ""
        if !path.isEmpty && !path.hasPrefix("/") { path = "/" + path }
        guard var comps = URLComponents(string: base + path) else { throw ToolError("无效的地址") }
        if let q = args["query"]?.object, !q.isEmpty {
            comps.queryItems = (comps.queryItems ?? []) + q.map { URLQueryItem(name: $0.key, value: $0.value.string ?? $0.value.jsonString()) }
        }
        guard let url = comps.url else { throw ToolError("无效的地址") }
        var req = URLRequest(url: url)
        req.httpMethod = (args.str("method") ?? "GET").uppercased()
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in ConnectorHeaders.load(connector.id) { req.setValue(v, forHTTPHeaderField: k) }
        if let body = args["body"], req.httpMethod != "GET" {
            if let s = body.string, body.object == nil {
                req.httpBody = Data(s.utf8)
            } else {
                req.httpBody = Data(body.jsonString().utf8)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        let (data, resp) = try await HTTP.send(req)
        let text = HTTP.decodeText(data, response: resp)
        return ToolOutput(text: "HTTP \(resp.statusCode)\n\(text.truncated(15000))", isError: resp.statusCode >= 400)
    }
}
