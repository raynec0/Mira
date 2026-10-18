import Foundation
import PDFKit
import CoreLocation

struct SearchResult {
    var title: String
    var url: String
    var snippet: String
}

enum WebSearch {
    static func tavily(_ query: String, key: String, max: Int) async throws -> [SearchResult] {
        var req = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "api_key": key, "query": query, "max_results": max, "search_depth": "basic"
        ] as [String: Any])
        let (data, resp) = try await HTTP.send(req)
        guard resp.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else {
            throw ToolError("Tavily 搜索失败（HTTP \(resp.statusCode)）")
        }
        return results.map {
            SearchResult(title: ($0["title"] as? String) ?? "",
                         url: ($0["url"] as? String) ?? "",
                         snippet: String((($0["content"] as? String) ?? "").prefix(400)))
        }
    }

    static func duckDuckGo(_ query: String, max: Int) async throws -> [SearchResult] {
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        let (data, resp) = try await HTTP.get(comps.url!)
        let html = HTTP.decodeText(data, response: resp)
        let links = html.regexMatches("<a[^>]+class=\"result__a\"[^>]+href=\"([^\"]+)\"[^>]*>(.*?)</a>")
        let snippets = html.regexMatches("class=\"result__snippet\"[^>]*>(.*?)</a>")
        var results: [SearchResult] = []
        for (i, link) in links.enumerated() where results.count < max {
            var href = HTMLText.decodeEntities(link[1])
            if let r = href.range(of: "uddg=") {
                let encoded = String(href[r.upperBound...].split(separator: "&").first ?? "")
                href = encoded.removingPercentEncoding ?? encoded
            }
            if href.hasPrefix("//") { href = "https:" + href }
            if href.contains("duckduckgo.com/y.js") { continue }
            let snippet = i < snippets.count ? HTMLText.strip(snippets[i][1]) : ""
            results.append(SearchResult(title: HTMLText.strip(link[2]), url: href, snippet: snippet))
        }
        return results
    }

    static func bing(_ query: String, max: Int) async throws -> [SearchResult] {
        var comps = URLComponents(string: "https://www.bing.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "setlang", value: "zh-Hans")]
        let (data, resp) = try await HTTP.get(comps.url!)
        let html = HTTP.decodeText(data, response: resp)
        var results: [SearchResult] = []
        for block in html.regexMatches("<li class=\"b_algo\"(.*?)</li>") where results.count < max {
            let body = block[1]
            guard let a = body.regexMatches("<h2[^>]*>\\s*<a[^>]+href=\"([^\"]+)\"[^>]*>(.*?)</a>").first else { continue }
            let p = body.regexMatches("<p[^>]*>(.*?)</p>").first?[1] ?? ""
            results.append(SearchResult(title: HTMLText.strip(a[2]), url: HTMLText.decodeEntities(a[1]), snippet: HTMLText.strip(p)))
        }
        return results
    }
}

struct WebSearchTool: AgentTool {
    let name = "web_search"
    let title = "搜索网页"
    let icon = "magnifyingglass"
    let description = "在互联网上搜索信息，返回标题、链接与摘要。需要事实、新闻、价格、时效信息时使用；需要细节时再用 fetch_url 阅读具体网页。"
    var schema: JSONValue {
        Schema.object(["query": Schema.string("搜索关键词"),
                       "max_results": Schema.integer("返回结果数，默认 6，最多 10")], required: ["query"])
    }
    let defaultRisk = ToolRisk.safe

    func summary(for args: JSONValue) -> String { "搜索「\(args.str("query") ?? "")」" }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let query = try args.require("query")
        let n = min(max(args["max_results"]?.int ?? 6, 1), 10)
        var results: [SearchResult] = []
        let tavily = Keychain.get(KeyName.tavily)
        if !tavily.isEmpty { results = (try? await WebSearch.tavily(query, key: tavily, max: n)) ?? [] }
        if results.isEmpty { results = (try? await WebSearch.duckDuckGo(query, max: n)) ?? [] }
        if results.isEmpty { results = (try? await WebSearch.bing(query, max: n)) ?? [] }
        guard !results.isEmpty else {
            return ToolOutput(text: "没有搜到结果。搜索服务可能暂时不可用，可在设置中配置 Tavily Key。", isError: true)
        }
        let text = results.enumerated().map { i, r in
            "\(i + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)"
        }.joined(separator: "\n")
        return ToolOutput(text: text)
    }
}

