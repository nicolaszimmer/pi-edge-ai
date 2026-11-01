import Foundation

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

/// A saved chat as the list of chats shows it, without its messages.
struct ChatSummary: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    /// The start of the last answer, as plain text.
    var preview: String
    var created: Date
    /// The last time something was asked in it. The list is sorted by this.
    var updated: Date
}

/// A chat as it is kept on disk.
struct SavedChat: Codable {
    var summary: ChatSummary
    var messages: [ChatMessage]
}

/// The chats on disk: one JSON file per chat, so opening one never reads the
/// photos of all the others, and an index for the list. The index can always
/// be built again from the chat files.
struct ChatArchive {
    let folder: URL

    static var standard: ChatArchive {
        ChatArchive(folder: URL.documentsDirectory.appending(path: "Chats"))
    }

    private var indexURL: URL { folder.appending(path: "index.json") }

    private func url(for id: UUID) -> URL {
        folder.appending(path: "\(id.uuidString).json")
    }

    /// Every chat, the most recent first.
    func loadIndex() -> [ChatSummary] {
        if let data = try? Data(contentsOf: indexURL),
           let chats = try? JSONDecoder().decode([ChatSummary].self, from: data) {
            return chats.sorted { $0.updated > $1.updated }
        }
        return rebuildIndex()
    }

    /// Reads every chat file for its summary, for when the index is missing.
    func rebuildIndex() -> [ChatSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var chats: [ChatSummary] = []
        for file in files where file.pathExtension == "json" && file.lastPathComponent != "index.json" {
            if let data = try? Data(contentsOf: file),
               let chat = try? JSONDecoder().decode(SavedChat.self, from: data) {
                chats.append(chat.summary)
            }
        }
        chats.sort { $0.updated > $1.updated }
        if !chats.isEmpty { saveIndex(chats) }
        return chats
    }

    func saveIndex(_ chats: [ChatSummary]) {
        makeFolder()
        try? JSONEncoder().encode(chats).write(to: indexURL, options: .atomic)
    }

    func load(_ id: UUID) -> SavedChat? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? JSONDecoder().decode(SavedChat.self, from: data)
    }

    func save(_ chat: SavedChat) {
        makeFolder()
        try? JSONEncoder().encode(chat).write(to: url(for: chat.summary.id), options: .atomic)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Earlier versions kept one conversation in chat.json. This makes it the
    /// first saved chat and removes the old file, once it is safely copied.
    func importSingleChat(from file: URL) -> ChatSummary? {
        guard let data = try? Data(contentsOf: file),
              let messages = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return nil }
        guard !messages.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        let created = messages.compactMap(\.date).min() ?? Date()
        let summary = ChatSummary(
            id: UUID(),
            title: ChatSummary.title(for: messages),
            preview: ChatSummary.preview(for: messages),
            created: created,
            updated: messages.compactMap(\.date).max() ?? created
        )
        save(SavedChat(summary: summary, messages: messages))
        guard load(summary.id) != nil else { return nil }
        try? FileManager.default.removeItem(at: file)
        return summary
    }

    private func makeFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
}

extension ChatSummary {
    /// The first line of the first question, cut at a word near 60 characters.
    static func title(for messages: [ChatMessage]) -> String {
        guard let first = messages.first(where: { $0.role == .user }) else { return "New chat" }
        return title(question: first.text, hasPhoto: first.imageJPEG != nil)
    }

    static func title(question: String, hasPhoto: Bool) -> String {
        let line = question
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        // The question is the person's own text, not Markdown: keep every character.
        let words = folded(line)
        if words.isEmpty { return hasPhoto ? "Photo" : "New chat" }
        return shortened(words, to: 60)
    }

    /// The start of the last answer, without Markdown marks.
    static func preview(for messages: [ChatMessage]) -> String {
        guard let answer = messages.last(where: { $0.role == .assistant && !$0.isError && !$0.text.isEmpty }) else {
            return ""
        }
        return shortened(plain(answer.text), to: 160)
    }

    /// An answer as plain text: Markdown's marks taken out, but not characters
    /// of the text itself, so "C#", "my_var", "5 > 3" and "$5" stay as written.
    static func plain(_ text: String) -> String {
        var s = text
        // Marks at the start of a line: rules, fences, headings, quotes, list
        // markers, table delimiter rows.
        let lineMarks = [
            #"(?m)^[ \t]*([-*_][ \t]*){3,}$"#,
            #"(?m)^[ \t]*(```|~~~).*$"#,
            #"(?m)^[ \t]{0,3}#{1,6}[ \t]+"#,
            #"(?m)^[ \t]*(>[ \t]?)+"#,
            #"(?m)^[ \t]*([-*+]|\d{1,9}[.)])[ \t]+"#,
            #"(?m)^[ \t]*\|?([ \t]*:?-+:?[ \t]*\|)+[ \t]*(:?-+:?)?[ \t]*$"#,
        ]
        for pattern in lineMarks {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        // Maths keeps its LaTeX but loses its dollars; prices keep theirs.
        let (marked, spans) = InlineMath.extract(s)
        s = ""
        for ch in marked {
            if let i = InlineMath.index(of: ch), i < spans.count { s += spans[i].latex } else { s.append(ch) }
        }
        s = s.replacingOccurrences(of: #"\\(text|mathrm|mathbf|operatorname)\{([^}]*)\}"#, with: "$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\(Huge|huge|LARGE|Large|large|left|right|displaystyle)(?![A-Za-z])"#, with: "", options: .regularExpression)
        // Emphasis and code marks, and table pipes.
        s = s.replacingOccurrences(of: #"\*+|`+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "|", with: " ")
        return folded(s)
    }

    /// White space, line breaks included, folded into single spaces.
    static func folded(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func shortened(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: space, to: cut.endIndex) < 20 {
            return cut[..<space].trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
}
