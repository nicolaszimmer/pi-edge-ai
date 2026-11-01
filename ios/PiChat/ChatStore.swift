import Foundation
import Observation

/// Keys for settings stored in UserDefaults (read by views via @AppStorage).
enum SettingsKey {
    static let serverURL = "serverURL"
    static let apiKey = "apiKey"
    static let model = "model"
    static let systemPrompt = "systemPrompt"
    static let thinking = "thinking"

    static let defaultServerURL = "http://pi-llm.local:8080"
}

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    var role: Role
    var text: String
    var reasoning: String = ""
    var imageJPEG: Data? = nil
    var stats: String? = nil
    var isError: Bool = false
    /// When it was sent or answered (nil for chats saved before this was kept).
    var date: Date? = Date()
}

@MainActor
@Observable
final class ChatStore {
    var messages: [ChatMessage] = []
    var isGenerating = false
    var models: [LlamaClient.ModelInfo] = []
    var connectionError: String?
    /// True when the last connection error was the network (no answer at all),
    /// false when the Pi answered with an error or the address is not valid.
    var connectionUnreachable = false

    @ObservationIgnored private var generation: Task<Void, Never>?
    @ObservationIgnored private var generationID = UUID()
    private let defaults = UserDefaults.standard

    private static var saveURL: URL { URL.documentsDirectory.appending(path: "chat.json") }

    init() {
        if let data = try? Data(contentsOf: Self.saveURL),
           let saved = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            messages = saved
        }
    }

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

    func send(_ text: String, image: Data?) {
        guard !isGenerating else { return }
        guard let client = makeClient() else {
            connectionError = "Enter a valid server address in Settings."
            connectionUnreachable = false
            return
        }

        messages.append(ChatMessage(role: .user, text: text, imageJPEG: image))
        let wire = wireHistory()
        let reply = ChatMessage(role: .assistant, text: "")
        messages.append(reply)

        let model = selectedModel
        let thinking = defaults.bool(forKey: SettingsKey.thinking)
        let id = UUID()
        generationID = id
        isGenerating = true

        generation = Task {
            do {
                for try await event in client.streamChat(model: model, messages: wire, thinking: thinking) {
                    switch event {
                    case .content(let piece):
                        update(reply.id) { $0.text += piece }
                    case .reasoning(let piece):
                        update(reply.id) { $0.reasoning += piece }
                    case .done(let timings):
                        update(reply.id) { $0.stats = Self.format(timings) }
                    }
                }
            } catch {
                if !Task.isCancelled && (error as? URLError)?.code != .cancelled {
                    update(reply.id) {
                        $0.isError = true
                        $0.text += ($0.text.isEmpty ? "" : "\n\n") + error.localizedDescription
                    }
                }
            }
            if generationID == id { isGenerating = false }
            save()
        }
    }

    func stop() {
        generation?.cancel()
        generation = nil
        generationID = UUID()
        isGenerating = false
        save()
    }

    func newChat() {
        stop()
        messages.removeAll()
        save()
    }

    // MARK: Private

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

    private func update(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[i])
    }

    private func save() {
        try? JSONEncoder().encode(messages).write(to: Self.saveURL, options: .atomic)
    }

    private static func format(_ t: LlamaClient.Timings?) -> String? {
        guard let t, let tps = t.predicted_per_second, let n = t.predicted_n else { return nil }
        return String(format: "%ld tokens · %.1f tokens a second", n, tps)
    }
}
