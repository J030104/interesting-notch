import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct NotchChatView: View {
    @ObservedObject private var model = NotchChats.shared
    @State private var selectedID: String?
    @State private var answers: [String: String] = [:]
    @State private var pasteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
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
                        composer
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Divider()
                chatList
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
    }

    private func counter(_ status: NotchChats.Status, icon: String, color: Color) -> some View {
        Label("\(model.count(status)) \(status.rawValue.lowercased())", systemImage: icon)
            .foregroundStyle(color)
            .fixedSize()
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                if let data = model.screenshot, let preview = NSImage(data: data) {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 44, height: 41)
                        .background(.white.opacity(0.09), in: .rect(cornerRadius: 4))
                        .accessibilityLabel("Attached screenshot")
                }
                ChatPromptField(text: $model.prompt, pasteImage: pasteImage, submit: submit)
                    .overlay(alignment: .topLeading) {
                        if model.prompt.isEmpty {
                            Text("Ask a question or paste a screenshot…")
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
            .frame(height: 55)
            .background(.white.opacity(0.08), in: .rect(cornerRadius: 6))

            HStack(spacing: 7) {
                Button {
                    _ = pasteImage(NSPasteboard.general)
                } label: {
                    Label(model.screenshot == nil ? "Paste screenshot" : "Replace screenshot", systemImage: "clipboard")
                }
                if model.screenshot != nil {
                    Button("Remove") { model.screenshot = nil }
                }
                Spacer(minLength: 1)
                if model.isConnected {
                    Button(action: submit) {
                        Label("Ask", systemImage: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.screenshot == nil && model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Start a new Codex chat (⌘↩)")
                } else {
                    Button(model.isConnecting ? "Connecting…" : "Connect") {
                        Task { await model.connect() }
                    }
                    .disabled(model.isConnecting)
                }
            }
            .controlSize(.small)

            if let message = pasteError ?? model.connectionError {
                Text(message)
                    .lineLimit(2)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(message)
            }
        }
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
                        if let url = URL(string: "codex://threads/" + chat.id), !NSWorkspace.shared.open(url) {
                            pasteError = "Couldn’t open this chat in the ChatGPT desktop app."
                            selectedID = nil
                        }
                    } label: {
                        Label("Open chat", systemImage: "arrow.up.right")
                    }
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
                    model.restoreDraft(chat.id)
                    selectedID = nil
                }
                .controlSize(.small)
                .disabled(!model.prompt.isEmpty || model.screenshot != nil)
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
                            ChatPromptField(text: answerBinding(question.id), pasteImage: { _ in false }, submit: {})
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

    private func submit() {
        pasteError = nil
        model.submit()
    }

    private func pasteImage(_ pasteboard: NSPasteboard) -> Bool {
        let png = pasteboard.data(forType: .png)
        guard let data = png ?? pasteboard.data(forType: .tiff) else {
            pasteError = "Copy a screenshot first with ⌃⇧⌘4."
            return false
        }
        pasteError = nil
        let maxBytes = 6 * 1024 * 1024
        if let png, png.count <= maxBytes {
            model.screenshot = png
            return true
        }
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            for pixels in [2400, 1600, 1200] {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { break }
                let png = NSMutableData()
                if let writer = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(writer, image, nil)
                    if CGImageDestinationFinalize(writer), png.length <= maxBytes {
                        model.screenshot = png as Data
                        return true
                    }
                }
            }
        }
        pasteError = "This screenshot couldn’t be attached."
        return true
    }
}

private struct ChatPromptField: NSViewRepresentable {
    @Binding var text: String
    var pasteImage: (NSPasteboard) -> Bool
    var submit: () -> Void

    final class Editor: NSTextView {
        var pasteImage: (NSPasteboard) -> Bool = { _ in false }
        var submit: () -> Void = {}

        override var needsPanelToBecomeKey: Bool { true }

        override func paste(_ sender: Any?) {
            let pasteboard = NSPasteboard.general
            if pasteboard.availableType(from: [.png, .tiff]) != nil, pasteImage(pasteboard) { return }
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
        editor.pasteImage = pasteImage
        editor.submit = submit
        context.coordinator.text = $text
    }
}

struct NotchActiveIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blinking = false

    var body: some View {
        Capsule()
            .fill(Color(red: 0.44, green: 0.58, blue: 0.68))
            .frame(width: 2, height: 12)
            .opacity(blinking ? 0.95 : 0.52)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: reduceMotion) {
                blinking = false
                guard !reduceMotion else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(8)) } catch { break }
                    withAnimation(.easeInOut(duration: 0.2)) { blinking = true }
                    do { try await Task.sleep(for: .milliseconds(320)) } catch { break }
                    withAnimation(.easeInOut(duration: 0.3)) { blinking = false }
                }
            }
    }
}
