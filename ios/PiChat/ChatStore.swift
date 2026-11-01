import Foundation
import Observation

/// Keys for settings stored in UserDefaults (read by views via @AppStorage).
enum SettingsKey {
    static let serverURL = "serverURL"
    static let apiKey = "apiKey"
    static let model = "model"
    static let systemPrompt = "systemPrompt"
    static let thinking = "thinking"
    /// The chat that was open, to open it again at the next launch.
    static let currentChat = "currentChat"
    /// Let the model use the tools the Pi offers, such as web search.
    static let tools = "tools"
    /// Run tools without asking first each time.
    static let toolsAlwaysAllowed = "toolsAlwaysAllowed"

    static let defaultServerURL = "http://pi-llm.local:8080"
}

@MainActor
@Observable
final class ChatStore {
    /// Every saved chat, the most recent first.
    private(set) var chats: [ChatSummary] = []
    /// The chat on screen. Nil for a new chat, which is saved once something is asked.
    private(set) var currentChatID: UUID?
    /// The messages of the chat on screen.
    private(set) var messages: [ChatMessage] = []
    private(set) var isGenerating = false
    /// The chat the Pi is answering in. Opening another chat does not stop it.
    private(set) var generatingChatID: UUID?
    var models: [LlamaClient.ModelInfo] = []
    var connectionError: String?
    /// True when the last connection error was the network (no answer at all),
    /// false when the Pi answered with an error or the address is not valid.
    var connectionUnreachable = false
    /// The tools the Pi offers (GET /tools), such as web_search. Empty when it offers none.
    var serverTools: [ServerTool] = []
    /// The tool step that waits for the person to allow it, if any.
    private(set) var toolStepAwaitingApproval: UUID?

    /// The answer to "The model wants to search the web for …".
    enum ToolDecision { case allow, alwaysAllow, deny }

    /// Rounds of tool calls per question. After the last one the model has to
    /// answer with what it has, so a model that keeps searching cannot loop.
    static let maxToolRounds = 5

    @ObservationIgnored private var generation: Task<Void, Never>?
    @ObservationIgnored private var generationID = UUID()
    /// The messages of a chat still being answered while another is on screen.
    @ObservationIgnored private var background: [UUID: [ChatMessage]] = [:]
    @ObservationIgnored private var approval: CheckedContinuation<Bool, Never>?
    private let archive: ChatArchive
    private let defaults: UserDefaults

    /// The app uses the standard archive and settings; tests pass their own.
    init(archive: ChatArchive = .standard, defaults: UserDefaults = .standard) {
        self.archive = archive
        self.defaults = defaults
        chats = archive.loadIndex()
        if chats.isEmpty, let imported = archive.importSingleChat(from: archive.singleChatFile) {
            chats = [imported]
            archive.saveIndex(chats)
            defaults.set(imported.id.uuidString, forKey: SettingsKey.currentChat)
        }
        // Open the chat that was open last time.
        if let raw = defaults.string(forKey: SettingsKey.currentChat),
           let id = UUID(uuidString: raw),
           chats.contains(where: { $0.id == id }),
           let saved = archive.load(id) {
            currentChatID = id
            messages = saved.messages
        }
    }

    /// True while the Pi answers in the chat on screen.
    var isGeneratingHere: Bool { isGenerating && generatingChatID == currentChatID }

    /// True while the Pi answers in a chat that is not on screen.
    var isBusyElsewhere: Bool { isGenerating && generatingChatID != currentChatID }

    var selectedModel: String { defaults.string(forKey: SettingsKey.model) ?? "" }

