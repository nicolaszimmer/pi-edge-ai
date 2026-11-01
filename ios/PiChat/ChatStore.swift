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

    @ObservationIgnored private var generation: Task<Void, Never>?
    @ObservationIgnored private var generationID = UUID()
    /// The messages of a chat still being answered while another is on screen.
    @ObservationIgnored private var background: [UUID: [ChatMessage]] = [:]
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

        let wire = wireHistory()
        let reply = ChatMessage(role: .assistant, text: "")
        messages.append(reply)

        let model = selectedModel
        let thinking = defaults.bool(forKey: SettingsKey.thinking)
        let id = UUID()
        generationID = id
        generatingChatID = chatID
        isGenerating = true

        generation = Task {
            do {
                for try await event in client.streamChat(model: model, messages: wire, thinking: thinking) {
                    switch event {
                    case .content(let piece):
                        update(chatID, reply.id) { $0.text += piece }
                    case .reasoning(let piece):
                        update(chatID, reply.id) { $0.reasoning += piece }
                    case .done(let timings):
                        update(chatID, reply.id) { $0.stats = Self.format(timings) }
                    }
                }
            } catch {
                if !Task.isCancelled && (error as? URLError)?.code != .cancelled {
                    update(chatID, reply.id) {
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
        if let id = generatingChatID {
            generatingChatID = nil
            saveChat(id)
            background[id] = nil
        }
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

    /// Conversation as sent to the server: optional system prompt + all
    /// successful turns (the API is stateless, the server caches the prefix).
    private func wireHistory() -> [LlamaClient.WireMessage] {
        var wire: [LlamaClient.WireMessage] = []
        let system = (defaults.string(forKey: SettingsKey.systemPrompt) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            wire.append(.init(role: "system", text: system))
        }
        for m in messages where !m.isError && !(m.text.isEmpty && m.imageJPEG == nil) {
            wire.append(.init(role: m.role.rawValue, text: m.text, imageJPEG: m.imageJPEG))
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
