import AppKit
import Combine
import Foundation

@MainActor
final class NotchChats: ObservableObject {
    static let shared = NotchChats()

    enum Status: String, CaseIterable {
        case running = "Ongoing"
        case attention = "Needs attention"
        case done = "Done"
        case history = "History"
    }

    struct Chat: Identifiable {
        let id: String
        var title: String
        var status: Status
        var updatedAt: TimeInterval
        var detail = ""
        var canOpenInDesktop = true
    }

    struct Draft {
        let prompt: String
        let image: Data?
    }

    struct Question: Identifiable {
        let id: String
        let text: String
        let options: [String]
    }

    struct Attention: Identifiable {
        enum Kind { case command, questions }

        let id: String
        let wireID: Any
        let threadID: String
        let kind: Kind
        let message: String
        var questions: [Question] = []
    }

    @Published private(set) var chats: [String: Chat] = [:]
    @Published private(set) var requests: [Attention] = []
    @Published private(set) var failedDrafts: [String: Draft] = [:]
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var sharedServer = false
    @Published private(set) var connectionError: String?
    @Published var prompt = ""
    @Published var screenshot: Data?

    private let connection = CodexConnection()
    private let outcomesKey = "interestingNotch.codex.outcomes"
    private lazy var outcomes = UserDefaults.standard.dictionary(forKey: outcomesKey) as? [String: String] ?? [:]
    private var managedThreads: Set<String> = []
    private var sendingThreads: Set<String> = []
    private var startedTurns: Set<String> = []
    private var isRefreshing = false

    private init() {
        connection.onMessage = { [weak self] in self?.receive($0) }
        connection.onDisconnect = { [weak self] in self?.connectionLost($0) }
    }

    var orderedChats: [Chat] {
        let order: [Status] = [.attention, .running, .done, .history]
        let ordered = order.flatMap { status in
            chats.values.filter { $0.status == status }.sorted { $0.updatedAt > $1.updatedAt }
        }
        return ordered
    }

    func count(_ status: Status) -> Int {
        chats.values.count(where: { $0.status == status })
    }