    /// The server as a person reads it: pi-llm.local:8080.
    var serverAddress: String {
        let raw = defaults.string(forKey: SettingsKey.serverURL) ?? SettingsKey.defaultServerURL
        guard let url = LlamaClient.normalizedBaseURL(raw), let host = url.host else { return raw }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    private func makeClient() -> LlamaClient? {
        let raw = defaults.string(forKey: SettingsKey.serverURL) ?? SettingsKey.defaultServerURL
        guard let url = LlamaClient.normalizedBaseURL(raw) else { return nil }
        return LlamaClient(baseURL: url, apiKey: defaults.string(forKey: SettingsKey.apiKey) ?? "")
    }

    func refreshModels() async {
        guard let client = makeClient() else {
            connectionError = "Enter a valid server address in Settings."
            connectionUnreachable = false
            return
        }
        do {
            models = try await client.models()
            connectionError = nil
            connectionUnreachable = false
            if !models.contains(where: { $0.id == selectedModel }), let first = models.first {
                defaults.set(first.id, forKey: SettingsKey.model)
            }
            serverTools = (try? await client.tools()) ?? []
        } catch {
            connectionError = error.localizedDescription
            connectionUnreachable = error is URLError
        }
    }

    // MARK: Asking

    func send(_ text: String, image: Data?) {
        guard !isGenerating else { return }
        guard let client = makeClient() else {
            connectionError = "Enter a valid server address in Settings."
            connectionUnreachable = false
            return
        }

        let chatID = currentChatID ?? startChat(question: text, hasPhoto: image != nil)
        messages.append(ChatMessage(role: .user, text: text, imageJPEG: image))
        moveToTop(chatID)
        // Saved now, so the question is kept even if the app closes mid-answer.
        saveChat(chatID)

        let reply = ChatMessage(role: .assistant, text: "")
        messages.append(reply)

        let model = selectedModel
        let thinking = defaults.bool(forKey: SettingsKey.thinking)
        let useTools = defaults.bool(forKey: SettingsKey.tools)
        let id = UUID()
        generationID = id
        generatingChatID = chatID
        isGenerating = true

        generation = Task {
            // The answer being written; after tool steps a new one follows them.
            var replyID = reply.id
            do {
                let tools = useTools ? await toolDefinitions(client) : []
                var round = 0
                while true {
                    let offered = round < Self.maxToolRounds ? tools : []
                    let wire = wireHistory(chatID, toolsOn: !tools.isEmpty)
                    var calls: [ToolCall] = []
                    for try await event in client.streamChat(model: model, messages: wire, thinking: thinking, tools: offered) {
                        switch event {
                        case .content(let piece):
                            update(chatID, replyID) { $0.text += piece }
                        case .reasoning(let piece):
                            update(chatID, replyID) { $0.reasoning += piece }
                        case .toolCalls(let asked):
                            calls = asked
                        case .done(let timings):
                            update(chatID, replyID) { $0.stats = Self.format(timings) }
                        }
                    }
                    guard !calls.isEmpty, !offered.isEmpty else { break }
                    round += 1
                    update(chatID, replyID) { $0.toolCalls = calls }
                    for call in calls {
                        try await runTool(call, in: chatID, client: client)
                    }
                    let next = ChatMessage(role: .assistant, text: "")
                    append(next, to: chatID)
                    replyID = next.id
                }
            } catch {
                if !Task.isCancelled && !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                    update(chatID, replyID) {
                        $0.isError = true
                        $0.text += ($0.text.isEmpty ? "" : "\n\n") + error.localizedDescription
                    }
                }
            }
            if generationID == id {
                isGenerating = false
                generatingChatID = nil
            }
            saveChat(chatID)
            if generatingChatID != chatID { background[chatID] = nil }
        }
    }

    func stop() {
        generation?.cancel()
        generation = nil
        generationID = UUID()
        isGenerating = false
        if let waiting = approval {
            approval = nil
            toolStepAwaitingApproval = nil
            waiting.resume(returning: false)
        }
        if let id = generatingChatID {
            generatingChatID = nil
            saveChat(id)
            background[id] = nil
        }
    }

    /// The person's answer to the tool step waiting for it.
    func answerToolRequest(_ decision: ToolDecision) {
        guard let waiting = approval else { return }
        approval = nil
        toolStepAwaitingApproval = nil
        if decision == .alwaysAllow {
            defaults.set(true, forKey: SettingsKey.toolsAlwaysAllowed)
        }
        waiting.resume(returning: decision != .deny)
    }

    // MARK: Chats

    /// An empty chat. The one on screen is kept, and keeps being answered.
    func newChat() {
        leaveCurrentChat()
        currentChatID = nil
        messages = []
        defaults.removeObject(forKey: SettingsKey.currentChat)
    }

    func open(_ id: UUID) {
        guard id != currentChatID else { return }
        leaveCurrentChat()
        if let answering = background.removeValue(forKey: id) {
            messages = answering
        } else {
            messages = archive.load(id)?.messages ?? []
        }
        currentChatID = id
        defaults.set(id.uuidString, forKey: SettingsKey.currentChat)
    }

    func rename(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let i = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[i].title = title
        if id == currentChatID || background[id] != nil {
            saveChat(id)
        } else if var saved = archive.load(id) {
            saved.summary = chats[i]
            archive.save(saved)
            archive.saveIndex(chats)
        }
    }

    func delete(_ id: UUID) {
        if id == generatingChatID { stop() }
        background[id] = nil
        chats.removeAll { $0.id == id }
        archive.delete(id)
        archive.saveIndex(chats)
        if id == currentChatID {
            currentChatID = nil
            messages = []
            defaults.removeObject(forKey: SettingsKey.currentChat)
        }
    }

    // MARK: Private

    /// Keeps the messages of the chat on screen in memory while it is still
    /// being answered, so the rest of the answer has somewhere to go.
    private func leaveCurrentChat() {
        if let id = currentChatID, isGenerating, generatingChatID == id {
            background[id] = messages
        }
    }

    private func startChat(question: String, hasPhoto: Bool) -> UUID {
        let now = Date()
        let summary = ChatSummary(
            id: UUID(),
            title: ChatSummary.title(question: question, hasPhoto: hasPhoto),
            preview: "",
            created: now,
            updated: now
        )
        chats.insert(summary, at: 0)
        currentChatID = summary.id
        defaults.set(summary.id.uuidString, forKey: SettingsKey.currentChat)
        return summary.id
    }

