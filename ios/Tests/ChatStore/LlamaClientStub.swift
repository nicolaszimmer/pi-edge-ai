import Foundation
/// Stand-in for LlamaClient's networking (the types come from LlamaWire.swift):
/// streams "one two three … ten" slowly, or asks for a tool when tests say so.
struct LlamaClient: Sendable {
    let baseURL: URL
    let apiKey: String
    nonisolated(unsafe) static var lastWire: [WireMessage] = []
    nonisolated(unsafe) static var lastTools: [JSONValue] = []
    nonisolated(unsafe) static var requests = 0
    /// What GET /tools lists.
    nonisolated(unsafe) static var offered: [ServerTool] = []
    /// The calls POST /tools ran.
    nonisolated(unsafe) static var ran: [ToolCall] = []
    /// With tools offered, the model asks for this tool instead of answering,
    /// unless it has just had a tool's result (or `keepCalling` is set).
    nonisolated(unsafe) static var asksFor: String? = nil
    nonisolated(unsafe) static var keepCalling = false
    /// How long the stream stays open after the tool call, before it ends.
    nonisolated(unsafe) static var pauseAfterCalls: UInt64 = 0

    func models() async throws -> [ModelInfo] { [ModelInfo(id: "m", status: nil)] }
    func tools() async throws -> [ServerTool] { Self.offered }
    func callTool(_ call: ToolCall) async throws -> (text: String, failed: Bool) {
        Self.ran.append(call)
        try await Task.sleep(nanoseconds: 20_000_000)
        return ("result for \(call.parameters["query"]?.string ?? "?")", false)
    }
    func streamChat(model: String, messages: [WireMessage], thinking: Bool, tools: [JSONValue] = []) -> AsyncThrowingStream<StreamEvent, Error> {
        Self.lastWire = messages
        Self.lastTools = tools
        Self.requests += 1
        let round = Self.requests
        let asks = Self.asksFor.flatMap { name in
            !tools.isEmpty && (Self.keepCalling || messages.last?.role != "tool") ? name : nil
        }
        return AsyncThrowingStream { c in
            let t = Task {
                if let asks {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    c.yield(.toolCalls([ToolCall(id: "call-\(round)", name: asks, arguments: #"{"query":"q\#(round)"}"#)]))
                    if Self.pauseAfterCalls > 0 { try? await Task.sleep(nanoseconds: Self.pauseAfterCalls) }
                    c.yield(.done(nil))
                    c.finish()
                    return
                }
                for w in ["one", " two", " three", " four", " five", " six", " seven", " eight", " nine", " ten"] {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    if Task.isCancelled { c.finish(throwing: CancellationError()); return }
                    c.yield(.content(w))
                }
                c.yield(.done(Timings(prompt_n: 1, prompt_per_second: 1, predicted_n: 10, predicted_per_second: 5)))
                c.finish()
            }
            c.onTermination = { _ in t.cancel() }
        }
    }
}
