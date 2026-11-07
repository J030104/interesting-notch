import AppKit
import Foundation

/// Runs the local Codex transport on behalf of the sandboxed notch.
final class CodexProcess {
    private let queue = DispatchQueue(label: "InterestingNotch.CodexProcess")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var webSocket: CodexWebSocket?
    private var startReply: ((Bool, String?) -> Void)?

    func start(events: CodexProcessEvents, reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            guard self.process == nil else {
                reply(false, "Codex is already connected.")
                return
            }
            let files = FileManager.default
            let desktop = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
            let candidates = [
                desktop?.appending(path: "Contents/Resources/codex-cli/bin/codex"),
                URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                URL(fileURLWithPath: "/usr/local/bin/codex")
            ].compactMap { $0 }
            guard let executable = candidates.first(where: { files.isExecutableFile(atPath: $0.path) }) else {
                reply(false, "Install the ChatGPT desktop app or the Codex CLI to connect.")
                return
            }

            let home = files.homeDirectoryForCurrentUser
            let socket = home.appending(path: ".codex/app-server-control/app-server-control.sock")
            let socketType = try? files.attributesOfItem(atPath: socket.path)[.type] as? FileAttributeType
            let shared = socketType == .typeSocket

            let process = Process()
            let stdin = Pipe()
            let stdout = Pipe()
            process.executableURL = executable
            process.arguments = shared ? ["app-server", "proxy", "--sock", socket.path] : ["app-server", "--stdio"]
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice

            do {
                if !shared {
                    let workspace = home.appending(path: "Library/Application Support/Interesting Notch/Chats")
                    try files.createDirectory(at: workspace, withIntermediateDirectories: true)
                    process.currentDirectoryURL = workspace
                }
                try process.run()
            } catch {
                reply(false, "Couldn’t start Codex. Check that it opens on this Mac.")
                return
            }

            self.process = process
            self.input = stdin.fileHandleForWriting
            self.output = stdout.fileHandleForReading

            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                self?.queue.async { [weak self] in
                    guard let self, self.output === handle else { return }
                    self.receive(bytes, events: events)
                }
            }
            if shared {
                let webSocket = CodexWebSocket()
                self.webSocket = webSocket
                self.startReply = reply
                do {
                    try self.input?.write(contentsOf: webSocket.handshake)
                } catch {
                    self.close()
                    return
                }
                self.queue.asyncAfter(deadline: .now() + 10) { [weak self, weak process] in
                    guard let self, self.process === process, self.startReply != nil else { return }
                    self.close()
                }
            } else {
                reply(false, nil)
            }
        }
    }

    private func receive(_ bytes: Data, events: CodexProcessEvents) {
        if bytes.isEmpty {
            close()
            events.codexEnded()
            return
        }
        guard webSocket != nil else {
            events.codexOutput(bytes)
            return
        }
        do {
            for event in try webSocket?.receive(bytes) ?? [] {
                switch event {
                case .connected:
                    let reply = startReply
                    startReply = nil
                    reply?(true, nil)
                case .message(var data):
                    data.append(0x0A)
                    events.codexOutput(data)
                case .ping(let payload):
                    try input?.write(contentsOf: CodexWebSocket.frame(payload, opcode: 10))
                case .closed:
                    close()
                    events.codexEnded()
                    return
                }
            }
        } catch {
            close()
            events.codexEnded()
        }
    }

    func write(_ data: Data, reply: @escaping (Bool) -> Void) {
        queue.async {
            guard let input = self.input else {
                reply(false)
                return
            }
            do {
                let payload = self.webSocket == nil ? data : CodexWebSocket.frame(Data(data.dropLast()))
                try input.write(contentsOf: payload)
                reply(true)
            } catch {
                reply(false)
            }
        }
    }

    func stop() {
        queue.async { self.close() }
    }

    private func close() {
        let reply = startReply
        startReply = nil
        reply?(false, "Couldn’t connect to the shared Codex server.")
        webSocket = nil
        output?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        if let process, process.isRunning { process.terminate() }
        output = nil
        input = nil
        process = nil
    }
}
