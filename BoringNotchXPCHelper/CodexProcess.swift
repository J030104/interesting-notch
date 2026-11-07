import AppKit
import Foundation

/// Runs the local Codex transport on behalf of the sandboxed notch.
final class CodexProcess {
    private let queue = DispatchQueue(label: "InterestingNotch.CodexProcess")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?

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
            let socket = home.appending(path: ".codex/app-server-control/app-server.sock")
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
                    if bytes.isEmpty {
                        self.close()
                        events.codexEnded()
                    } else {
                        events.codexOutput(bytes)
                    }
                }
            }
            reply(shared, nil)
        }
    }

    func write(_ data: Data, reply: @escaping (Bool) -> Void) {
        queue.async {
            guard let input = self.input else {
                reply(false)
                return
            }
            do {
                try input.write(contentsOf: data)
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
        output?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        if let process, process.isRunning { process.terminate() }
        output = nil
        input = nil
        process = nil
    }
}
