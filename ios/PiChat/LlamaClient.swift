import Foundation

/// Minimal client for llama-server's OpenAI-compatible API.
struct LlamaClient: Sendable {
    let baseURL: URL
    let apiKey: String

    // MARK: Types

    struct ModelInfo: Decodable, Identifiable, Hashable, Sendable {
        struct Status: Decodable, Hashable, Sendable { let value: String? }
        let id: String
        let status: Status?
    }

    struct Timings: Decodable, Sendable {
        let prompt_n: Int?
        let prompt_per_second: Double?
        let predicted_n: Int?
        let predicted_per_second: Double?
    }

    enum StreamEvent: Sendable {
        case content(String)
        case reasoning(String)
        case done(Timings?)
    }

    /// One chat message as sent to the server. Images are sent inline as
    /// base64 data URLs, which llama-server passes to Gemma's vision encoder.
    struct WireMessage: Encodable, Sendable {
        let role: String
        let text: String
        var imageJPEG: Data? = nil

        private struct Part: Encodable {
            struct ImageURL: Encodable { let url: String }
            let type: String
            var text: String? = nil
            var image_url: ImageURL? = nil
        }

        private enum CodingKeys: String, CodingKey { case role, content }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            if let imageJPEG {
                var parts: [Part] = []
                if !text.isEmpty { parts.append(Part(type: "text", text: text)) }
                let dataURL = "data:image/jpeg;base64," + imageJPEG.base64EncodedString()
                parts.append(Part(type: "image_url", image_url: .init(url: dataURL)))
                try container.encode(parts, forKey: .content)
            } else {
                try container.encode(text, forKey: .content)
            }
        }
    }

    enum ClientError: LocalizedError {
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .http(401, _): return "Wrong API key (HTTP 401). Check Settings."
            case .http(let code, let message): return "Server error \(code): \(message)"
            }
        }
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [WireMessage]
        let stream = true
        let chat_template_kwargs: [String: Bool]
    }

    private struct ModelList: Decodable { let data: [ModelInfo] }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    struct Chunk: Decodable {
        struct Choice: Decodable { let delta: Delta? }
        struct Delta: Decodable {
            let content: String?
            let reasoning_content: String?
        }
        let choices: [Choice]?
        let timings: Timings?
    }

    enum SSELine {
        case chunk(Chunk)
        case error(String)
        case done
    }

    // MARK: Helpers

    /// Accepts "pi-llm.local:8080", "http://pi-llm.local:8080/", ".../v1".
    static func normalizedBaseURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/v1") { s.removeLast(3) }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    /// Parses one line of the server-sent-events stream.
    static func parseSSELine(_ line: String) -> SSELine? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8) else { return nil }
        if let err = try? JSONDecoder().decode(ErrorBody.self, from: data) {
            return .error(err.error.message)
        }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { return nil }
        return .chunk(chunk)
    }

    private func makeRequest(_ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
            ?? String(decoding: data, as: UTF8.self)
        throw ClientError.http(http.statusCode, message)
    }

    // MARK: API

    func models() async throws -> [ModelInfo] {
        var request = makeRequest("v1/models")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return try JSONDecoder().decode(ModelList.self, from: data).data
    }

    /// Streams a chat completion token by token.
    func streamChat(model: String, messages: [WireMessage], thinking: Bool) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = makeRequest("v1/chat/completions")
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    // Generous idle timeout: switching models and processing a long
                    // prompt on a Pi can take a while before the first token arrives.
                    request.timeoutInterval = 600
                    request.httpBody = try JSONEncoder().encode(ChatRequest(
                        model: model,
                        messages: messages,
                        chat_template_kwargs: ["enable_thinking": thinking]
                    ))

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        try Self.check(response, body)
                    }

                    var timings: Timings?
                    stream: for try await line in bytes.lines {
                        switch Self.parseSSELine(line) {
                        case .chunk(let chunk):
                            if let t = chunk.timings { timings = t }
                            if let delta = chunk.choices?.first?.delta {
                                if let r = delta.reasoning_content, !r.isEmpty { continuation.yield(.reasoning(r)) }
                                if let c = delta.content, !c.isEmpty { continuation.yield(.content(c)) }
                            }
                        case .error(let message):
                            throw ClientError.http(500, message)
                        case .done:
                            break stream
                        case nil:
                            continue
                        }
                    }
                    continuation.yield(.done(timings))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
