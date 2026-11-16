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
        let input: NotchComposerInput
        let threadID: String?
        let model: String?
        let effort: String?
        let serviceTier: String?
    }

    struct Model: Identifiable {
        let id: String
        let name: String
        let isDefault: Bool
        let efforts: [String]
        let defaultEffort: String?
        let supportsImages: Bool
        let fastTier: String?
        let fastDescription: String?

        init?(_ value: CodexJSON) {
            guard let id = value["model"] as? String, value["hidden"] as? Bool != true else { return nil }
            self.id = id
            name = value["displayName"] as? String ?? id
            isDefault = value["isDefault"] as? Bool ?? false
            efforts = (value["supportedReasoningEfforts"] as? [CodexJSON] ?? []).compactMap { $0["reasoningEffort"] as? String }
            defaultEffort = value["defaultReasoningEffort"] as? String
            supportsImages = (value["inputModalities"] as? [String])?.contains("image") ?? true
            let fast = (value["serviceTiers"] as? [CodexJSON])?.first { $0["name"] as? String == "Fast" }
            let legacyFast = (value["additionalSpeedTiers"] as? [String])?.contains("fast") == true
            fastTier = (fast?["id"] as? String) ?? (legacyFast ? "priority" : nil)
            fastDescription = fast?["description"] as? String
        }
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
    @Published private(set) var models: [Model] = []
    @Published private(set) var modelID: String?
    @Published var effort: String?
    @Published var fastMode = false
    @Published var newInput = NotchComposerInput()
    @Published var replyInputs: [String: NotchComposerInput] = [:]

    let chatCompleted = PassthroughSubject<Void, Never>()

    private let connection = CodexConnection()
    private let outcomesKey = "interestingNotch.codex.outcomes"
    private let clearedOutcome = "cleared"
    private lazy var outcomes = UserDefaults.standard.dictionary(forKey: outcomesKey) as? [String: String] ?? [:]
    private var managedThreads: Set<String> = []
    private var sendingThreads: Set<String> = []
    private var startedTurns: Set<String> = []
    private var activeTurns: Set<String> = []
    private var privateWriters: [String: CodexConnection] = [:]
    @Published private var releases: [String: Task<Void, Never>] = [:]
    private var isRefreshing = false

    private init() {
        connection.onMessage = { [weak self, weak connection] message in
            if let connection { self?.receive(message, from: connection) }
        }
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

    private var clearableChatIDs: [String] {
        outcomes.keys.filter { id in
            outcomes[id] == Status.done.rawValue && (chats[id]?.status ?? .done) == .done
        }
    }

    var hasFinishedNotchChats: Bool { !clearableChatIDs.isEmpty }

    func clearFinishedChats() {
        for id in clearableChatIDs {
            outcomes[id] = clearedOutcome
            chats[id]?.status = .history
        }
        UserDefaults.standard.set(outcomes, forKey: outcomesKey)
    }

    var selectedModel: Model? {
        models.first { $0.id == modelID } ?? models.first(where: \.isDefault) ?? models.first
    }

    func selectModel(_ id: String?) {
        modelID = models.contains { $0.id == id } ? id : nil
        if let effort, selectedModel?.efforts.contains(effort) != true { self.effort = nil }
        if selectedModel?.fastTier == nil { fastMode = false }
    }

    func connect() async {
        guard !isConnected, !isConnecting else { return }
        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }
        do {
            sharedServer = try await connection.connect()
            isConnected = true
            await loadModels()
            await refresh()
        } catch {
            connection.close()
            connectionLost(error.localizedDescription)
        }
    }

    private func loadModels() async {
        do {
            var catalog: [Model] = []
            var cursor: String?
            repeat {
                let params: CodexJSON = cursor.map { ["cursor": $0] } ?? [:]
                let result = try await connection.request("model/list", params)
                catalog += (result["data"] as? [CodexJSON] ?? []).compactMap(Model.init)
                cursor = result["nextCursor"] as? String
            } while cursor != nil
            models = catalog
            selectModel(modelID)
        } catch {
            models = []
            selectModel(nil)
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

    func canSubmit(_ input: NotchComposerInput, in id: String? = nil) -> Bool {
        guard isConnected, !isConnecting, !input.isEmpty,
              input.screenshots.isEmpty || selectedModel?.supportsImages != false else { return false }
        guard let id else { return true }
        return chats[id]?.canOpenInDesktop == true
            && !sendingThreads.contains(id) && !activeTurns.contains(id) && releases[id] == nil
            && chats[id]?.status != .running && requests.allSatisfy { $0.threadID != id } && failedDrafts[id] == nil
    }

    func submit(in threadID: String? = nil) {
        let input = threadID.map { replyInputs[$0, default: NotchComposerInput()] } ?? newInput
        guard canSubmit(input, in: threadID) else { return }
        let fastTier = fastMode ? selectedModel?.fastTier : nil
        let requestedModel = modelID ?? ((effort != nil || fastTier != nil) ? selectedModel?.id : nil)
        let draft = Draft(
            input: input,
            threadID: threadID,
            model: requestedModel,
            effort: effort ?? (requestedModel == nil ? nil : selectedModel?.defaultEffort),
            serviceTier: fastTier ?? (selectedModel?.fastTier == nil ? nil : "default")
        )
        let pendingID = threadID ?? UUID().uuidString
        let now = Date().timeIntervalSince1970
        let title = String(input.question.prefix(160))
        if let threadID {
            replyInputs[threadID] = nil
            chats[threadID]?.status = .running
        } else {
            chats[pendingID] = Chat(id: pendingID, title: title, status: .running, updatedAt: now, canOpenInDesktop: false)
            newInput = NotchComposerInput()
        }
        sendingThreads.insert(pendingID)

        Task {
            var chatID = pendingID
            defer {
                sendingThreads.remove(pendingID)
                sendingThreads.remove(chatID)
                startedTurns.remove(chatID)
                releaseIdleChat(chatID)
            }
            do {
                let items = try draft.input.turnItems()
                let writer = try await connectWriter(for: pendingID)
                if let threadID {
                    let result = try await writer.request("thread/resume", ["threadId": threadID])
                    managedThreads.insert(threadID)
                    let thread = result["thread"] as? CodexJSON
                    let status = thread?["status"] as? CodexJSON
                    guard status?["type"] as? String != "active" else {
                        throw CodexConnection.Failure(message: "Wait for this chat to finish its current reply, then restore your draft.")
                    }
                } else {
                    var params: CodexJSON = ["approvalPolicy": "on-request", "sandbox": "read-only", "serviceName": "interesting_notch"]
                    if let model = draft.model { params["model"] = model }
                    let result = try await writer.request("thread/start", params)
                    guard let thread = result["thread"] as? CodexJSON, let id = thread["id"] as? String else {
                        throw CodexConnection.Failure(message: "Codex didn’t return a chat ID.")
                    }
                    chatID = id
                    privateWriters[id] = privateWriters.removeValue(forKey: pendingID)
                    sendingThreads.insert(id)
                    chats[pendingID] = nil
                    chats[id] = Chat(id: id, title: title, status: .running, updatedAt: now)
                }
                managedThreads.insert(chatID)
                activeTurns.insert(chatID)
                var turn: CodexJSON = [
                    "threadId": chatID, "input": items,
                    "approvalPolicy": "on-request", "sandboxPolicy": ["type": "readOnly"]
                ]
                if let model = draft.model { turn["model"] = model }
                if let effort = draft.effort { turn["effort"] = effort }
                if let tier = draft.serviceTier { turn["serviceTier"] = tier }
                _ = try await writer.request("turn/start", turn)
            } catch {
                guard !startedTurns.contains(chatID) else { return }
                activeTurns.remove(chatID)
                failedDrafts[chatID] = draft
                chats[chatID]?.status = .attention
                let message = error.localizedDescription
                chats[chatID]?.detail = message.contains("already has an active writer")
                    ? "Close this chat in the other app, then restore your draft and try again."
                    : message
            }
        }
    }

    func canRestoreDraft(_ id: String) -> Bool {
        guard let draft = failedDrafts[id] else { return false }
        return (draft.threadID.map { replyInputs[$0, default: NotchComposerInput()] } ?? newInput).isEmpty
    }

    func restoreDraft(_ id: String) {
        guard canRestoreDraft(id), let draft = failedDrafts.removeValue(forKey: id) else { return }
        if let threadID = draft.threadID {
            replyInputs[threadID] = draft.input
        } else {
            newInput = draft.input
        }
        selectModel(draft.model)
        effort = draft.effort.flatMap { selectedModel?.efforts.contains($0) == true ? $0 : nil }
        fastMode = draft.serviceTier != nil && draft.serviceTier == selectedModel?.fastTier
        if chats[id]?.canOpenInDesktop == false {
            chats[id] = nil
        } else {
            chats[id]?.status = .history
            chats[id]?.detail = ""
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

    func openInDesktop(_ id: String) async throws {
        if privateWriters[id] != nil {
            releaseIdleChat(id)
            await releases[id]?.value
            guard privateWriters[id] == nil else {
                throw CodexConnection.Failure(message: "Wait for this chat to finish its current reply, then open it again.")
            }
        }
        guard UUID(uuidString: id) != nil, let url = URL(string: "codex://threads/" + id), NSWorkspace.shared.open(url) else {
            throw CodexConnection.Failure(message: "Couldn’t open this chat in the ChatGPT desktop app.")
        }
    }

    private func connectWriter(for id: String) async throws -> CodexConnection {
        if sharedServer { return connection }
        // Each local turn has its own process, so releasing one chat leaves other turns running.
        let writer = CodexConnection()
        privateWriters[id] = writer
        writer.onMessage = { [weak self, weak writer] message in
            if let writer { self?.receive(message, from: writer) }
        }
        writer.onDisconnect = { [weak self, weak writer] message in
            guard let self, let writer, let id = self.privateWriters.first(where: { $0.value === writer })?.key else { return }
            self.privateWriters[id] = nil
            self.managedThreads.remove(id)
            self.requests.removeAll { $0.threadID == id }
            if self.activeTurns.remove(id) != nil {
                self.chats[id]?.status = .attention
                self.chats[id]?.detail = message
            }
        }
        _ = try await writer.connect()
        return writer
    }

    private func releaseIdleChat(_ id: String) {
        guard !activeTurns.contains(id), !sendingThreads.contains(id), releases[id] == nil else { return }
        let writer = privateWriters[id]
        guard writer != nil || managedThreads.contains(id) else { return }
        releases[id] = Task {
            defer { releases[id] = nil }
            do {
                if let writer {
                    try await writer.stopLocalSession()
                    writer.close()
                    privateWriters[id] = nil
                } else {
                    _ = try await connection.request("thread/unsubscribe", ["threadId": id])
                }
                managedThreads.remove(id)
            } catch {
                connectionError = error.localizedDescription
            }
        }
    }

    func respond(_ request: Attention, accept: Bool, answers: [String: String] = [:]) {
        let connection = privateWriters[request.threadID] ?? self.connection
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
                let wasRunning = chats[id]?.status == .running
                let status: Status = sharedServer && outcomes[id] != clearedOutcome ? .done : savedStatus(id)
                chats[id]?.status = status
                if wasRunning, status == .done { chatCompleted.send() }
            }
        case "notLoaded":
            if !managedThreads.contains(id), chats[id]?.status != .done {
                chats[id]?.status = savedStatus(id)
            }
        default:
            break
        }
    }

    private func receive(_ message: CodexJSON, from source: CodexConnection) {
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? CodexJSON ?? [:]
        if let id = message["id"] {
            receiveRequest(method, id: id, params: params, from: source)
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
            guard let turn = params["turn"] as? CodexJSON else { return }
            if sendingThreads.contains(id) { startedTurns.insert(id) }
            let sentFromNotch = activeTurns.remove(id) != nil
            defer { releaseIdleChat(id) }
            requests.removeAll { $0.threadID == id }
            guard let chat = chats[id] else { return }
            let status: Status = turn["status"] as? String == "completed" ? .done : .attention
            chats[id]?.status = status
            chats[id]?.updatedAt = Date().timeIntervalSince1970
            if status == .attention {
                let error = turn["error"] as? CodexJSON
                chats[id]?.detail = error?["message"] as? String ?? "This request ended before it completed."
            }
            if sentFromNotch {
                outcomes[id] = status.rawValue
                UserDefaults.standard.set(outcomes, forKey: outcomesKey)
            }
            if status == .done, chat.status != .done { chatCompleted.send() }
        case "item/completed":
            if let item = params["item"] as? CodexJSON,
               item["type"] as? String == "agentMessage", let text = item["text"] as? String {
                chats[id]?.detail = String(text.prefix(12_000))
            }
        case "serverRequest/resolved":
            if let requestID = params["requestId"] {
                requests.removeAll { $0.threadID == id && String(describing: $0.wireID) == String(describing: requestID) }
            }
        case "thread/archived", "thread/deleted":
            chats[id] = nil
        default:
            break
        }
    }

    private func receiveRequest(_ method: String, id: Any, params: CodexJSON, from connection: CodexConnection) {
        guard let threadID = params["threadId"] as? String else {
            connection.declineUnknownRequest(id)
            return
        }
        let key = threadID + ":" + String(describing: id)
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
        requests.removeAll { privateWriters[$0.threadID] == nil }
        managedThreads.formIntersection(privateWriters.keys)
        activeTurns.formIntersection(privateWriters.keys)
        for id in Array(chats.keys) where chats[id]?.status == .running || chats[id]?.status == .attention {
            if failedDrafts[id] == nil, privateWriters[id] == nil {
                chats[id]?.status = .history
            }
        }
    }
}
