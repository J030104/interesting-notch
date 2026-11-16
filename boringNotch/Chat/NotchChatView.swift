import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct NotchChatView: View {
    @EnvironmentObject private var vm: BoringViewModel
    let showQuickShare: Bool
    @ObservedObject private var model = NotchChats.shared
    @State private var selectedID: String?
    @State private var answers: [String: String] = [:]
    @State private var pasteError: String?
    @State private var openingChatID: String?
    @State private var isAttaching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    model.clearFinishedChats()
                } label: {
                    Image(systemName: "eraser")
                }
                .buttonStyle(.plain)
                .disabled(!model.hasFinishedNotchChats)
                .accessibilityLabel("Clear Done tracking")
                .help("Clear the Done status and keep the chats in History.")
                counter(.done, icon: "checkmark.circle", color: .secondary)
                counter(.running, icon: "circle.dotted", color: .secondary)
                counter(.attention, icon: "exclamationmark.circle", color: model.count(.attention) > 0 ? .orange : .secondary)
                Spacer()
                Text(model.sharedServer ? "Shared Codex" : "Local Codex")
                    .foregroundStyle(.secondary)
                    .help(model.sharedServer
                          ? "Live activity from chats on the shared Codex server."
                          : "Live activity for chats started here. Other local chats appear as history.")
            }
            .font(.system(size: 10, weight: .medium))
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let selectedID, let chat = model.chats[selectedID] {
                        details(chat)
                    } else {
                        composer($model.newInput)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Divider()
                VStack(spacing: 6) {
                    chatList
                    if showQuickShare {
                        FileShareView(compact: true)
                            .frame(height: 32)
                            .help("Drop a file here to share it.")
                    }
                }
                .frame(width: 225)
            }
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await model.connect()
            await model.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                await model.refresh()
            }
        }
        .task(id: selectedID) {
            if let selectedID { await model.loadReply(selectedID) }
        }
        .onChange(of: selectedID) { pasteError = nil }
        .onDisappear { vm.chatDropTargeting = false }
    }

    private func counter(_ status: NotchChats.Status, icon: String, color: Color) -> some View {
        Label("\(model.count(status)) \(status.rawValue.lowercased())", systemImage: icon)
            .foregroundStyle(color)
            .fixedSize()
    }

    private func composer(_ draft: Binding<NotchComposerInput>, in threadID: String? = nil) -> some View {
        let input = draft.wrappedValue
        return VStack(alignment: .leading, spacing: 5) {
            if !input.files.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(input.files.indices, id: \.self) { index in
                            let file = input.files[index]
                            HStack(spacing: 4) {
                                Label(file.lastPathComponent, systemImage: "doc")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 160)
                                Button {
                                    draft.wrappedValue.files.remove(at: index)
                                    pasteError = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(file.lastPathComponent)")
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.08), in: .rect(cornerRadius: 4))
                            .help(file.path(percentEncoded: false))
                        }
                    }
                    .font(.system(size: 11))
                }
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 7) {
                ForEach(input.screenshots.indices, id: \.self) { index in
                    if let preview = NSImage(data: input.screenshots[index]) {
                        Image(nsImage: preview)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 44, height: 41)
                            .background(.white.opacity(0.09), in: .rect(cornerRadius: 4))
                            .accessibilityLabel("Screenshot \(index + 1)")
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    draft.wrappedValue.screenshots.remove(at: index)
                                    pasteError = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .padding(2)
                                        .background(.black.opacity(0.8), in: .circle)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove screenshot \(index + 1)")
                            }
                    }
                }
                ChatPromptField(
                    text: draft.prompt,
                    pasteAttachments: { pasteAttachments($0, into: draft) },
                    submit: { submit(in: threadID) }
                )
                    .overlay(alignment: .topLeading) {
                        if input.prompt.isEmpty {
                            Text(threadID == nil ? "Ask a question or drop files…" : "Continue this chat…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .padding(4)
            .frame(height: threadID == nil ? 55 : 50)
            .background(.white.opacity(0.08), in: .rect(cornerRadius: 6))
            .overlay {
                if vm.chatDropTargeting || isAttaching {
                    Label(isAttaching ? "Attaching…" : "Drop files to attach", systemImage: "paperclip")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.9), in: .rect(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor))
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: DragDetector.fileTypes, isTargeted: $vm.chatDropTargeting) { providers in
                attachDroppedFiles(providers, to: draft)
            }

            HStack(spacing: 7) {
                Button {
                    chooseFiles(for: draft)
                } label: {
                    Image(systemName: "paperclip")
                }
                .accessibilityLabel("Attach files")
                .disabled(isAttaching)
                .help("Choose files to attach")

                Button {
                    if !pasteAttachments(NSPasteboard.general, into: draft) {
                        pasteError = "Copy a file or screenshot first."
                    }
                } label: {
                    Image(systemName: "clipboard")
                }
                .accessibilityLabel("Paste attachments")
                .disabled(isAttaching)
                .help("Paste files or screenshots")
                if !model.models.isEmpty { modelOptions }
                Spacer(minLength: 1)
                if model.isConnected && !model.isConnecting {
                    Button {
                        submit(in: threadID)
                    } label: {
                        Label(threadID == nil ? "Ask" : "Send", systemImage: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAttaching || !model.canSubmit(input, in: threadID))
                    .help(threadID == nil ? "Start a new Codex chat (⌘↩)" : "Send a follow-up (⌘↩)")
                } else {
                    Button(model.isConnecting ? "Connecting…" : "Connect") {
                        Task { await model.connect() }
                    }
                    .disabled(model.isConnecting)
                }
            }
            .controlSize(.small)

            if let message = pasteError ?? model.connectionError ?? imageSupportMessage(input) {
                Text(message)
                    .lineLimit(2)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(message)
            }
        }
    }

    private var modelOptions: some View {
        Menu {
            Picker("Model", selection: Binding(get: { model.modelID }, set: { model.selectModel($0) })) {
                Text("Codex default").tag(nil as String?)
                ForEach(model.models) { option in
                    Text(option.name).tag(Optional(option.id))
                }
            }
            if let selectedModel = model.selectedModel, !selectedModel.efforts.isEmpty {
                Picker("Reasoning effort", selection: $model.effort) {
                    Text(selectedModel.defaultEffort.map { "Default (\(effortLabel($0)))" } ?? "Default").tag(nil as String?)
                    ForEach(selectedModel.efforts, id: \.self) { effort in
                        Text(effortLabel(effort)).tag(Optional(effort))
                    }
                }
            }
            if let selectedModel = model.selectedModel, selectedModel.fastTier != nil {
                Toggle("Fast mode", isOn: $model.fastMode)
                    .help(selectedModel.fastDescription ?? "Use the model’s faster service tier.")
            }
        } label: {
            Label(model.modelID == nil ? "Codex default" : (model.selectedModel?.name ?? "Model"),
                  systemImage: model.fastMode ? "bolt.fill" : "slider.horizontal.3")
                .lineLimit(1)
        }
        .help("Model, reasoning effort, and Fast mode")
    }

    private func effortLabel(_ effort: String) -> String {
        effort == "xhigh" ? "Extra high" : effort.capitalized
    }

    private func imageSupportMessage(_ input: NotchComposerInput) -> String? {
        guard !input.screenshots.isEmpty, model.selectedModel?.supportsImages == false else { return nil }
        return "Choose a model that accepts screenshots."
    }

    private var chatList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if model.orderedChats.isEmpty {
                    Text(model.isConnecting ? "Connecting to Codex…" : "Chats will appear here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(model.orderedChats) { chat in
                    Button {
                        answers.removeAll()
                        selectedID = chat.id
                    } label: {
                        HStack(spacing: 6) {
                            Text(chat.title).lineLimit(1)
                            Spacer(minLength: 3)
                            Text(chat.status.rawValue)
                                .font(.system(size: 9))
                                .foregroundStyle(chat.status == .attention ? Color.orange : Color.secondary)
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(selectedID == chat.id ? .white.opacity(0.13) : .clear, in: .rect(cornerRadius: 4))
                    .help(chat.title)
                }
            }
        }
        .accessibilityLabel("Codex chats")
    }

    private func details(_ chat: NotchChats.Chat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Button {
                    selectedID = nil
                } label: {
                    Label("New question", systemImage: "square.and.pencil")
                }
                Spacer(minLength: 2)
                if chat.canOpenInDesktop, UUID(uuidString: chat.id) != nil {
                    Button {
                        openingChatID = chat.id
                        pasteError = nil
                        Task {
                            defer { openingChatID = nil }
                            do {
                                try await model.openInDesktop(chat.id)
                            } catch {
                                if selectedID == chat.id { pasteError = error.localizedDescription }
                            }
                        }
                    } label: {
                        Label("Open chat", systemImage: "arrow.up.right")
                    }
                    .disabled(openingChatID != nil)
                    .help("Open this chat in the ChatGPT desktop app")
                }
            }
            .controlSize(.small)

            Text(chat.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            if let request = model.requests.first(where: { $0.threadID == chat.id }) {
                attention(request)
            } else {
                ScrollView {
                    Text(chat.detail.isEmpty ? statusDetail(chat.status) : chat.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if model.failedDrafts[chat.id] != nil {
                Button("Restore draft") {
                    let target = model.failedDrafts[chat.id]?.threadID
                    model.restoreDraft(chat.id)
                    selectedID = target
                    if let target { Task { await model.loadReply(target) } }
                }
                .controlSize(.small)
                .disabled(isAttaching || !model.canRestoreDraft(chat.id))
            }
            if chat.canOpenInDesktop {
                composer(Binding(
                    get: { model.replyInputs[chat.id, default: NotchComposerInput()] },
                    set: { model.replyInputs[chat.id] = $0 }
                ), in: chat.id)
            }
        }
    }

    private func statusDetail(_ status: NotchChats.Status) -> String {
        switch status {
        case .running: "Codex is working on this request."
        case .attention: "Open this chat to see what Codex needs."
        case .done, .history: "Open this chat to see its conversation."
        }
    }

    private func attention(_ request: NotchChats.Attention) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    Text(request.message)
                        .textSelection(.enabled)
                    ForEach(request.questions) { question in
                        Text(question.text)
                        if question.options.isEmpty {
                            ChatPromptField(text: answerBinding(question.id), pasteAttachments: { _ in false }, submit: {})
                                .frame(height: 24)
                                .background(.white.opacity(0.08), in: .rect(cornerRadius: 4))
                        } else {
                            Picker("Answer", selection: answerBinding(question.id)) {
                                Text("Choose an answer").tag("")
                                ForEach(question.options, id: \.self) { option in
                                    Text(option).tag(option)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Decline") { model.respond(request, accept: false) }
                Button(request.kind == .command ? "Allow once" : "Reply") {
                    model.respond(request, accept: true, answers: answers)
                    answers.removeAll()
                }
                .disabled(request.questions.contains { (answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
            .controlSize(.small)
        }
        .font(.system(size: 11))
        .onChange(of: request.id) { answers.removeAll() }
    }

    private func answerBinding(_ id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }

    private func submit(in threadID: String?) {
        guard !isAttaching else { return }
        pasteError = nil
        model.submit(in: threadID)
    }

    private func chooseFiles(for draft: Binding<NotchComposerInput>) {
        let panel = NSOpenPanel()
        panel.title = "Attach Files"
        panel.prompt = "Attach"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        let sharing = SharingStateManager.shared
        sharing.beginInteraction()
        defer { sharing.endInteraction(closeNotch: false) }
        if panel.runModal() == .OK {
            pasteError = addAttachments(panel.urls.map { NotchAttachment(fileURL: $0) }, to: draft)
        }
    }

    private func pasteAttachments(_ pasteboard: NSPasteboard, into draft: Binding<NotchComposerInput>) -> Bool {
        let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
        let items = pasteboard.pasteboardItems?.filter { $0.availableType(from: types) != nil } ?? []
        guard !items.isEmpty else { return false }
        guard !isAttaching else { return true }
        let attachments: [NotchAttachment?] = items.map { item in
            if let url = item.string(forType: .fileURL).flatMap({ URL(string: $0) }) {
                return NotchAttachment(fileURL: url)
            }
            return (item.data(forType: .png) ?? item.data(forType: .tiff))
                .flatMap(NotchScreenshot.encode).map(NotchAttachment.screenshot)
        }
        pasteError = addAttachments(attachments, to: draft)
        return true
    }

    private func attachDroppedFiles(_ providers: [NSItemProvider], to draft: Binding<NotchComposerInput>) -> Bool {
        guard !isAttaching, !providers.isEmpty else { return false }
        vm.dropEvent = true
        pasteError = nil
        isAttaching = true
        let targetID = selectedID
        let count = providers.count
        let (results, continuation) = AsyncStream.makeStream(of: (Int, NotchAttachment?).self)
        for (index, provider) in providers.enumerated() {
            NotchAttachment.load(provider) { attachment in
                continuation.yield((index, attachment))
            }
        }
        Task { @MainActor in
            defer {
                continuation.finish()
                isAttaching = false
            }
            var attachments = [NotchAttachment?](repeating: nil, count: count)
            for await (index, attachment) in results.prefix(count) { attachments[index] = attachment }
            let error = addAttachments(attachments, to: draft)
            if selectedID == targetID { pasteError = error }
        }
        return true
    }

    private func addAttachments(_ attachments: [NotchAttachment?], to draft: Binding<NotchComposerInput>) -> String? {
        var input = draft.wrappedValue
        var error: String?
        for attachment in attachments {
            switch attachment {
            case .screenshot(let data) where input.screenshots.count < NotchScreenshot.limit:
                input.screenshots.append(data)
            case .screenshot:
                error = "You can attach up to \(NotchScreenshot.limit) screenshots per question."
            case .file(let url):
                input.files.append(url)
            case nil:
                error = "An attachment couldn’t be opened. Choose a file or screenshot."
            }
        }
        draft.wrappedValue = input
        return error
    }
}

private struct ChatPromptField: NSViewRepresentable {
    @Binding var text: String
    var pasteAttachments: (NSPasteboard) -> Bool
    var submit: () -> Void

    final class Editor: NSTextView {
        var pasteAttachments: (NSPasteboard) -> Bool = { _ in false }
        var submit: () -> Void = {}

        override var needsPanelToBecomeKey: Bool { true }

        override func paste(_ sender: Any?) {
            if pasteAttachments(NSPasteboard.general) { return }
            super.paste(sender)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if window?.firstResponder === self, event.keyCode == 36, event.modifierFlags.contains(.command) {
                submit()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView {
                text.wrappedValue = editor.string
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay

        let editor = Editor(frame: scroll.bounds)
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.font = .systemFont(ofSize: 12)
        editor.textContainerInset = NSSize(width: 0, height: 3)
        editor.isVerticallyResizable = true
        editor.minSize = NSSize(width: 0, height: 24)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("Codex question")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? Editor else { return }
        if editor.string != text { editor.string = text }
        editor.pasteAttachments = pasteAttachments
        editor.submit = submit
        context.coordinator.text = $text
    }
}

struct NotchChatCompletionChip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var dismissalTask: Task<Void, Never>?

    var body: some View {
        Label("Chat finished", systemImage: "checkmark.circle.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: chatCompletionChipTravel - 5)
            .background(.black, in: .capsule)
            .fixedSize()
            .offset(y: isVisible || reduceMotion ? chatCompletionChipTravel : 0)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(!isVisible)
            .onReceive(NotchChats.shared.chatCompleted) {
                dismissalTask?.cancel()
                let animation = Animation.easeInOut(duration: reduceMotion ? 0.15 : 0.3)
                withAnimation(animation) { isVisible = true }
                dismissalTask = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    withAnimation(animation) { isVisible = false }
                }
            }
            .onDisappear {
                dismissalTask?.cancel()
                isVisible = false
            }
    }
}

struct NotchActiveIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blinking = false

    var body: some View {
        Capsule()
            .fill(Color(red: 0.44, green: 0.58, blue: 0.68))
            .frame(width: 2, height: 12)
            .opacity(blinking ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: reduceMotion) {
                blinking = false
                guard !reduceMotion else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(4)) } catch { break }
                    withAnimation(.easeInOut(duration: 0.2)) { blinking = true }
                    do { try await Task.sleep(for: .milliseconds(320)) } catch { break }
                    withAnimation(.easeInOut(duration: 0.3)) { blinking = false }
                }
            }
    }
}
