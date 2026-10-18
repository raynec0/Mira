import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: AgentEngine
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var tavilyKey = ""
    @State private var imageKey = ""
    @State private var loadedKeys = false
    @State private var modelChoices: ModelChoices?
    @State private var fetching: ProviderKind?
    @State private var alertMessage: String?
    @State private var exportURL: URL?
    @State private var showImport = false
    @State private var confirmWipe = false

    struct ModelChoices: Identifiable {
        let provider: ProviderKind
        let models: [String]
        var id: String { provider.rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(Circle().fill(LinearGradient(colors: [Color(hex: "BF5AF2"), Color(hex: "5E5CE6"), Color(hex: "0A84FF")],
                                                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.settings.userName.isEmpty ? "Mira" : store.settings.userName).font(.title3.weight(.semibold))
                            Text("你的私人 AI 智能体").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    TextField("怎么称呼你", text: $store.settings.userName)
                    TextField("关于我（职业、偏好、常住城市…）", text: $store.settings.aboutMe, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("关于我")
                } footer: {
                    Text("这些信息会提供给所有智能体，帮助它们更懂你。")
                }

                Section("模型服务") {
                    Picker("默认服务商", selection: $store.settings.defaultProvider) {
                        ForEach(ProviderKind.allCases) { Text($0.title).tag($0) }
                    }
                }

                Section {
                    urlField("Base URL", text: $store.settings.openAIBaseURL)
                    SecureField("API Key", text: $openAIKey)
                    modelRow(text: $store.settings.openAIModel, provider: .openai)
                } header: {
                    Text("OpenAI 兼容")
                } footer: {
                    Text("支持 OpenAI、DeepSeek、通义千问、Kimi、智谱、OpenRouter、Ollama 等兼容 /chat/completions 的服务。模型需支持工具调用（Function Calling）。")
                }

                Section {
                    urlField("Base URL", text: $store.settings.anthropicBaseURL)
                    SecureField("API Key", text: $anthropicKey)
                    modelRow(text: $store.settings.anthropicModel, provider: .anthropic)
                    Stepper("最大输出 \(store.settings.anthropicMaxTokens) tokens", value: $store.settings.anthropicMaxTokens, in: 1024...64000, step: 1024)
                } header: {
                    Text("Anthropic Claude")
                }

                Section {
                    SecureField("Tavily API Key（可选）", text: $tavilyKey)
                } header: {
                    Text("网页搜索")
                } footer: {
                    Text("未填写时使用 DuckDuckGo / Bing 网页搜索。Tavily 结果更稳定，可在 tavily.com 免费申请。")
                }

                Section {
                    urlField("Base URL（留空同 OpenAI 兼容）", text: $store.settings.imageBaseURL)
                    SecureField("API Key（留空同 OpenAI 兼容）", text: $imageKey)
                    TextField("模型", text: $store.settings.imageModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("默认尺寸", selection: $store.settings.imageSize) {
                        Text("方形 1024×1024").tag("1024x1024")
                        Text("竖版 1024×1536").tag("1024x1536")
                        Text("横版 1536×1024").tag("1536x1024")
                    }
                } header: {
                    Text("图像生成")
                }

                Section("智能体与能力") {
                    NavigationLink { AgentsListView() } label: {
                        Label { Text("智能体") } icon: { IconTile(systemName: "person.2.fill", color: .indigo) }
                    }
                    NavigationLink { PermissionsView() } label: {
                        Label { Text("权限与批准") } icon: { IconTile(systemName: "hand.raised.fill", color: .orange) }
                    }
                    NavigationLink { ConnectorsView() } label: {
                        Label { Text("连接器") } icon: { IconTile(systemName: "point.3.connected.trianglepath.dotted", color: .teal) }
                    }
                    NavigationLink { ShortcutsView() } label: {
                        Label { Text("快捷指令") } icon: { IconTile(systemName: "command", color: .purple) }
                    }
                    NavigationLink { MemoryView() } label: {
                        Label { Text("记忆") } icon: { IconTile(systemName: "brain.head.profile", color: .pink) }
                    }
                    NavigationLink { FilesView() } label: {
                        Label { Text("文件") } icon: { IconTile(systemName: "folder.fill", color: .blue) }
                    }
                }

                Section("体验") {
                    Toggle("触感反馈", isOn: $store.settings.hapticsEnabled)
                    Toggle("自动朗读回复", isOn: $store.settings.autoSpeak)
                    Toggle("让智能体参考记忆", isOn: $store.settings.injectMemories)
                }

                Section {
                    Toggle("面容 ID / 密码锁", isOn: $store.settings.biometricLock)
                    Button("开启通知权限") { NotificationService.requestAuthorization() }
                } header: {
                    Text("隐私与安全")
                } footer: {
                    Text("API Key 保存在系统钥匙串中。所有对话与数据只存储在本机。")
                }

                Section("数据") {
                    Button {
                        exportURL = store.exportBackup()
                    } label: {
                        Label("生成备份文件", systemImage: "arrow.up.doc")
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("分享备份：\(exportURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button {
                        showImport = true
                    } label: {
                        Label("从备份恢复", systemImage: "arrow.down.doc")
                    }
                    Button(role: .destructive) {
                        confirmWipe = true
                    } label: {
                        Label("删除所有对话", systemImage: "trash")
                    }
                }

                Section {
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    LabeledContent("工具数量", value: "\(ToolRegistry.all.count)")
                }
            }
            .navigationTitle("设置")
            .onAppear(perform: loadKeys)
            .onChange(of: openAIKey) { _, v in if loadedKeys { Keychain.set(v.trimmingCharacters(in: .whitespacesAndNewlines), for: KeyName.openAI) } }
            .onChange(of: anthropicKey) { _, v in if loadedKeys { Keychain.set(v.trimmingCharacters(in: .whitespacesAndNewlines), for: KeyName.anthropic) } }
            .onChange(of: tavilyKey) { _, v in if loadedKeys { Keychain.set(v.trimmingCharacters(in: .whitespacesAndNewlines), for: KeyName.tavily) } }
            .onChange(of: imageKey) { _, v in if loadedKeys { Keychain.set(v.trimmingCharacters(in: .whitespacesAndNewlines), for: KeyName.image) } }
            .sheet(item: $modelChoices) { choices in
                ModelPickerSheet(models: choices.models) { model in
                    if choices.provider == .openai { store.settings.openAIModel = model } else { store.settings.anthropicModel = model }
                }
            }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    do {
                        engine.stopAll()
                        try store.importBackup(from: url)
                        alertMessage = "已从备份恢复。"
                    } catch {
                        alertMessage = "恢复失败：\(error.localizedDescription)"
                    }
                case .failure(let error):
                    alertMessage = error.localizedDescription
                }
            }
            .confirmationDialog("删除所有对话？此操作无法撤销。", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("全部删除", role: .destructive) {
                    engine.stopAll()
                    for c in store.conversations { store.deleteConversation(c.id) }
                }
            }
            .alert("提示", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private func urlField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    private func modelRow(text: Binding<String>, provider: ProviderKind) -> some View {
        HStack {
            TextField("模型", text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if fetching == provider {
                ProgressView()
            } else {
                Button("选择") { fetchModels(provider) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func loadKeys() {
        guard !loadedKeys else { return }
        openAIKey = Keychain.get(KeyName.openAI)
        anthropicKey = Keychain.get(KeyName.anthropic)
        tavilyKey = Keychain.get(KeyName.tavily)
        imageKey = Keychain.get(KeyName.image)
        DispatchQueue.main.async { loadedKeys = true }
    }

    private func fetchModels(_ provider: ProviderKind) {
        fetching = provider
        let base = provider == .openai ? store.settings.openAIBaseURL : store.settings.anthropicBaseURL
        let key = provider == .openai ? openAIKey : anthropicKey
        Task {
            do {
                let models = try await LLMClient.listModels(provider: provider, baseURL: base, apiKey: key)
                fetching = nil
                if models.isEmpty { alertMessage = "没有获取到模型" } else { modelChoices = ModelChoices(provider: provider, models: models) }
            } catch {
                fetching = nil
                alertMessage = "获取模型失败：\(error.localizedDescription)"
            }
        }
    }
}

struct ModelPickerSheet: View {
    let models: [String]
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List(models.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { m in
                Button {
                    onPick(m)
                    dismiss()
                } label: {
                    Text(m).foregroundStyle(.primary)
                }
            }
            .searchable(text: $search)
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

// MARK: - 智能体列表

struct AgentsListView: View {
    @EnvironmentObject private var store: AppStore
    @State private var editing: AgentProfile?

    var body: some View {
        List {
            ForEach(store.agents) { a in
                Button { editing = a } label: {
                    HStack(spacing: 12) {
                        AgentAvatar(agent: a, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name).foregroundStyle(.primary)
                            Text(a.provider?.title ?? "默认服务商").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onMove { store.agents.move(fromOffsets: $0, toOffset: $1) }
        }
        .navigationTitle("智能体")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = AgentProfile.blank } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .sheet(item: $editing) { a in NavigationStack { AgentEditorView(agent: a) } }
    }
}

// MARK: - 权限

struct PermissionsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List {
            Section {
                ForEach(ToolRegistry.infos) { info in
                    Picker(selection: Binding(
                        get: { store.settings.toolPermissions[info.name] ?? info.defaultPermission },
                        set: { store.settings.toolPermissions[info.name] = $0 })) {
                        ForEach(ToolPermission.allCases) { p in Text(p.title).tag(p) }
                    } label: {
                        Label { Text(info.title) } icon: { Image(systemName: info.icon).foregroundStyle(Color.iMessageBlue) }
                    }
                }
            } footer: {
                Text("“每次询问”的操作会在对话中显示批准卡片，你同意后智能体才会执行。所有操作都会记录在「动态」中。")
            }
            Section {
                Button("恢复默认") { store.settings.toolPermissions = [:] }
            }
        }
        .navigationTitle("权限与批准")
    }
}

// MARK: - 连接器

struct ConnectorsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var editing: Connector?

    var body: some View {
        List {
            Section {
                ForEach(store.connectors) { c in
                    Button { editing = c } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).foregroundStyle(.primary)
                                Text(c.baseURL).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if !c.enabled { Text("已停用").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx { Keychain.set("", for: KeyName.connector(store.connectors[i].id)) }
                    store.connectors.remove(atOffsets: idx)
                }
            } footer: {
                Text("把任意 HTTP API 接入给智能体，例如 Notion、GitHub、Home Assistant、公司内部系统。认证头保存在钥匙串中，智能体看不到明文。")
            }
        }
        .overlay {
            if store.connectors.isEmpty {
                ContentUnavailableView("没有连接器", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("点右上角添加一个 API"))
            }
        }
        .navigationTitle("连接器")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = Connector(name: "", summary: "", baseURL: "https://") } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editing) { c in NavigationStack { ConnectorEditor(connector: c) } }
    }
}

struct ConnectorEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var connector: Connector
    @State private var headers: [HeaderRow] = []

    struct HeaderRow: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    var body: some View {
        Form {
            Section {
                TextField("名称（英文，如 github）", text: $connector.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("用途说明（告诉智能体它能做什么）", text: $connector.summary, axis: .vertical)
                    .lineLimit(2...5)
                TextField("Base URL", text: $connector.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("启用", isOn: $connector.enabled)
            }
            Section {
                ForEach($headers) { $row in
                    VStack(spacing: 6) {
                        TextField("Header 名，如 Authorization", text: $row.key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("值，如 Bearer xxx", text: $row.value)
                    }
                }
                .onDelete { headers.remove(atOffsets: $0) }
                Button {
                    headers.append(HeaderRow(key: "", value: ""))
                } label: {
                    Label("添加请求头", systemImage: "plus")
                }
            } header: {
                Text("请求头（认证）")
            }
        }
        .navigationTitle(connector.name.isEmpty ? "新连接器" : connector.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    var dict: [String: String] = [:]
                    for h in headers where !h.key.trimmingCharacters(in: .whitespaces).isEmpty {
                        dict[h.key.trimmingCharacters(in: .whitespaces)] = h.value
                    }
                    ConnectorHeaders.save(dict, for: connector.id)
                    connector.name = connector.name.trimmingCharacters(in: .whitespaces)
                    if let i = store.connectors.firstIndex(where: { $0.id == connector.id }) {
                        store.connectors[i] = connector
                    } else {
                        store.connectors.append(connector)
                    }
                    dismiss()
                }
                .disabled(connector.name.trimmingCharacters(in: .whitespaces).isEmpty || URL(string: connector.baseURL)?.host == nil)
            }
        }
        .onAppear {
            if headers.isEmpty {
                headers = ConnectorHeaders.load(connector.id).map { HeaderRow(key: $0.key, value: $0.value) }
            }
        }
    }
}

// MARK: - 快捷指令

struct ShortcutsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var editing: PromptShortcut?

    var body: some View {
        List {
            Section {
                ForEach(store.shortcuts) { s in
                    Button { editing = s } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("/\(s.name)").font(.body.weight(.semibold)).foregroundStyle(.primary)
                            Text(s.prompt.plainPreview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .onDelete { store.shortcuts.remove(atOffsets: $0) }
                .onMove { store.shortcuts.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                Text("在输入框输入 “/” 即可调用。提示词中的 {{input}} 会被替换为指令后面输入的内容。")
            }
        }
        .navigationTitle("快捷指令")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = PromptShortcut(name: "", prompt: "{{input}}") } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .sheet(item: $editing) { s in NavigationStack { ShortcutEditor(shortcut: s) } }
    }
}

struct ShortcutEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var shortcut: PromptShortcut

    var body: some View {
        Form {
            Section("名称") {
                TextField("如 翻译", text: $shortcut.name)
            }
            Section {
                TextEditor(text: $shortcut.prompt).frame(minHeight: 160)
            } header: {
                Text("提示词")
            } footer: {
                Text("用 {{input}} 表示输入内容的位置。")
            }
        }
        .navigationTitle("快捷指令")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    shortcut.name = shortcut.name.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: " ", with: "")
                        .replacingOccurrences(of: "/", with: "")
                    if let i = store.shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
                        store.shortcuts[i] = shortcut
                    } else {
                        store.shortcuts.append(shortcut)
                    }
                    dismiss()
                }
                .disabled(shortcut.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - 记忆

struct MemoryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var editing: MemoryItem?
    @State private var confirmClear = false

    private var categories: [String] {
        Array(Set(store.memories.map { $0.category })).sorted()
    }

    var body: some View {
        List {
            ForEach(categories, id: \.self) { cat in
                Section(cat) {
                    ForEach(store.memories.filter { $0.category == cat }) { m in
                        Button { editing = m } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.content).foregroundStyle(.primary)
                                Text(RelativeTime.chatHeader(m.createdAt)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { store.memories.removeAll { $0.id == m.id } } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if store.memories.isEmpty {
                ContentUnavailableView("还没有记忆", systemImage: "brain.head.profile",
                                       description: Text("聊天时告诉智能体你的偏好，它会记下来。你也可以手动添加。"))
            }
        }
        .navigationTitle("记忆")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = MemoryItem(content: "") } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { confirmClear = true } label: { Label("清空全部记忆", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("清空全部记忆？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { store.memories.removeAll() }
        }
        .sheet(item: $editing) { m in NavigationStack { MemoryEditor(item: m) } }
    }
}

struct MemoryEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var item: MemoryItem

    var body: some View {
        Form {
            Section("内容") {
                TextField("例如：我喜欢简洁的回答", text: $item.content, axis: .vertical).lineLimit(2...8)
            }
            Section("分类") {
                TextField("分类", text: $item.category)
            }
        }
        .navigationTitle("记忆")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    if item.category.trimmingCharacters(in: .whitespaces).isEmpty { item.category = "通用" }
                    if let i = store.memories.firstIndex(where: { $0.id == item.id }) {
                        store.memories[i] = item
                    } else {
                        store.memories.append(item)
                    }
                    dismiss()
                }
                .disabled(item.content.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - 文件

struct FilesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var files: [URL] = []

    var body: some View {
        List {
            Section {
                ForEach(files, id: \.self) { url in
                    ShareLink(item: url) {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text.fill").font(.title3).foregroundStyle(Color.iMessageBlue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent).foregroundStyle(.primary).lineLimit(1)
                                Text(detail(url)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx { try? FileManager.default.removeItem(at: files[i]) }
                    reload()
                }
            } footer: {
                Text("这些文件也可以在系统「文件」App › 我的 iPhone › Mira 中找到。")
            }
        }
        .overlay {
            if files.isEmpty {
                ContentUnavailableView("还没有文件", systemImage: "folder", description: Text("让智能体为你创建文档，它们会出现在这里。"))
            }
        }
        .navigationTitle("文件")
        .onAppear(perform: reload)
        .refreshable { reload() }
    }

    private func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: store.filesDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        files = urls.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    private func detail(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
        let date = values?.contentModificationDate.map { RelativeTime.chatHeader($0) } ?? ""
        return "\(size) · \(date)"
    }
}
