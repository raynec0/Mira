import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: AgentEngine
    @State private var selected: AuditEntry?
    @State private var confirmClear = false

    private struct DayGroup: Identifiable {
        let id: Date
        let title: String
        let entries: [AuditEntry]
    }

    private var groups: [DayGroup] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: store.audit) { cal.startOfDay(for: $0.date) }
        return dict.keys.sorted(by: >).map { day in
            DayGroup(id: day, title: RelativeTime.dayTitle(day), entries: dict[day] ?? [])
        }
    }

    private var todayCount: Int {
        store.audit.filter { Calendar.current.isDateInToday($0.date) }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        StatTile(value: "\(engine.running.count)", label: "运行中", icon: "bolt.fill", color: .blue)
                        StatTile(value: "\(engine.pendingApprovals)", label: "待批准", icon: "hand.raised.fill", color: .orange)
                        StatTile(value: "\(todayCount)", label: "今日操作", icon: "checkmark.seal.fill", color: .green)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    if let next = RoutineScheduler.shared.nextRunText() {
                        Label("下一个例程：\(next)", systemImage: "alarm")
                            .font(.subheadline)
                    }
                    if !engine.running.isEmpty {
                        ForEach(Array(engine.running), id: \.self) { id in
                            if let conv = store.conversation(id) {
                                Button {
                                    store.selectedTab = .messages
                                    store.openConversationRequest = id
                                } label: {
                                    HStack {
                                        AgentAvatar(agent: store.agent(for: conv.agentID), size: 28)
                                        Text(conv.title.isEmpty ? store.agent(for: conv.agentID).name : conv.title)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        ProgressView()
                                    }
                                }
                            }
                        }
                    }
                }

                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.entries) { e in
                            Button { selected = e } label: { AuditRow(entry: e) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if store.audit.isEmpty {
                    ContentUnavailableView("还没有动态", systemImage: "waveform.path.ecg",
                                           description: Text("智能体每次使用工具都会记录在这里，方便你审查它做了什么。"))
                        .padding(.top, 120)
                }
            }
            .navigationTitle("动态")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) { confirmClear = true } label: { Label("清空记录", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("清空全部操作记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) { store.audit.removeAll() }
            }
            .sheet(item: $selected) { e in AuditDetailView(entry: e) }
        }
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(color))
            Text(value).font(.title2.weight(.bold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}

struct AuditRow: View {
    let entry: AuditEntry

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemName: ToolRegistry.icon(for: entry.toolName), color: entry.status.color == .secondary ? .gray : entry.status.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.summary).font(.subheadline).lineLimit(2)
                Text("\(entry.agentName) · \(entry.status.title) · \(RelativeTime.fmt("HH:mm", entry.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

struct AuditDetailView: View {
    let entry: AuditEntry
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("工具", value: entry.toolTitle)
                    LabeledContent("智能体", value: entry.agentName)
                    LabeledContent("状态") { Text(entry.status.title).foregroundStyle(entry.status.color) }
                    LabeledContent("时间", value: RelativeTime.chatHeader(entry.date))
                }
                Section("摘要") { Text(entry.summary) }
                Section("参数") {
                    Text(JSONValue.parse(entry.arguments)?.jsonString(pretty: true) ?? entry.arguments)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Section("结果") {
                    Text(entry.result.isEmpty ? "（无）" : entry.result)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let cid = entry.conversationID, store.conversation(cid) != nil {
                    Section {
                        Button {
                            dismiss()
                            store.selectedTab = .messages
                            store.openConversationRequest = cid
                        } label: {
                            Label("打开对话", systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                }
            }
            .navigationTitle("操作详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
