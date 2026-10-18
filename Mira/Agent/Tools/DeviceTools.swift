import Foundation
import EventKit
import Contacts
import UIKit
import MessageUI
import UserNotifications

// MARK: - EventKit

enum EventKitService {
    static let store = EKEventStore()

    static func requestEvents() async throws {
        let ok = try await store.requestFullAccessToEvents()
        if !ok { throw ToolError("没有日历权限，请在系统设置中允许 Mira 访问日历。") }
    }

    static func requestReminders() async throws {
        let ok = try await store.requestFullAccessToReminders()
        if !ok { throw ToolError("没有提醒事项权限，请在系统设置中允许 Mira 访问提醒事项。") }
    }

    static func fetchReminderLines(includeCompleted: Bool) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            let predicate = includeCompleted
                ? store.predicateForReminders(in: nil)
                : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate) { reminders in
                let lines = (reminders ?? []).prefix(100).map { r -> String in
                    var line = "- [\(r.calendarItemIdentifier)] \(r.isCompleted ? "✅" : "⬜️") \(r.title ?? "（无标题）")"
                    if let comps = r.dueDateComponents, let date = Calendar.current.date(from: comps) {
                        line += " ｜截止 \(DateParser.describe(date))"
                    }
                    if let list = r.calendar?.title { line += " ｜列表：\(list)" }
                    if let notes = r.notes, !notes.isEmpty { line += " ｜备注：\(notes.prefix(80))" }
                    return line
                }
                cont.resume(returning: Array(lines))
            }
        }
    }
}

struct CalendarListTool: AgentTool {
    let name = "calendar_list_events"
    let title = "查看日程"
    let icon = "calendar"
    let description = "列出日历中某个时间范围内的日程。时间格式如 2026-10-18 09:00。默认今天起 7 天。"
    var schema: JSONValue {
        Schema.object(["start": Schema.string("开始时间"), "end": Schema.string("结束时间"),
                       "query": Schema.string("可选：按标题关键词过滤")])
    }
    let defaultRisk = ToolRisk.safe

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try await EventKitService.requestEvents()
        let start = DateParser.parse(args.str("start")) ?? Calendar.current.startOfDay(for: Date())
        let end = DateParser.parse(args.str("end")) ?? start.addingTimeInterval(7 * 86400)
        let store = EventKitService.store
        var events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
        if let q = args.str("query")?.lowercased() {
            events = events.filter { ($0.title ?? "").lowercased().contains(q) }
        }
        if events.isEmpty {
            return ToolOutput(text: "\(DateParser.describe(start)) 至 \(DateParser.describe(end)) 没有日程。")
        }
        let lines = events.prefix(80).map { e -> String in
            let time = e.isAllDay ? RelativeTime.fmt("M月d日 EEEE", e.startDate) + " 全天"
                : RelativeTime.fmt("M月d日 EEEE HH:mm", e.startDate) + "–" + RelativeTime.fmt("HH:mm", e.endDate)
            var line = "- [\(e.eventIdentifier ?? "")] \(time) \(e.title ?? "（无标题）")"
            if let loc = e.location, !loc.isEmpty { line += " @\(loc)" }
            line += " ｜\(e.calendar.title)"
            return line
        }
        return ToolOutput(text: lines.joined(separator: "\n"))
    }
}

struct CalendarCreateTool: AgentTool {
    let name = "calendar_create_event"
    let title = "创建日程"
    let icon = "calendar.badge.plus"
    let description = "在用户日历中创建日程。时间格式如 2026-10-18 14:00。"
    var schema: JSONValue {
        Schema.object([
            "title": Schema.string("标题"),
            "start": Schema.string("开始时间"),
            "end": Schema.string("结束时间，默认开始后 1 小时"),
            "all_day": Schema.boolean("是否全天"),
            "location": Schema.string("地点"),
            "notes": Schema.string("备注"),
            "alert_minutes": Schema.integer("提前多少分钟提醒")
        ], required: ["title", "start"])
    }
    let defaultRisk = ToolRisk.action

