import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct InputBar: View {
    @Binding var text: String
    @Binding var attachments: [Attachment]
    @Binding var replyTo: ChatMessage?
    var focus: FocusState<Bool>.Binding
    let isRunning: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var speech = SpeechRecognizer()
    @State private var showDrawer = false
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var dictationBase = ""
    @State private var dictating = false

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var shortcutMatches: [PromptShortcut] {
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { return [] }
        let q = text.dropFirst().lowercased()
        return store.shortcuts.filter { q.isEmpty || $0.name.lowercased().hasPrefix(q) }
    }

    var body: some View {
        VStack(spacing: 8) {
            if showDrawer {
                AppDrawer(
                    shortcuts: store.shortcuts,
                    onCamera: { open { showCamera = true } },
                    onPhotos: { open { showPhotos = true } },
                    onFiles: { open { showFiles = true } },
                    onLocation: { open { insertLocation() } },
                    onShortcut: { s in open { text = "/\(s.name) "; focus.wrappedValue = true } }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !shortcutMatches.isEmpty { shortcutList }
            if let replyTo { replyBanner(replyTo) }
            if !attachments.isEmpty { attachmentStrip }
            GlassSurfaceGroup {
                HStack(alignment: .bottom, spacing: 10) {
                    Button {
                        if !showDrawer { focus.wrappedValue = false }
                        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82)) {
                            showDrawer.toggle()
                        }
                        Haptics.tap()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.primary)
                            .rotationEffect(.degrees(showDrawer ? 45 : 0))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glass(Circle(), interactive: true)
                    .accessibilityLabel(showDrawer ? "关闭附件菜单" : "添加附件和快捷指令")

                    HStack(alignment: .bottom, spacing: 4) {
                        TextField(speech.isRecording ? "正在聆听…" : "信息", text: $text, axis: .vertical)
                            .lineLimit(1...6)
                            .focused(focus)
                            .padding(.leading, 15)
                            .padding(.vertical, 12)
                            .accessibilityLabel("信息")
                        trailingButton
                            .padding(.trailing, 2)
                    }
                    .frame(minHeight: 44)
                    .glass(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
            }
        }
        .frame(maxWidth: 680)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: attachments.count)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: replyTo?.id)
        .onChange(of: focus.wrappedValue) { _, focused in
            if focused { showDrawer = false }
        }
        .onDisappear {
            speech.stop()
            dictating = false
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 6, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in addImage(data) }.ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            handleFiles(result)
        }
        .onChange(of: speech.transcript) { _, t in
            if dictating, !t.isEmpty { text = dictationBase + t }
        }
    }

    // MARK: 发送按钮

    @ViewBuilder
    private var trailingButton: some View {
        Group {
            if speech.isRecording {
                Button {
                    speech.stop()
                } label: {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.red)
                        .symbolEffect(.pulse, isActive: !reduceMotion)
                }
                .accessibilityLabel("结束听写")
            } else if isRunning {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.iMessageBlue)
                }
                .accessibilityLabel("停止回复")
            } else if canSend {
                Button {
                    dictating = false
                    onSend()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, isRunning ? Color.gray : Color.iMessageBlue)
                }
                .disabled(isRunning)
                .accessibilityLabel("发送信息")
            } else {
                Button {
                    dictationBase = text
                    dictating = true
                    speech.toggle()
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("语音听写")
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .buttonStyle(ComposerActionStyle())
    }

    // MARK: 附加区域

    private var shortcutList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shortcutMatches.prefix(5)) { s in
                Button {
                    text = "/\(s.name) "
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "command").foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("/\(s.name)").font(.subheadline.weight(.semibold))
                            Text(s.prompt.plainPreview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func replyBanner(_ m: ChatMessage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill").foregroundStyle(Color.iMessageBlue)
            Text(m.text.isEmpty ? "附件" : m.text.plainPreview)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button { replyTo = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("取消引用回复")
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glass(Capsule())
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { att in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if att.kind == .image, let img = store.image(for: att) {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else {
                                VStack(spacing: 4) {
                                    Image(systemName: "doc.fill").font(.title3)
                                    Text(att.fileName).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(.secondarySystemBackground))
                            }
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        Button {
                            attachments.removeAll { $0.id == att.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white, Color.black.opacity(0.6))
                                .font(.system(size: 20))
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("移除附件 \(att.fileName)")
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 6)
        }
    }

    // MARK: 动作

    private func open(_ action: () -> Void) {
        showDrawer = false
        action()
    }

    private func addImage(_ data: Data) {
        guard let jpeg = ImageUtil.jpeg(data),
              let att = store.storeAttachment(data: jpeg, fileName: "照片.jpg", mime: "image/jpeg", kind: .image) else { return }
        attachments.append(att)
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) { addImage(data) }
        }
        photoItems = []
    }

    private func handleFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .image) == true {
                addImage(data)
            } else {
                let mime = type?.preferredMIMEType ?? "application/octet-stream"
                if let att = store.storeAttachment(data: data, fileName: url.lastPathComponent, mime: mime, kind: .file) {
                    attachments.append(att)
                }
            }
        }
    }

    private func insertLocation() {
        Task {
            do {
                let loc = try await LocationService.shared.current()
                let name = await LocationService.shared.placeName(for: loc)
                let line = "我的位置：\(name)（\(String(format: "%.5f, %.5f", loc.coordinate.latitude, loc.coordinate.longitude))）"
                text = text.isEmpty ? line : text + "\n" + line
            } catch {
                text += (text.isEmpty ? "" : "\n") + "（获取位置失败：\(error.localizedDescription)）"
            }
        }
    }
}

private struct ComposerActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - “+” 抽屉

struct AppDrawer: View {
    let shortcuts: [PromptShortcut]
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void
    let onLocation: () -> Void
    let onShortcut: (PromptShortcut) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                row("相机", "camera.fill", .gray, onCamera)
                row("照片", "photo.on.rectangle.angled", .blue, onPhotos)
                row("文件", "folder.fill", .cyan, onFiles)
                row("位置", "location.fill", .green, onLocation)
                if !shortcuts.isEmpty {
                    Divider().padding(.vertical, 8)
                    Text("快捷指令")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        ForEach(shortcuts) { s in
                            Button {
                                onShortcut(s)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "command")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 36, height: 36)
                                        .background(Circle().fill(Color.purple))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("/\(s.name)").foregroundStyle(.primary)
                                        Text(s.prompt.plainPreview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .padding(.horizontal, 16)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                }
            }
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 300)
        .glass(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityIdentifier("chat.attachmentMenu")
    }

    private func row(_ title: String, _ icon: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(color))
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .font(.body.weight(.medium))
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 相机

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onImage(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
