import Foundation

/// 通用 JSON 值，用于工具参数、Schema 与 API 往返。
enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n):
            if n.isFinite, n.rounded() == n, abs(n) < 9e15 { return String(Int(n)) }
            return String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    var int: Int? {
        guard let d = double, d.isFinite, abs(d) < 9e15 else { return nil }
        return Int(d)
    }

    var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return ["true", "yes", "1"].contains(s.lowercased())
        case .number(let n): return n != 0
        default: return nil
        }
    }

    var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// 字符串数组；兼容模型把数组写成逗号分隔字符串的情况。
    var stringArray: [String]? {
        if let a = array { return a.compactMap { $0.string } }
        if let s = string {
            return s.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return nil
    }

    var intArray: [Int]? {
        if let a = array { return a.compactMap { $0.int } }
        if let s = stringArray { return s.compactMap { Int($0) } }
        return nil
    }

    /// 转为 JSONSerialization 可用的 Foundation 对象。
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map { $0.any }
        case .object(let o): return o.mapValues { $0.any }
        }
    }

    init(any value: Any) {
        if value is NSNull {
            self = .null
        } else if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        } else if let s = value as? String {
            self = .string(s)
        } else if let a = value as? [Any] {
            self = .array(a.map { JSONValue(any: $0) })
        } else if let o = value as? [String: Any] {
            self = .object(o.mapValues { JSONValue(any: $0) })
        } else {
            self = .string(String(describing: value))
        }
    }

    static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    func jsonString(pretty: Bool = false) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(self) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 取出非空字符串参数。
    func str(_ key: String) -> String? {
        guard let s = self[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    func require(_ key: String) throws -> String {
        guard let s = str(key) else { throw ToolError("缺少参数 \(key)") }
        return s
    }
}

/// 构造工具参数 JSON Schema 的小助手。
enum Schema {
    static func object(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required.map { .string($0) })
        ])
    }

    static func string(_ desc: String, options: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("string"), "description": .string(desc)]
        if let options { o["enum"] = .array(options.map { .string($0) }) }
        return .object(o)
    }

    static func integer(_ desc: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(desc)])
    }

    static func number(_ desc: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(desc)])
    }

    static func boolean(_ desc: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(desc)])
    }

    static func stringArray(_ desc: String) -> JSONValue {
        .object(["type": .string("array"), "description": .string(desc), "items": .object(["type": .string("string")])])
    }

    static func integerArray(_ desc: String) -> JSONValue {
        .object(["type": .string("array"), "description": .string(desc), "items": .object(["type": .string("integer")])])
    }

    static func freeObject(_ desc: String) -> JSONValue {
        .object(["type": .string("object"), "description": .string(desc)])
    }
}