    func connect() async {
        guard !isConnected, !isConnecting else { return }
        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }
        do {
            sharedServer = try await connection.connect()
            isConnected = true
            await refresh()
        } catch {
            connection.close()
            connectionLost(error.localizedDescription)
        }
    }

    func refresh() async {
        guard isConnected, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let result = try await connection.request("thread/list", [
                "limit": 40, "sortKey": "updated_at",
                "sourceKinds": ["appServer", "cli", "vscode", "exec", "unknown"]
            ])
            var listed: Set<String> = []
            for thread in result["data"] as? [CodexJSON] ?? [] {
                guard let id = thread["id"] as? String else { continue }
                listed.insert(id)
                let name = (thread["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = thread["preview"] as? String ?? ""
                let title = (name?.isEmpty == false ? name : nil) ?? (preview.isEmpty ? "Untitled chat" : preview)
                let time = thread["updatedAt"] as? TimeInterval ?? 0
                if chats[id] == nil {
                    chats[id] = Chat(id: id, title: String(title.prefix(160)), status: savedStatus(id), updatedAt: time)
                } else if !preview.isEmpty || name?.isEmpty == false {
                    chats[id]?.title = String(title.prefix(160))
                }
                if let status = thread["status"] as? CodexJSON {
                    applyRuntimeStatus(status, to: id)
                }
            }
            if sharedServer {
                try await includeLoadedChats(excluding: listed)
            }
            connectionError = nil
        } catch {
            if isConnected { connectionError = error.localizedDescription }
        }
    }

    func submit() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !trimmed.isEmpty || screenshot != nil else { return }
        let draft = Draft(
            prompt: trimmed.isEmpty ? "Please explain this screenshot." : trimmed,
            image: screenshot
        )
        let pendingID = UUID().uuidString
        let now = Date().timeIntervalSince1970
        let title = String(draft.prompt.prefix(160))
        chats[pendingID] = Chat(id: pendingID, title: title, status: .running, updatedAt: now, canOpenInDesktop: false)
        prompt = ""
        screenshot = nil

        Task {
            var chatID = pendingID
            defer { startedTurns.remove(chatID) }
            do {
                let result = try await connection.request("thread/start", [
                    "approvalPolicy": "on-request", "sandbox": "read-only", "serviceName": "interesting_notch"
                ])
                guard let thread = result["thread"] as? CodexJSON, let id = thread["id"] as? String else {
                    throw CodexConnection.Failure(message: "Codex didn’t return a chat ID.")
                }
                chatID = id
                managedThreads.insert(id)
                sendingThreads.insert(id)
                defer {
                    sendingThreads.remove(id)
                }
                chats[pendingID] = nil
                chats[id] = Chat(id: id, title: title, status: .running, updatedAt: now)
                var input: [CodexJSON] = [["type": "text", "text": draft.prompt]]
                if let image = draft.image {
                    input.append(["type": "image", "url": "data:image/png;base64," + image.base64EncodedString()])
                }
                _ = try await connection.request("turn/start", ["threadId": id, "input": input])
            } catch {
                guard !startedTurns.contains(chatID) else { return }
                failedDrafts[chatID] = draft
                chats[chatID]?.status = .attention
                chats[chatID]?.detail = error.localizedDescription
            }
        }
    }

    func restoreDraft(_ id: String) {
        guard prompt.isEmpty, screenshot == nil, let draft = failedDrafts.removeValue(forKey: id) else { return }
        prompt = draft.prompt
        screenshot = draft.image
        if chats[id]?.canOpenInDesktop == false {
            chats[id] = nil
        } else {
            chats[id]?.status = .history
        }
    }

    func loadReply(_ id: String) async {
        guard let chat = chats[id], chat.canOpenInDesktop, chat.detail.isEmpty, isConnected else { return }
        do {
            let result = try await connection.request("thread/turns/list", ["threadId": id, "limit": 1, "itemsView": "full"])
            guard let turn = (result["data"] as? [CodexJSON])?.first else { return }
            let replies = (turn["items"] as? [CodexJSON])?.filter { $0["type"] as? String == "agentMessage" }
            if let reply = replies?.last?["text"] as? String, chats[id]?.detail.isEmpty == true {
                chats[id]?.detail = String(reply.prefix(12_000))
            }
        } catch {
            // A new chat may not yet have a stored turn. Live events supply the reply.
        }
    }

    func respond(_ request: Attention, accept: Bool, answers: [String: String] = [:]) {
        switch request.kind {
        case .command:
            connection.respond(to: request.wireID, result: ["decision": accept ? "accept" : "decline"])
        case .questions:
            connection.respond(to: request.wireID, result: [
                "answers": accept ? answers.mapValues { ["answers": [$0]] } : [:]
            ])
        }
        requests.removeAll { $0.id == request.id }
    }

    private func includeLoadedChats(excluding listed: Set<String>) async throws {
        let result = try await connection.request("thread/loaded/list")
        let loaded = Set(result["data"] as? [String] ?? [])
        for id in loaded.subtracting(listed) {
            let value = try await connection.request("thread/read", ["threadId": id])
            guard let thread = value["thread"] as? CodexJSON else { continue }
            if chats[id] == nil {
                let title = thread["name"] as? String ?? thread["preview"] as? String ?? "Untitled chat"
                chats[id] = Chat(id: id, title: String(title.prefix(160)), status: savedStatus(id), updatedAt: thread["updatedAt"] as? TimeInterval ?? 0)
            }
            if let status = thread["status"] as? CodexJSON { applyRuntimeStatus(status, to: id) }
        }
        for id in Set(chats.keys).subtracting(loaded).subtracting(listed) {
            if chats[id]?.status == .running || chats[id]?.status == .attention {
                applyRuntimeStatus(["type": "notLoaded"], to: id)
            }
        }
    }

    private func savedStatus(_ id: String) -> Status {
        outcomes[id].flatMap(Status.init(rawValue:)) ?? .history
    }

    private func applyRuntimeStatus(_ status: CodexJSON, to id: String) {
        guard !sendingThreads.contains(id), failedDrafts[id] == nil else { return }
        switch status["type"] as? String {
        case "active":
            let flags = status["activeFlags"] as? [String] ?? []
            chats[id]?.status = flags.isEmpty ? .running : .attention
        case "systemError":
            chats[id]?.status = .attention
        case "idle":
            if !managedThreads.contains(id) {
                chats[id]?.status = sharedServer ? .done : savedStatus(id)
            }
        case "notLoaded":
            if !managedThreads.contains(id), chats[id]?.status != .done {
                chats[id]?.status = savedStatus(id)
            }
        default:
            break
        }
    }

    private func receive(_ message: CodexJSON) {
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? CodexJSON ?? [:]
        if let id = message["id"] {
            receiveRequest(method, id: id, params: params)
            return
        }
        guard let id = params["threadId"] as? String else { return }
        switch method {
        case "thread/status/changed":
            if let status = params["status"] as? CodexJSON { applyRuntimeStatus(status, to: id) }
        case "turn/started":
            if sendingThreads.contains(id) { startedTurns.insert(id) }
            chats[id]?.status = .running
        case "turn/completed":
            guard chats[id] != nil, let turn = params["turn"] as? CodexJSON else { return }
            if sendingThreads.contains(id) { startedTurns.insert(id) }
            let status: Status = turn["status"] as? String == "completed" ? .done : .attention
            chats[id]?.status = status
            chats[id]?.updatedAt = Date().timeIntervalSince1970
            if status == .attention {
                let error = turn["error"] as? CodexJSON
                chats[id]?.detail = error?["message"] as? String ?? "This request ended before it completed."
            }
            if managedThreads.contains(id) {
                outcomes[id] = status.rawValue
                UserDefaults.standard.set(outcomes, forKey: outcomesKey)
            }
            requests.removeAll { $0.threadID == id }
        case "item/completed":
            if let item = params["item"] as? CodexJSON,
               item["type"] as? String == "agentMessage", let text = item["text"] as? String {
                chats[id]?.detail = String(text.prefix(12_000))
            }
        case "serverRequest/resolved":
            if let requestID = params["requestId"] {
                requests.removeAll { $0.id == String(describing: requestID) }
            }
        case "thread/archived", "thread/deleted":
            chats[id] = nil
        default:
            break
        }
    }

    private func receiveRequest(_ method: String, id: Any, params: CodexJSON) {
        guard let threadID = params["threadId"] as? String else {
            connection.declineUnknownRequest(id)
            return
        }
        let key = String(describing: id)
        let reason = params["reason"] as? String ?? ""
        switch method {
        case "item/commandExecution/requestApproval":
            let network = params["networkApprovalContext"] as? CodexJSON
            let scope = network?["host"] as? String
            let command = params["command"] as? String
            guard let description = scope.map({ "Connect to " + $0 }) ?? command else {
                connection.respond(to: id, result: ["decision": "decline"])
                return
            }
            let cwd = params["cwd"] as? String ?? ""
            let message = [description, cwd, reason].filter { !$0.isEmpty }.joined(separator: "\n")
            requests.append(Attention(id: key, wireID: id, threadID: threadID, kind: .command, message: message))
        case "item/fileChange/requestApproval":
            connection.respond(to: id, result: ["decision": "decline"])
        case "item/permissions/requestApproval":
            connection.respond(to: id, result: ["permissions": [:], "scope": "turn"])
        case "mcpServer/elicitation/request":
            connection.respond(to: id, result: ["action": "decline", "content": NSNull()])
        case "item/tool/requestUserInput", "tool/requestUserInput":
            let questions = (params["questions"] as? [CodexJSON] ?? []).compactMap { value -> Question? in
                guard let id = value["id"] as? String, let text = value["question"] as? String else { return nil }
                let options = (value["options"] as? [CodexJSON])?.compactMap { $0["label"] as? String } ?? []
                return Question(id: id, text: text, options: options)
            }
            requests.append(Attention(id: key, wireID: id, threadID: threadID, kind: .questions, message: "Codex needs your input.", questions: questions))
        default:
            connection.declineUnknownRequest(id)
            return
        }
        chats[threadID]?.status = .attention
    }

    private func connectionLost(_ message: String) {
        isConnected = false
        connectionError = message
        requests.removeAll()
        managedThreads.removeAll()
        for id in Array(chats.keys) where chats[id]?.status == .running || chats[id]?.status == .attention {
            if failedDrafts[id] == nil {
                chats[id]?.status = .history
            }
        }
    }
}