    func summary(for args: JSONValue) -> String {
        let time = DateParser.parse(args.str("start")).map { DateParser.describe($0) } ?? args.str("start") ?? ""
        return "创建日程「\(args.str("title") ?? "")」\(time)"
    }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try await EventKitService.requestEvents()
        let title = try args.require("title")
        guard let start = DateParser.parse(args.str("start")) else { throw ToolError("无法解析开始时间") }
        let allDay = args["all_day"]?.bool ?? false
        let end = DateParser.parse(args.str("end")) ?? start.addingTimeInterval(allDay ? 86400 : 3600)
        let store = EventKitService.store
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = max(end, start.addingTimeInterval(60))
        event.isAllDay = allDay
        event.location = args.str("location")
        event.notes = args.str("notes")
        event.calendar = store.defaultCalendarForNewEvents
        if let minutes = args["alert_minutes"]?.int {
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60)))
        }
        try store.save(event, span: .thisEvent, commit: true)
        return ToolOutput(text: "已创建日程「\(title)」：\(DateParser.describe(start))，ID：\(event.eventIdentifier ?? "")")
    }
}

struct CalendarDeleteTool: AgentTool {
    let name = "calendar_delete_event"
    let title = "删除日程"
    let icon = "calendar.badge.minus"
    let description = "根据日程 ID（来自 calendar_list_events）删除日程。"
    var schema: JSONValue { Schema.object(["event_id": Schema.string("日程 ID")], required: ["event_id"]) }
    let defaultRisk = ToolRisk.sensitive

    func summary(for args: JSONValue) -> String {
        if let id = args.str("event_id"), let e = EventKitService.store.event(withIdentifier: id) {
            return "删除日程「\(e.title ?? "")」"
        }
        return "删除日程"
    }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try await EventKitService.requestEvents()
        let id = try args.require("event_id")
        guard let event = EventKitService.store.event(withIdentifier: id) else { throw ToolError("找不到这个日程") }
        let title = event.title ?? ""
        try EventKitService.store.remove(event, span: .thisEvent, commit: true)
        return ToolOutput(text: "已删除日程「\(title)」")
    }
}

struct RemindersListTool: AgentTool {
    let name = "reminders_list"
    let title = "查看提醒事项"
    let icon = "checklist"
    let description = "列出提醒事项（默认只列未完成的）。"
    var schema: JSONValue { Schema.object(["include_completed": Schema.boolean("是否包含已完成")]) }
    let defaultRisk = ToolRisk.safe

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try await EventKitService.requestReminders()
        let lines = await EventKitService.fetchReminderLines(includeCompleted: args["include_completed"]?.bool ?? false)
        return ToolOutput(text: lines.isEmpty ? "没有提醒事项。" : lines.joined(separator: "\n"))
    }
}

struct RemindersCreateTool: AgentTool {
    let name = "reminders_create"
    let title = "添加提醒事项"
    let icon = "plus.circle"
    let description = "在系统「提醒事项」中添加一条待办，可设置截止时间（到时会提醒）。"
    var schema: JSONValue {
        Schema.object(["title": Schema.string("标题"),
                       "due": Schema.string("截止/提醒时间，如 2026-10-18 18:00"),
                       "notes": Schema.string("备注"),
                       "priority": Schema.integer("优先级 1(高) 5(中) 9(低)")], required: ["title"])
    }
    let defaultRisk = ToolRisk.action

    func summary(for args: JSONValue) -> String { "添加提醒「\(args.str("title") ?? "")」" }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try await EventKitService.requestReminders()
        let store = EventKitService.store
        let reminder = EKReminder(eventStore: store)
        reminder.title = try args.require("title")
        reminder.notes = args.str("notes")
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let p = args["priority"]?.int { reminder.priority = p }
        if let due = DateParser.parse(args.str("due")) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return ToolOutput(text: "已添加提醒「\(reminder.title ?? "")」，ID：\(reminder.calendarItemIdentifier)")
    }
}

struct RemindersCompleteTool: AgentTool {
    let name = "reminders_complete"
    let title = "完成提醒事项"
    let icon = "checkmark.circle"
    let description = "把提醒事项标记为已完成（ID 来自 reminders_list）。"
    var schema: JSONValue { Schema.object(["reminder_id": Schema.string("提醒事项 ID")], required: ["reminder_id"]) }
    let defaultRisk = ToolRisk.action

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try await EventKitService.requestReminders()
        let id = try args.require("reminder_id")
        guard let item = EventKitService.store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ToolError("找不到这个提醒事项")
        }
        item.isCompleted = true
        try EventKitService.store.save(item, commit: true)
        return ToolOutput(text: "已完成「\(item.title ?? "")」")
    }
}

// MARK: - 通讯录

struct ContactsSearchTool: AgentTool {
    let name = "contacts_search"
    let title = "查找联系人"
    let icon = "person.crop.circle"
    let description = "按姓名在通讯录中查找联系人，返回电话和邮箱。"
    var schema: JSONValue { Schema.object(["query": Schema.string("姓名关键字")], required: ["query"]) }
    let defaultRisk = ToolRisk.sensitive