struct FetchURLTool: AgentTool {
    let name = "fetch_url"
    let title = "阅读网页"
    let icon = "safari"
    let description = "抓取一个网页（或 JSON / 文本 / PDF）并返回正文文本。"
    var schema: JSONValue {
        Schema.object(["url": Schema.string("完整的 http(s) 链接"),
                       "max_chars": Schema.integer("最多返回的字符数，默认 10000")], required: ["url"])
    }
    let defaultRisk = ToolRisk.safe

    func summary(for args: JSONValue) -> String {
        let url = args.str("url") ?? ""
        return "阅读 \(URL(string: url)?.host ?? url)"
    }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let raw = try args.require("url")
        guard let url = URL(string: raw.hasPrefix("http") ? raw : "https://" + raw) else { throw ToolError("无效的链接") }
        let maxChars = min(max(args["max_chars"]?.int ?? 10000, 500), 40000)
        let (data, resp) = try await HTTP.get(url)
        guard (200..<400).contains(resp.statusCode) else { throw ToolError("HTTP \(resp.statusCode)") }
        let type = (resp.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        var output: String
        if type.contains("pdf") || url.pathExtension.lowercased() == "pdf" {
            output = PDFDocument(data: data)?.string ?? "（无法解析 PDF）"
        } else if type.contains("json") || type.contains("text/plain") || type.contains("xml") || type.contains("csv") {
            output = HTTP.decodeText(data, response: resp)
        } else if type.contains("image") {
            output = "（这是一张图片，无法提取文字）"
        } else {
            let html = HTTP.decodeText(data, response: resp)
            let title = HTMLText.title(html).map { "标题：\($0)\n\n" } ?? ""
            output = title + HTMLText.strip(html)
        }
        return ToolOutput(text: "来源：\(url.absoluteString)\n\n" + output.truncated(maxChars))
    }
}

struct DateTimeTool: AgentTool {
    let name = "get_current_datetime"
    let title = "查看时间"
    let icon = "clock"
    let description = "获取当前精确的日期、时间、星期和时区。"
    var schema: JSONValue { Schema.object([:]) }
    let defaultRisk = ToolRisk.safe

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        return ToolOutput(text: "\(RelativeTime.fmt("yyyy年M月d日 EEEE HH:mm:ss", now))\nISO：\(iso.string(from: now))\n时区：\(TimeZone.current.identifier)")
    }
}

struct LocationTool: AgentTool {
    let name = "get_current_location"
    let title = "获取位置"
    let icon = "location"
    let description = "获取用户当前的大致位置（经纬度与地名）。"
    var schema: JSONValue { Schema.object([:]) }
    let defaultRisk = ToolRisk.sensitive

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let loc = try await LocationService.shared.current()
        let name = await LocationService.shared.placeName(for: loc)
        return ToolOutput(text: "位置：\(name)\n纬度：\(loc.coordinate.latitude)\n经度：\(loc.coordinate.longitude)")
    }
}

struct WeatherTool: AgentTool {
    let name = "get_weather"
    let title = "查询天气"
    let icon = "cloud.sun"
    let description = "查询天气（当前与未来几天）。可以给城市名，或经纬度；都不给时使用用户当前位置。"
    var schema: JSONValue {
        Schema.object(["city": Schema.string("城市名，如“深圳”"),
                       "latitude": Schema.number("纬度"),
                       "longitude": Schema.number("经度"),
                       "days": Schema.integer("预报天数，默认 3，最多 7")])
    }
    let defaultRisk = ToolRisk.safe

    func summary(for args: JSONValue) -> String { "查询\(args.str("city") ?? "当前位置")的天气" }

