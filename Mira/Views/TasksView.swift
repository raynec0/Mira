import SwiftUI

struct TasksView: View {
    @EnvironmentObject private var store: AppStore
    @State private var segment = 0
    @State private var creatingTask = false
    @State private var editingRoutine: Routine?

    var body: some View {
        NavigationStack {
            Group {
                if segment == 0 { taskList } else { RoutineListView(editing: $editingRoutine) }
            }
            .navigationTitle(segment == 0 ? "任务" : "例程")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $segment) {
                        Text("任务").tag(0)
                        Text("例程").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if segment == 0 {
                            creatingTask = true
                        } else if let agent = store.agents.first {
                            var r = Routine(title: "", prompt: "", agentID: agent.id)
                            r.lastRun = Date()
                            editingRoutine = r
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in TaskDetailView(taskID: id) }
            .sheet(isPresented: $creatingTask) { NewTaskSheet() }
            .sheet(item: $editingRoutine) { r in
                NavigationStack { RoutineEditorView(routine: r) }
            }
        }
    }

    private var taskList: some View {
        List {
            ForEach(TaskStatus.allCases) { status in
                let items = store.tasks.filter { $0.status == status }.sorted { $0.updatedAt > $1.updatedAt }
                if !items.isEmpty {
                    Section(status.title) {
                        ForEach(items) { t in
                            NavigationLink(value: t.id) { TaskRow(task: t) }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { store.deleteTask(t.id) } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                    if t.status != .done {
                                        Button { store.setTaskStatus(t.id, .done) } label: {
                                            Label("完成", systemImage: "checkmark")
                                        }
                                        .tint(.green)
                                    }
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if store.tasks.isEmpty {
                ContentUnavailableView("还没有任务", systemImage: "checklist",
                                       description: Text("把一个目标交给智能体，它会拆成步骤、建立任务并持续推进。"))
            }
        }
    }
}

struct TaskRow: View {
    let task: AgentTaskItem

    var body: some View {
        HStack(spacing: 12) {
            ProgressRing(progress: task.progress, color: task.status.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(task.progressText)
                    if let due = task.dueDate {
                        Text("·")
                        Text("截止 \(RelativeTime.listString(due))")
                            .foregroundStyle(due < Date() && task.status != .done ? Color.red : Color.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct TaskDetailView: View {
    let taskID: UUID
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: AgentEngine
    @Environment(\.dismiss) private var dismiss
    @State private var newStep = ""

    private var binding: Binding<AgentTaskItem>? {
        guard let current = store.tasks.first(where: { $0.id == taskID }) else { return nil }
        return Binding(
            get: { store.tasks.first(where: { $0.id == taskID }) ?? current },
            set: { value in
                if let i = store.tasks.firstIndex(where: { $0.id == taskID }) {
                    var v = value
                    v.updatedAt = Date()
                    store.tasks[i] = v
                }
            })
    }

    var body: some View {
        if let task = binding {
            form(task)
        } else {
            ContentUnavailableView("任务已删除", systemImage: "trash")
        }
    }

    private func form(_ task: Binding<AgentTaskItem>) -> some View {
        Form {
            Section {
                TextField("标题", text: task.title, axis: .vertical).font(.headline)
                TextField("说明", text: task.detail, axis: .vertical).lineLimit(2...8)
                Picker("状态", selection: task.status) {
                    ForEach(TaskStatus.allCases) { s in
                        Label(s.title, systemImage: s.icon).tag(s)
                    }
                }
                Toggle("截止日期", isOn: Binding(
                    get: { task.wrappedValue.dueDate != nil },
                    set: { task.wrappedValue.dueDate = $0 ? Date().addingTimeInterval(86400) : nil }))
                if task.wrappedValue.dueDate != nil {
                    DatePicker("截止", selection: Binding(
                        get: { task.wrappedValue.dueDate ?? Date() },
                        set: { task.wrappedValue.dueDate = $0 }))
                }
            }

            Section {
                ForEach(task.steps) { $step in
                    HStack(spacing: 10) {
                        Button {
                            step.done.toggle()
                            Haptics.tap()
                        } label: {
                            Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(step.done ? Color.green : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        TextField("步骤", text: $step.title, axis: .vertical)
                            .strikethrough(step.done)
                            .foregroundStyle(step.done ? Color.secondary : Color.primary)
                    }
                }
                .onDelete { task.wrappedValue.steps.remove(atOffsets: $0) }
                .onMove { task.wrappedValue.steps.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    Image(systemName: "plus.circle.fill").foregroundStyle(Color.iMessageBlue)
                    TextField("添加步骤", text: $newStep)
                        .onSubmit {
                            let s = newStep.trimmingCharacters(in: .whitespaces)
                            guard !s.isEmpty else { return }
                            task.wrappedValue.steps.append(TaskStep(title: s))
                            newStep = ""
                        }
                }
            } header: {
                HStack {
                    Text("步骤")
                    Spacer()
                    Text(task.wrappedValue.progressText)
                }
            }

            if !task.wrappedValue.notes.isEmpty {
                Section("进展记录") {
                    ForEach(Array(task.wrappedValue.notes.enumerated().reversed()), id: \.offset) { _, note in
                        Text(note).font(.callout)
                    }
                }
            }

            Section {
                Button {
                    continueWithAgent(task.wrappedValue)
                } label: {
                    Label("让智能体继续推进", systemImage: "sparkles")
                }
                if let cid = task.wrappedValue.conversationID, store.conversation(cid) != nil {
                    Button {
                        store.selectedTab = .messages
                        store.openConversationRequest = cid
                    } label: {
                        Label("打开相关对话", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                Button(role: .destructive) {
                    store.deleteTask(taskID)
                    dismiss()
                } label: {
                    Label("删除任务", systemImage: "trash")
                }
            } footer: {
                Text("创建于 \(RelativeTime.chatHeader(task.wrappedValue.createdAt))，更新于 \(RelativeTime.chatHeader(task.wrappedValue.updatedAt))")
            }
        }
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    private func continueWithAgent(_ task: AgentTaskItem) {
        let convID: UUID
        if let cid = task.conversationID, store.conversation(cid) != nil {
            convID = cid
        } else {
            guard let agent = store.agents.first else { return }
            convID = store.newConversation(agentID: agent.id, title: task.title)
            if let i = store.tasks.firstIndex(where: { $0.id == task.id }) { store.tasks[i].conversationID = convID }
        }
        guard !engine.isRunning(convID) else {
            store.selectedTab = .messages
            store.openConversationRequest = convID
            return
        }
        engine.send(text: "请继续推进任务「\(task.title)」（ID \(task.id.uuidString.prefix(8))）：先看看当前进度，完成下一步，并用 update_task 更新进度。",
                    conversationID: convID)
        store.selectedTab = .messages
        store.openConversationRequest = convID
    }
}

struct NewTaskSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var detail = ""
    @State private var stepsText = ""
    @State private var hasDue = false
    @State private var due = Date().addingTimeInterval(86400)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("标题", text: $title)
                    TextField("说明（可选）", text: $detail, axis: .vertical).lineLimit(2...6)
                }
                Section {
                    TextField("每行一个步骤", text: $stepsText, axis: .vertical).lineLimit(3...10)
                } header: {
                    Text("步骤")
                } footer: {
                    Text("也可以留空，之后让智能体帮你拆解。")
                }
                Section {
                    Toggle("截止日期", isOn: $hasDue)
                    if hasDue { DatePicker("截止", selection: $due) }
                }
            }
            .navigationTitle("新任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        var t = AgentTaskItem(title: title.trimmingCharacters(in: .whitespaces))
                        t.detail = detail
                        t.steps = stepsText.split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                            .map { TaskStep(title: $0) }
                        t.dueDate = hasDue ? due : nil
                        store.tasks.insert(t, at: 0)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - 例程

struct RoutineListView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: AgentEngine
    @Binding var editing: Routine?

    var body: some View {
        List {
            if let next = RoutineScheduler.shared.nextRunText() {
                Section {
                    Label("下一次：\(next)", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(store.routines) { r in
                    HStack(spacing: 12) {
                        Button { editing = r } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.timeText)
                                    .font(.system(size: 34, weight: .light, design: .rounded))
                                    .foregroundStyle(r.enabled ? Color.primary : Color.secondary)
                                Text("\(r.title.isEmpty ? "未命名" : r.title) · \(r.weekdayText)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 4) {
                                    AgentAvatar(agent: store.agent(for: r.agentID), size: 16)
                                    Text(store.agent(for: r.agentID).name)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Toggle("", isOn: Binding(
                            get: { store.routines.first(where: { $0.id == r.id })?.enabled ?? false },
                            set: { on in
                                if let i = store.routines.firstIndex(where: { $0.id == r.id }) {
                                    store.routines[i].enabled = on
                                    if on { store.routines[i].lastRun = Date() }
                                    Task { await RoutineScheduler.shared.reschedule() }
                                }
                            }))
                            .labelsHidden()
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.routines.removeAll { $0.id == r.id }
                            Task { await RoutineScheduler.shared.reschedule() }
                        } label: { Label("删除", systemImage: "trash") }
                        Button {
                            store.selectedTab = .messages
                            Task { await engine.runRoutine(r) }
                        } label: { Label("立即运行", systemImage: "play.fill") }
                        .tint(.green)
                    }
                }
            } footer: {
                Text("例程到点时会推送通知；App 在前台或被系统唤醒时自动执行，结果会出现在对应对话里。")
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if store.routines.isEmpty {
                ContentUnavailableView("没有例程", systemImage: "alarm",
                                       description: Text("比如：每个工作日 7:30 给我一份早间简报。"))
            }
        }
    }
}

struct RoutineEditorView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: AgentEngine
    @Environment(\.dismiss) private var dismiss
    @State var routine: Routine

    private static let dayNames = ["一", "二", "三", "四", "五", "六", "日"]
    private var isNew: Bool { !store.routines.contains { $0.id == routine.id } }

    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: routine.hour, minute: routine.minute, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                routine.hour = c.hour ?? 8
                routine.minute = c.minute ?? 0
            })
    }

    var body: some View {
        Form {
            Section {
                TextField("名称，如“早间简报”", text: $routine.title)
                DatePicker("时间", selection: time, displayedComponents: .hourAndMinute)
                HStack(spacing: 6) {
                    ForEach(1...7, id: \.self) { d in
                        let on = routine.weekdays.contains(d)
                        Text(Self.dayNames[d - 1])
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(Circle().fill(on ? Color.iMessageBlue : Color(.tertiarySystemFill)))
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .onTapGesture {
                                if on { routine.weekdays.removeAll { $0 == d } } else { routine.weekdays.append(d) }
                                routine.weekdays.sort()
                            }
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text(routine.weekdayText)
            }

            Section {
                TextEditor(text: $routine.prompt).frame(minHeight: 120)
            } header: {
                Text("到时让智能体做什么")
            }

            Section {
                Picker("智能体", selection: $routine.agentID) {
                    ForEach(store.agents) { a in Text("\(a.emoji) \(a.name)").tag(a.id) }
                }
                Toggle("完成后通知我", isOn: $routine.notify)
                Toggle("启用", isOn: $routine.enabled)
            }

            if !isNew {
                Section {
                    Button {
                        save()
                        store.selectedTab = .messages
                        let r = routine
                        Task { await engine.runRoutine(r) }
                    } label: {
                        Label("立即运行一次", systemImage: "play.circle")
                    }
                }
            }
        }
        .navigationTitle(isNew ? "新例程" : "编辑例程")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    save()
                    dismiss()
                }
                .disabled(routine.title.trimmingCharacters(in: .whitespaces).isEmpty
                          || routine.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func save() {
        store.upsertRoutine(routine)
        Task { await RoutineScheduler.shared.reschedule() }
    }
}