    func summary(for args: JSONValue) -> String { "查找联系人「\(args.str("query") ?? "")」" }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let query = try args.require("query")
        let store = CNContactStore()
        let granted = try await store.requestAccess(for: .contacts)
        guard granted else { throw ToolError("没有通讯录权限") }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                    CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let contacts = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)
        if contacts.isEmpty { return ToolOutput(text: "没有找到「\(query)」。") }
        let lines = contacts.prefix(20).map { c -> String in
            let name = (c.familyName + c.givenName).isEmpty ? c.organizationName : c.familyName + c.givenName
            let phones = c.phoneNumbers.map { $0.value.stringValue }.joined(separator: ", ")
            let emails = c.emailAddresses.map { $0.value as String }.joined(separator: ", ")
            return "- \(name)｜电话：\(phones.isEmpty ? "无" : phones)｜邮箱：\(emails.isEmpty ? "无" : emails)"
        }
        return ToolOutput(text: lines.joined(separator: "\n"))
    }
}

// MARK: - 邮件 / 短信

@MainActor
final class ComposerService: NSObject, MFMailComposeViewControllerDelegate, MFMessageComposeViewControllerDelegate {
    static let shared = ComposerService()
    private var mailCont: CheckedContinuation<String, Never>?
    private var messageCont: CheckedContinuation<String, Never>?

    func composeMail(to: [String], cc: [String], subject: String, body: String, isHTML: Bool) async -> String {
        guard MFMailComposeViewController.canSendMail() else {
            var comps = URLComponents()
            comps.scheme = "mailto"
            comps.path = to.joined(separator: ",")
            var items = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
            if !cc.isEmpty { items.append(URLQueryItem(name: "cc", value: cc.joined(separator: ","))) }
            comps.queryItems = items
            if let url = comps.url, await UIApplication.shared.open(url) {
                return "设备未配置系统邮件账户，已在默认邮件 App 中打开草稿，等待用户手动发送。"
            }
            return "无法发送邮件：设备上没有可用的邮件 App。"
        }
        guard let top = UIApplication.topViewController() else { return "无法显示邮件编辑器" }
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = self
        vc.setToRecipients(to)
        vc.setCcRecipients(cc)
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: isHTML)
        return await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            mailCont = c
            top.present(vc, animated: true)
        }
    }

    func composeMessage(recipients: [String], body: String) async -> String {
        guard MFMessageComposeViewController.canSendText() else { return "此设备无法发送短信/iMessage。" }
        guard let top = UIApplication.topViewController() else { return "无法显示信息编辑器" }
        let vc = MFMessageComposeViewController()
        vc.messageComposeDelegate = self
        vc.recipients = recipients
        vc.body = body
        return await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            messageCont = c
            top.present(vc, animated: true)
        }
    }

    nonisolated func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        let text: String
        switch result {
        case .sent: text = "邮件已发送。"
        case .saved: text = "用户把邮件存为了草稿，尚未发送。"
        case .cancelled: text = "用户取消了发送。"
        case .failed: text = "邮件发送失败：\(error?.localizedDescription ?? "未知错误")"
        @unknown default: text = "邮件编辑器已关闭。"
        }
        Task { @MainActor in
            controller.dismiss(animated: true)
            self.mailCont?.resume(returning: text)
            self.mailCont = nil
        }
    }

    nonisolated func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        let text: String
        switch result {
        case .sent: text = "信息已发送。"
        case .cancelled: text = "用户取消了发送。"
        case .failed: text = "信息发送失败。"
        @unknown default: text = "信息编辑器已关闭。"
        }
        Task { @MainActor in
            controller.dismiss(animated: true)
            self.messageCont?.resume(returning: text)
            self.messageCont = nil
        }
    }
}

struct SendEmailTool: AgentTool {
    let name = "send_email"
    let title = "发送邮件"
    let icon = "envelope"
    let description = "起草并发送邮件。会弹出系统邮件编辑器，用户确认后发送。"
    var schema: JSONValue {
        Schema.object(["to": Schema.stringArray("收件人邮箱"),
                       "cc": Schema.stringArray("抄送"),
                       "subject": Schema.string("主题"),
                       "body": Schema.string("正文"),
                       "is_html": Schema.boolean("正文是否为 HTML")], required: ["to", "subject", "body"])
    }
    let defaultRisk = ToolRisk.sensitive