    private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "晴"
        case 1: return "大致晴朗"
        case 2: return "局部多云"
        case 3: return "阴"
        case 45, 48: return "雾"
        case 51, 53, 55: return "毛毛雨"
        case 56, 57: return "冻毛毛雨"
        case 61: return "小雨"
        case 63: return "中雨"
        case 65: return "大雨"
        case 66, 67: return "冻雨"
        case 71: return "小雪"
        case 73: return "中雪"
        case 75: return "大雪"
        case 77: return "雪粒"
        case 80, 81, 82: return "阵雨"
        case 85, 86: return "阵雪"
        case 95: return "雷暴"
        case 96, 99: return "雷暴伴冰雹"
        default: return "未知(\(code))"
        }
    }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        var lat = args["latitude"]?.double
        var lon = args["longitude"]?.double
        var place = ""
        if let city = args.str("city") {
            var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
            c.queryItems = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1"),
                            URLQueryItem(name: "language", value: "zh")]
            let (data, _) = try await HTTP.get(c.url!)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let r = (obj["results"] as? [[String: Any]])?.first else { throw ToolError("找不到城市：\(city)") }
            lat = num(r["latitude"])
            lon = num(r["longitude"])
            place = [r["name"] as? String, r["admin1"] as? String, r["country"] as? String]
                .compactMap { $0 }.joined(separator: "，")
        }
        if lat == nil || lon == nil {
            let loc = try await LocationService.shared.current()
            lat = loc.coordinate.latitude
            lon = loc.coordinate.longitude
            place = await LocationService.shared.placeName(for: loc)
        }
        guard let latitude = lat, let longitude = lon else { throw ToolError("无法确定位置") }
        let days = min(max(args["days"]?.int ?? 3, 1), 7)
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(days))
        ]
        let (data, _) = try await HTTP.get(c.url!)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ToolError("天气数据解析失败") }
        var lines = ["地点：\(place.isEmpty ? "\(latitude), \(longitude)" : place)"]
        if let cur = obj["current"] as? [String: Any] {
            let code = Int(num(cur["weather_code"]) ?? -1)
            lines.append("现在：\(Self.describe(code))，\(num(cur["temperature_2m"]) ?? 0)°C（体感 \(num(cur["apparent_temperature"]) ?? 0)°C），湿度 \(Int(num(cur["relative_humidity_2m"]) ?? 0))%，风速 \(num(cur["wind_speed_10m"]) ?? 0) km/h")
        }
        if let daily = obj["daily"] as? [String: Any], let times = daily["time"] as? [String] {
            let codes = daily["weather_code"] as? [Any] ?? []
            let maxs = daily["temperature_2m_max"] as? [Any] ?? []
            let mins = daily["temperature_2m_min"] as? [Any] ?? []
            let rain = daily["precipitation_probability_max"] as? [Any] ?? []
            for (i, day) in times.enumerated() {
                let code = i < codes.count ? Int(num(codes[i]) ?? -1) : -1
                let hi = i < maxs.count ? num(maxs[i]) ?? 0 : 0
                let lo = i < mins.count ? num(mins[i]) ?? 0 : 0
                let p = i < rain.count ? Int(num(rain[i]) ?? 0) : 0
                lines.append("\(day)：\(Self.describe(code))，\(lo)~\(hi)°C，降水概率 \(p)%")
            }
        }
        return ToolOutput(text: lines.joined(separator: "\n"))
    }
}

// MARK: - 定位服务

@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    private let manager = CLLocationManager()
    private var locationCont: CheckedContinuation<CLLocation, Error>?
    private var authCont: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func current() async throws -> CLLocation {
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                authCont = c
                manager.requestWhenInUseAuthorization()
            }
        }
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            throw ToolError("没有定位权限，请在「设置 › 隐私 › 定位服务」中允许 Mira 使用位置。")
        }
        if let recent = manager.location, Date().timeIntervalSince(recent.timestamp) < 120 { return recent }
        guard locationCont == nil else { throw ToolError("正在定位中，请稍后再试") }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<CLLocation, Error>) in
            locationCont = c
            manager.requestLocation()
        }
    }

    func placeName(for location: CLLocation) async -> String {
        guard let marks = try? await CLGeocoder().reverseGeocodeLocation(location), let p = marks.first else {
            return String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude)
        }
        let parts = [p.administrativeArea, p.locality, p.subLocality, p.name].compactMap { $0 }
        var unique: [String] = []
        for part in parts where !unique.contains(part) { unique.append(part) }
        return unique.joined(separator: " ")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status != .notDetermined {
                self.authCont?.resume()
                self.authCont = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.locationCont?.resume(returning: loc)
            self.locationCont = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.locationCont?.resume(throwing: error)
            self.locationCont = nil
        }
    }
}
