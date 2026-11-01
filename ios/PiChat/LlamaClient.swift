import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // Linux, where ios/Tests runs this file against a real server
#endif

/// Minimal client for llama-server's OpenAI-compatible API. The JSON it sends
/// and reads is in LlamaWire.swift.
struct LlamaClient: Sendable {
    let baseURL: URL
    let apiKey: String

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

    /// The tools the server offers (GET /tools), such as web_search. Empty when
    /// it offers none: llama-server answers 403 then.
    func tools() async throws -> [ServerTool] {
        var request = makeRequest("tools")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 403 || http.statusCode == 404 {
            return []
        }
        try Self.check(response, data)
        return try JSONDecoder().decode([ServerTool].self, from: data)
    }

    /// Runs one tool on the server (POST /tools) and returns its result as the
    /// text the model gets. A tool that ran but failed comes back with `failed`.
    func callTool(_ call: ToolCall) async throws -> (text: String, failed: Bool) {
        var request = makeRequest("tools")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The Pi gives a tool up to 60 s (mcp.json); reading a page takes up to 25.
        request.timeoutInterval = 90
        request.httpBody = try JSONEncoder().encode(ToolRequest(tool: call.name, params: call.parameters))
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return ToolResult.text(from: data)
    }

    /// Streams a chat completion token by token. With `tools`, the model may
    /// answer with tool calls instead, which arrive as one `.toolCalls` event
    /// just before `.done`.
    func streamChat(model: String, messages: [WireMessage], thinking: Bool, tools: [JSONValue] = []) -> AsyncThrowingStream<StreamEvent, Error> {
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
                        chat_template_kwargs: ["enable_thinking": thinking],
                        tools: tools.isEmpty ? nil : tools
                    ))

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        try Self.check(response, body)
                    }

                    var timings: Timings?
                    var calls = ToolCallAccumulator()
                    stream: for try await line in bytes.lines {
                        switch Self.parseSSELine(line) {
                        case .chunk(let chunk):
                            if let t = chunk.timings { timings = t }
                            if let delta = chunk.choices?.first?.delta {
                                if let r = delta.reasoning_content, !r.isEmpty { continuation.yield(.reasoning(r)) }
                                if let c = delta.content, !c.isEmpty { continuation.yield(.content(c)) }
                                if let pieces = delta.tool_calls { calls.add(pieces) }
                            }
                        case .error(let message):
                            throw ClientError.http(500, message)
                        case .done:
                            break stream
                        case nil:
                            continue
                        }
                    }
                    let finished = calls.result
                    if !finished.isEmpty { continuation.yield(.toolCalls(finished)) }
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
