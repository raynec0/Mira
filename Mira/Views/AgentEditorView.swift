import SwiftUI

struct AgentEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var agent: AgentProfile
    @State private var useTemperature = false
    @State private var confirmDelete = false

    private static let palette = ["5E5CE6", "0A84FF", "64D2FF", "30D158", "FF9F0A", "FF375F", "BF5AF2", "8E8E93"]

    private var isNew: Bool { !store.agents.contains { $0.id == agent.id } }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    AgentAvatar(agent: agent, size: 92)
                    TextField("表情", text: $agent.emoji)
                        .multilineTextAlignment(.center)
                        .font(.title2)
                        .frame(width: 90)
                        .onChange(of: agent.emoji) { _, v in
                            if v.count > 1 { agent.emoji = String(v.suffix(1)) }
                        }
                    HStack(spacing: 10) {
                        ForEach(Self.palette, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 28, height: 28)
                                .overlay(Circle().stroke(Color.primary, lineWidth: agent.colorHex == hex ? 2.5 : 0).padding(-3))
                                .onTapGesture { agent.colorHex = hex }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }

            Section("名称") {
                TextField("名称", text: $agent.name)
            }

            Section {
                TextEditor(text: $agent.systemPrompt)
                    .frame(minHeight: 160)
            } header: {
                Text("人设与职责（系统提示词）")
            } footer: {
                Text("描述这个智能体是谁、擅长什么、说话风格如何。")
            }

            Section("模型") {
                Picker("服务商", selection: $agent.provider) {
                    Text("跟随默认").tag(ProviderKind?.none)
                    ForEach(ProviderKind.allCases) { p in
                        Text(p.title).tag(ProviderKind?.some(p))
                    }
                }
                TextField("模型（留空使用默认）", text: Binding(
                    get: { agent.model ?? "" },
                    set: { agent.model = $0.isEmpty ? nil : $0 }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("自定义温度", isOn: $useTemperature)
                if useTemperature {
                    HStack {
                        Slider(value: Binding(get: { agent.temperature ?? 0.7 }, set: { agent.temperature = $0 }),
                               in: 0...2, step: 0.1)
                        Text(String(format: "%.1f", agent.temperature ?? 0.7))
                            .monospacedDigit()
                            .frame(width: 34)
                    }
                }
                Stepper("单次最多 \(agent.maxSteps) 步", value: $agent.maxSteps, in: 1...50)
            }

            Section {
                ForEach(ToolRegistry.infos) { info in
                    Toggle(isOn: Binding(
                        get: { !agent.disabledTools.contains(info.name) },
                        set: { on in
                            if on {
                                agent.disabledTools.removeAll { $0 == info.name }
                            } else if !agent.disabledTools.contains(info.name) {
                                agent.disabledTools.append(info.name)
                            }
                        })) {
                        Label(info.title, systemImage: info.icon)
                    }
                }
            } header: {
                Text("可用工具")
            }

            if !isNew {
                Section {
                    Button {
                        let id = store.newConversation(agentID: agent.id)
                        store.upsertAgent(normalized)
                        store.selectedTab = .messages
                        store.openConversationRequest = id
                        dismiss()
                    } label: {
                        Label("和 \(agent.name) 开始新对话", systemImage: "square.and.pencil")
                    }
                    if store.agents.count > 1 {
                        Button("删除智能体", role: .destructive) { confirmDelete = true }
                    }
                }
            }
        }
        .navigationTitle(isNew ? "新建智能体" : "编辑智能体")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    store.upsertAgent(normalized)
                    dismiss()
                }
                .disabled(agent.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { useTemperature = agent.temperature != nil }
        .confirmationDialog("删除「\(agent.name)」？使用它的对话会转给其他智能体。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                store.deleteAgent(agent.id)
                dismiss()
            }
        }
    }

    private var normalized: AgentProfile {
        var a = agent
        a.name = a.name.trimmingCharacters(in: .whitespaces)
        if !useTemperature { a.temperature = nil }
        return a
    }
}
