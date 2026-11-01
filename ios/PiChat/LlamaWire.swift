import Foundation

// The JSON that goes to llama-server and comes back. Kept apart from the
// networking in LlamaClient.swift, so ios/Tests/run.sh can test it anywhere.

extension LlamaClient {
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
        /// The model wants these tools run before it goes on.
        case toolCalls([ToolCall])
        case done(Timings?)
    }

    /// One chat message as sent to the server. Images are sent inline as
    /// base64 data URLs, which llama-server passes to the vision encoder.
    struct WireMessage: Encodable, Sendable {
        let role: String
        let text: String
        var imageJPEG: Data? = nil
        /// An answer that asked for tools.
        var toolCalls: [ToolCall]? = nil
        /// A tool's result: the call it answers.
        var toolCallID: String? = nil

        private struct Part: Encodable {
            struct ImageURL: Encodable { let url: String }
            let type: String
            var text: String? = nil
            var image_url: ImageURL? = nil
        }

        private enum CodingKeys: String, CodingKey { case role, content, tool_calls, tool_call_id }

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
            if let toolCalls, !toolCalls.isEmpty {
                try container.encode(toolCalls, forKey: .tool_calls)
            }
            if let toolCallID {
                try container.encode(toolCallID, forKey: .tool_call_id)
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

    struct ChatRequest: Encodable {
        let model: String
        let messages: [WireMessage]
        let stream = true
        let chat_template_kwargs: [String: Bool]
        /// The tool definitions, as the server listed them. Left out when nil.
        var tools: [JSONValue]? = nil
    }

    /// POST /tools: run one tool with the arguments the model wrote.
    struct ToolRequest: Encodable {
        let tool: String
        let params: JSONValue
    }

    struct ModelList: Decodable { let data: [ModelInfo] }

    struct ErrorBody: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    struct Chunk: Decodable {
        struct Choice: Decodable {
            let delta: Delta?
            let finish_reason: String?
        }
        struct Delta: Decodable {
            let content: String?
            let reasoning_content: String?
            let tool_calls: [ToolCallDelta]?
        }
        let choices: [Choice]?
        let timings: Timings?
    }

    enum SSELine {
        case chunk(Chunk)
        case error(String)
        case done
    }

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
}
