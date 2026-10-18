import Foundation
import SwiftUI
import UIKit
import Security
import PDFKit

// MARK: - Keychain

enum Keychain {
    private static let service = "com.raynec.mira"

    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    static func set(_ value: String, for key: String) {
        SecItemDelete(base(key) as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base(key)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - 颜色

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    static let iMessageBlue = Color(red: 0, green: 0.478, blue: 1)

    static let agentBubble = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.15, green: 0.15, blue: 0.16, alpha: 1)
            : UIColor(red: 0.914, green: 0.914, blue: 0.922, alpha: 1)
    })
}

// MARK: - 时间

enum RelativeTime {
    static func fmt(_ format: String, _ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = format
        return df.string(from: date)
    }

    private static func daysAgo(_ date: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 99
    }

    static func listString(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return fmt("HH:mm", date) }
        if cal.isDateInYesterday(date) { return "昨天" }
        if daysAgo(date) < 7 { return fmt("EEEE", date) }
        return fmt("yy/M/d", date)
    }

    static func chatHeader(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天 " + fmt("HH:mm", date) }
        if cal.isDateInYesterday(date) { return "昨天 " + fmt("HH:mm", date) }
        if daysAgo(date) < 7 { return fmt("EEEE HH:mm", date) }
        return fmt("M月d日 HH:mm", date)
    }

    static func dayTitle(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        return fmt("M月d日 EEEE", date)
    }
}

enum DateParser {
    static func parse(_ text: String?) -> Date? {
        guard let s = text?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let formats = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss",
                       "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd"]
        for f in formats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = .current
            df.dateFormat = f
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    static func describe(_ date: Date) -> String {
        RelativeTime.fmt("yyyy-MM-dd HH:mm EEEE", date)
    }
}

// MARK: - 文本 / HTML

extension String {
    /// 正则匹配，返回每个匹配的所有捕获组。
    func regexMatches(_ pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = self as NSString
        return re.matches(in: self, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    func truncated(_ max: Int) -> String {
        count > max ? String(prefix(max)) + "\n…（已截断，共 \(count) 字符）" : self
    }

    var plainPreview: String {
        var s = self
        for token in ["**", "__", "`", "###", "##", "#", "> "] { s = s.replacingOccurrences(of: token, with: "") }
        return s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

enum HTMLText {
    static func strip(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg", "head", "template"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</li>|</h[1-6]>|</tr>|</section>|</article>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "[ \\t\\u00A0]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " *\\n[ \\n]*", with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ input: String) -> String {
        var s = input
        let map = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                   "&apos;": "'", "&#x27;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&middot;": "·"]
        for (k, v) in map { s = s.replacingOccurrences(of: k, with: v) }
        for m in s.regexMatches("&#(x?[0-9a-fA-F]+);") {
            let code = m[1]
            let value = code.hasPrefix("x") || code.hasPrefix("X") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            if let value, let scalar = Unicode.Scalar(value) {
                s = s.replacingOccurrences(of: m[0], with: String(Character(scalar)))
            }
        }
        return s
    }

    static func title(_ html: String) -> String? {
        guard let t = html.regexMatches("<title[^>]*>(.*?)</title>").first?[1] else { return nil }
        let clean = decodeEntities(t).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

// MARK: - HTTP

enum HTTP {
    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 300
        return URLSession(configuration: c)
    }()

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = request
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ToolError("无效的网络响应") }
        return (data, http)
    }

    static func get(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return try await send(req)
    }

    /// 根据 Content-Type / meta charset 解码文本（支持 GBK/GB18030）。
    static func decodeText(_ data: Data, response: HTTPURLResponse?) -> String {
        let contentType = (response?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let head = String(decoding: data.prefix(3000), as: UTF8.self).lowercased()
        let isGB = contentType.contains("gb2312") || contentType.contains("gbk") || contentType.contains("gb18030")
            || head.contains("charset=gb") || head.contains("charset=\"gb")
        if isGB {
            let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            if let s = String(data: data, encoding: enc) { return s }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}

// MARK: - 文件文本提取

enum FileText {
    static func extract(url: URL, mime: String) -> String? {
        if mime == "application/pdf" || url.pathExtension.lowercased() == "pdf" {
            return PDFDocument(url: url)?.string
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        return nil
    }
}

// MARK: - 图片

enum ImageUtil {
    static func jpeg(_ data: Data, maxDimension: CGFloat = 1600) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let longest = max(img.size.width, img.size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
        return out.jpegData(compressionQuality: 0.82)
    }
}

// MARK: - UIKit

extension UIApplication {
    @MainActor
    static func topViewController() -> UIViewController? {
        let scenes = shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

@MainActor
enum Haptics {
    static func tap() {
        guard AppStore.shared.settings.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard AppStore.shared.settings.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}

// MARK: - 快捷指令展开

enum ShortcutExpander {
    static func expand(_ text: String, shortcuts: [PromptShortcut]) -> String {
        guard text.hasPrefix("/") else { return text }
        let body = text.dropFirst()
        let name = String(body.prefix { !$0.isWhitespace })
        guard let s = shortcuts.first(where: { $0.name == name }) else { return text }
        let rest = String(body.dropFirst(name.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.prompt.contains("{{input}}") {
            return s.prompt.replacingOccurrences(of: "{{input}}", with: rest)
        }
        return rest.isEmpty ? s.prompt : s.prompt + "\n\n" + rest
    }
}