    func summary(for args: JSONValue) -> String {
        "给 \((args["to"]?.stringArray ?? []).joined(separator: ", ")) 发邮件：\(args.str("subject") ?? "")"
    }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let to = args["to"]?.stringArray ?? []
        guard !to.isEmpty else { throw ToolError("缺少收件人") }
        let result = await ComposerService.shared.composeMail(
            to: to, cc: args["cc"]?.stringArray ?? [], subject: args.str("subject") ?? "",
            body: args["body"]?.string ?? "", isHTML: args["is_html"]?.bool ?? false)
        return ToolOutput(text: result)
    }
}

struct SendMessageTool: AgentTool {
    let name = "send_message"
    let title = "发送信息"
    let icon = "message"
    let description = "通过系统信息 App 发送短信或 iMessage（会弹出编辑器，用户确认后发送）。"
    var schema: JSONValue {
        Schema.object(["recipients": Schema.stringArray("手机号或 Apple ID"),
                       "body": Schema.string("内容")], required: ["recipients", "body"])
    }
    let defaultRisk = ToolRisk.sensitive

    func summary(for args: JSONValue) -> String {
        "给 \((args["recipients"]?.stringArray ?? []).joined(separator: ", ")) 发信息"
    }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let result = await ComposerService.shared.composeMessage(
            recipients: args["recipients"]?.stringArray ?? [], body: args["body"]?.string ?? "")
        return ToolOutput(text: result)
    }
}

// MARK: - 通知 / 剪贴板 / 链接

struct NotificationTool: AgentTool {
    let name = "schedule_notification"
    let title = "定时通知"
    let icon = "bell.badge"
    let description = "在指定时间（或若干分钟后）给用户推送一条本地通知，适合简单的提醒。"
    var schema: JSONValue {
        Schema.object(["title": Schema.string("通知标题"), "body": Schema.string("通知内容"),
                       "at": Schema.string("时间，如 2026-10-18 18:00"),
                       "minutes_from_now": Schema.integer("多少分钟后")], required: ["title"])
    }
    let defaultRisk = ToolRisk.safe

    func summary(for args: JSONValue) -> String { "定时通知「\(args.str("title") ?? "")」" }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let title = try args.require("title")
        let date: Date
        if let at = DateParser.parse(args.str("at")) {
            date = at
        } else if let m = args["minutes_from_now"]?.int {
            date = Date().addingTimeInterval(TimeInterval(max(m, 1) * 60))
        } else {
            throw ToolError("需要提供 at 或 minutes_from_now")
        }
        guard date > Date() else { throw ToolError("时间已经过去了") }
        try await NotificationService.schedule(title: title, body: args.str("body") ?? "", at: date,
                                               conversationID: context.conversationID)
        return ToolOutput(text: "已设定通知：\(DateParser.describe(date))「\(title)」")
    }
}

struct ClipboardReadTool: AgentTool {
    let name = "clipboard_read"
    let title = "读取剪贴板"
    let icon = "doc.on.clipboard"
    let description = "读取剪贴板中的文本。"
    var schema: JSONValue { Schema.object([:]) }
    let defaultRisk = ToolRisk.sensitive

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        ToolOutput(text: UIPasteboard.general.string.map { $0.truncated(20000) } ?? "剪贴板中没有文本。")
    }
}

struct ClipboardWriteTool: AgentTool {
    let name = "clipboard_write"
    let title = "拷贝到剪贴板"
    let icon = "doc.on.doc"
    let description = "把文本拷贝到剪贴板，方便用户粘贴。"
    var schema: JSONValue { Schema.object(["text": Schema.string("要拷贝的文本")], required: ["text"]) }
    let defaultRisk = ToolRisk.safe

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        UIPasteboard.general.string = args["text"]?.string ?? ""
        return ToolOutput(text: "已拷贝到剪贴板。")
    }
}

struct OpenURLTool: AgentTool {
    let name = "open_url"
    let title = "打开链接"
    let icon = "arrow.up.forward.app"
    let description = "在 Safari 或对应 App 中打开链接（支持 https、tel:、maps:、URL Scheme 等）。"
    var schema: JSONValue { Schema.object(["url": Schema.string("链接")], required: ["url"]) }
    let defaultRisk = ToolRisk.action

    func summary(for args: JSONValue) -> String { "打开 \(args.str("url") ?? "")" }

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        guard let url = URL(string: try args.require("url")) else { throw ToolError("无效的链接") }
        let ok = await UIApplication.shared.open(url)
        return ToolOutput(text: ok ? "已打开 \(url.absoluteString)" : "无法打开这个链接", isError: !ok)
    }
}