    private func moveToTop(_ id: UUID) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        var summary = chats.remove(at: i)
        summary.updated = Date()
        chats.insert(summary, at: 0)
    }

    /// Writes a chat to disk, from the screen or from the background.
    private func saveChat(_ id: UUID) {
        let list: [ChatMessage]
        if id == currentChatID {
            list = messages
        } else if let answering = background[id] {
            list = answering
        } else {
            return
        }
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[i].preview = ChatSummary.preview(for: list)
        archive.save(SavedChat(summary: chats[i], messages: list))
        archive.saveIndex(chats)
    }

    /// The definitions of the read-only tools the Pi offers, asked for fresh,
    /// so switching web search on at the Pi works without a restart here.
    private func toolDefinitions(_ client: LlamaClient) async -> [JSONValue] {
        if let fresh = try? await client.tools() { serverTools = fresh }
        return serverTools.filter(\.isReadOnly).map(\.definition)
    }

    /// One tool step: shown in the chat, asked about unless always allowed,
    /// run on the Pi, its result kept for the model. Only Stop throws.
    private func runTool(_ call: ToolCall, in chatID: UUID, client: LlamaClient) async throws {
        var step = ChatMessage(role: .tool, text: "")
        step.toolCallID = call.id
        step.toolName = call.name
        step.toolArguments = call.arguments
        step.toolState = .running
        append(step, to: chatID)

        if !defaults.bool(forKey: SettingsKey.toolsAlwaysAllowed) {
            update(chatID, step.id) { $0.toolState = .waitingForApproval }
            saveChat(chatID)
            let allowed = await withCheckedContinuation { continuation in
                approval = continuation
                toolStepAwaitingApproval = step.id
            }
            try Task.checkCancellation()
            guard allowed else {
                update(chatID, step.id) {
                    $0.toolState = .declined
                    $0.text = "The person did not allow this. Answer without it, or say what you would need."
                }
                return
            }
            update(chatID, step.id) { $0.toolState = .running }
        }

        do {
            let result = try await client.callTool(call)
            update(chatID, step.id) {
                $0.text = result.text
                $0.toolState = result.failed ? .failed : .done
            }
        } catch {
            try Task.checkCancellation()
            update(chatID, step.id) {
                $0.text = "The tool could not run: \(error.localizedDescription)"
                $0.toolState = .failed
            }
        }
        saveChat(chatID)
    }

    /// The messages of a chat being answered, on screen or not.
    private func messages(of chatID: UUID) -> [ChatMessage] {
        chatID == currentChatID ? messages : background[chatID] ?? []
    }

    private func append(_ message: ChatMessage, to chatID: UUID) {
        if chatID == currentChatID {
            messages.append(message)
        } else if background[chatID] != nil {
            background[chatID]?.append(message)
        }
    }

    /// Conversation as sent to the server: optional system prompt + all
    /// successful turns (the API is stateless, the server caches the prefix).
    /// With tools, the steps go along, and the system prompt says today's date:
    /// the models don't know it, and a search for "the latest …" needs it.
    private func wireHistory(_ chatID: UUID, toolsOn: Bool) -> [LlamaClient.WireMessage] {
        var wire: [LlamaClient.WireMessage] = []
        var system = (defaults.string(forKey: SettingsKey.systemPrompt) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if toolsOn {
            let today = Date().formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: Locale(identifier: "en_US_POSIX")))
            system += (system.isEmpty ? "" : "\n\n") + "Today is \(today)."
        }
        if !system.isEmpty {
            wire.append(.init(role: "system", text: system))
        }
        let list = messages(of: chatID)
        // A call goes along only with its result; a step that Stop cut short goes with neither.
        let answered = Set(list.filter(\.isFinishedToolStep).compactMap(\.toolCallID))
        for m in list where !m.isError {
            switch m.role {
            case .user:
                guard !(m.text.isEmpty && m.imageJPEG == nil) else { continue }
                wire.append(.init(role: "user", text: m.text, imageJPEG: m.imageJPEG))
            case .assistant:
                let calls = (m.toolCalls ?? []).filter { answered.contains($0.id) }
                guard !(m.text.isEmpty && calls.isEmpty) else { continue }
                wire.append(.init(role: "assistant", text: m.text, toolCalls: calls.isEmpty ? nil : calls))
            case .tool:
                guard m.isFinishedToolStep, let id = m.toolCallID else { continue }
                wire.append(.init(role: "tool", text: m.text, toolCallID: id))
            }
        }
        return wire
    }

    /// Changes a message of the chat being answered, on screen or not.
    private func update(_ chatID: UUID, _ messageID: UUID, _ change: (inout ChatMessage) -> Void) {
        if chatID == currentChatID {
            guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
            change(&messages[i])
        } else if var list = background[chatID], let i = list.firstIndex(where: { $0.id == messageID }) {
            change(&list[i])
            background[chatID] = list
        }
    }

    private static func format(_ t: LlamaClient.Timings?) -> String? {
        guard let t, let tps = t.predicted_per_second, let n = t.predicted_n else { return nil }
        return String(format: "%ld tokens · %.1f tokens a second", n, tps)
    }
}
