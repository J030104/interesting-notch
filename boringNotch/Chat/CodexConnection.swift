import Foundation

typealias CodexJSON = [String: Any]

@MainActor
final class CodexConnection {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class Events: NSObject, CodexProcessEvents {
        let output: (Data) -> Void
        let ended: () -> Void

        init(output: @escaping (Data) -> Void, ended: @escaping () -> Void) {
            self.output = output
            self.ended = ended
        }

        func codexOutput(_ data: Data) { output(data) }
        func codexEnded() { ended() }
    }

    private struct Request {
        let continuation: CheckedContinuation<CodexJSON, Error>
        let timeout: Task<Void, Never>
    }

    private var connection: NSXPCConnection?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: Request] = [:]
    private var generation = UUID()
    var onMessage: (CodexJSON) -> Void = { _ in }
    var onDisconnect: (String) -> Void = { _ in }

    func connect() async throws -> Bool {
        let generation = UUID()
        self.generation = generation
        let connection = NSXPCConnection(serviceName: XPCHelperClient.serviceName)
        self.connection = connection
        connection.remoteObjectInterface = NSXPCInterface(with: BoringNotchXPCHelperProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: CodexProcessEvents.self)
        connection.exportedObject = Events(output: { [weak self] bytes in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.receive(bytes)
            }
        }, ended: { [weak self] in
            DispatchQueue.main.async {
                self?.disconnect(generation, message: "The local Codex server closed.")
            }
        })
        let onLoss: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.disconnect(generation, message: "The Codex connection was interrupted.")
            }
        }
        connection.interruptionHandler = onLoss
        connection.invalidationHandler = onLoss
        connection.resume()

        let shared: Bool = try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                continuation.resume(throwing: Failure(message: "Couldn’t open the Codex helper."))
            } as? BoringNotchXPCHelperProtocol
            guard let proxy else {
                continuation.resume(throwing: Failure(message: "The Codex helper is unavailable."))
                return
            }
            proxy.startCodex { shared, error in
                if let error {
                    continuation.resume(throwing: Failure(message: error))
                } else {
                    continuation.resume(returning: shared)
                }
            }
        }

        guard generation == self.generation else { throw CancellationError() }
        _ = try await request("initialize", [
            "clientInfo": ["name": "interesting_notch", "title": "Interesting Notch", "version": "0.1.0"],
            "capabilities": ["optOutNotificationMethods": [
                "item/reasoning/textDelta", "item/reasoning/summaryTextDelta", "item/commandExecution/outputDelta"
            ]]
        ])
        try send(["method": "initialized"])
        return shared
    }

    func request(_ method: String, _ params: CodexJSON = [:]) async throws -> CodexJSON {
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.finish(id, result: .failure(Failure(message: "Codex didn’t confirm the request.")))
            }
            pending[id] = Request(continuation: continuation, timeout: timeout)
            do {
                try send(["id": id, "method": method, "params": params])
            } catch {
                finish(id, result: .failure(error))
            }
        }
    }

    func respond(to id: Any, result: CodexJSON) {
        try? send(["id": id, "result": result])
    }

    func declineUnknownRequest(_ id: Any) {
        try? send(["id": id, "error": ["code": -32601, "message": "This request is unavailable in Interesting Notch."]])
    }

    private func send(_ message: CodexJSON) throws {
        let generation = generation
        let proxy = connection?.remoteObjectProxyWithErrorHandler { [weak self] _ in
            DispatchQueue.main.async {
                self?.disconnect(generation, message: "Couldn’t send a message to Codex.")
            }
        } as? BoringNotchXPCHelperProtocol
        guard let proxy else { throw Failure(message: "Connect to Codex first.") }
        var bytes = try JSONSerialization.data(withJSONObject: message)
        bytes.append(0x0A)
        proxy.writeCodex(bytes) { [weak self] sent in
            if !sent {
                DispatchQueue.main.async {
                    self?.disconnect(generation, message: "Couldn’t send a message to Codex.")
                }
            }
        }
    }

    func close() {
        generation = UUID()
        connection?.invalidate()
        connection = nil
        buffer.removeAll()
        for id in Array(pending.keys) {
            finish(id, result: .failure(Failure(message: "The Codex connection closed.")))
        }
    }

    private func disconnect(_ generation: UUID, message: String) {
        guard generation == self.generation else { return }
        close()
        onDisconnect(message)
    }

    private func finish(_ id: Int, result: Result<CodexJSON, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }

    private func receive(_ bytes: Data) {
        buffer.append(bytes)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let frame = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let message = (try? JSONSerialization.jsonObject(with: frame)) as? CodexJSON else { continue }
            if message["method"] != nil {
                onMessage(message)
            } else if let id = message["id"] as? Int {
                if let error = message["error"] as? CodexJSON {
                    finish(id, result: .failure(Failure(message: error["message"] as? String ?? "Codex rejected the request.")))
                } else {
                    finish(id, result: .success(message["result"] as? CodexJSON ?? [:]))
                }
            }
        }
        if buffer.count > 32 * 1024 * 1024 {
            disconnect(generation, message: "A Codex message was too large to display.")
        }
    }
}
