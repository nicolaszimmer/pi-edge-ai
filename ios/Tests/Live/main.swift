// LlamaClient against a real llama-server with the web tools switched on
// (./web-search.sh on): lists the tools, lets the model call one, runs it and
// sends the result back, the way ChatStore does. Needs a running server, so
// run.sh only runs it when PICHAT_TEST_SERVER is set:
//
//   PICHAT_TEST_SERVER=http://pi-llm.local:8080 PICHAT_TEST_KEY=sk-pi-… \
//   PICHAT_TEST_MODEL=gemma-4-e2b ios/Tests/run.sh
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
var failures = 0
func check(_ c: Bool, _ m: String, line: Int = #line) { if !c { failures += 1; print("FAIL \(line): \(m)") } }

let env = ProcessInfo.processInfo.environment
let client = LlamaClient(baseURL: LlamaClient.normalizedBaseURL(env["PICHAT_TEST_SERVER"]!)!, apiKey: env["PICHAT_TEST_KEY"] ?? "")
let model = env["PICHAT_TEST_MODEL"] ?? "gemma-4-e2b"

/// One round: streams an answer and collects what came.
func ask(_ wire: [LlamaClient.WireMessage], tools: [JSONValue]) async throws -> (text: String, calls: [ToolCall]) {
    var text = "", calls: [ToolCall] = []
    for try await event in client.streamChat(model: model, messages: wire, thinking: false, tools: tools) {
        switch event {
        case .content(let piece): text += piece
        case .toolCalls(let c): calls = c
        case .reasoning, .done: break
        }
    }
    return (text, calls)
}

/// A question that should make the model use `tool`: the call, its result, and
/// what the model does next: answer, or call another tool (ChatStore loops then).
func roundTrip(_ question: String, expecting tool: String, definitions: [JSONValue]) async throws -> (text: String, calls: [ToolCall])? {
    let user = LlamaClient.WireMessage(role: "user", text: question)
    var first = try await ask([user], tools: definitions)
    for _ in 0..<2 where first.calls.first?.name != tool { first = try await ask([user], tools: definitions) }
    guard let call = first.calls.first, call.name == tool else {
        check(false, "\(model) did not call \(tool) for “\(question)”: \(first)")
        return nil
    }
    let result = try await client.callTool(call)
    check(!result.failed && !result.text.isEmpty, "\(tool) result: \(result.text.prefix(120))")
    let wire = [user,
                LlamaClient.WireMessage(role: "assistant", text: first.text, toolCalls: [call]),
                LlamaClient.WireMessage(role: "tool", text: result.text, toolCallID: call.id)]
    let next = try await ask(wire, tools: definitions)
    let shown = next.text.isEmpty ? "another call: \(next.calls.map { "\($0.name) \($0.arguments)" })" : next.text
    print("  \(tool) \(call.arguments) -> \(shown.prefix(110).replacingOccurrences(of: "\n", with: " "))")
    return next
}

func run() async throws {
    print("Live: \(model) at \(client.baseURL)")
    let tools = try await client.tools()
    check(tools.map(\.tool).contains("web_search") && tools.map(\.tool).contains("web_fetch"), "tools listed: \(tools.map(\.tool))")
    let definitions = tools.filter(\.isOfferedByApp).map(\.definition)

    let plain = try await ask([.init(role: "user", text: "Say hello in one word.")], tools: [])
    check(!plain.text.isEmpty && plain.calls.isEmpty, "answer without tools: \(plain)")

    let weather = try await roundTrip("What is the weather forecast for Berlin tomorrow? Search the web.", expecting: "web_search", definitions: definitions)
    check(weather.map { !$0.text.isEmpty || !$0.calls.isEmpty } == true, "an answer or another call after the search")

    let page = try await roundTrip("Read https://en.wikipedia.org/wiki/Raspberry_Pi and tell me in one sentence how many Raspberry Pi units have been sold.",
                                   expecting: "web_fetch", definitions: definitions)
    check(page?.text.contains("75") == true, "answer uses the page: \(page?.text ?? "")")

    let failed = try await client.callTool(ToolCall(id: "x", name: "web_fetch", arguments: #"{"url":"http://127.0.0.1/"}"#))
    check(failed.failed && failed.text.contains("local or private"), "tool error comes back as failed: \(failed)")

    if let bare = env["PICHAT_TEST_SERVER_WITHOUT_TOOLS"] {
        let none = try await LlamaClient(baseURL: URL(string: bare)!, apiKey: client.apiKey).tools()
        check(none.isEmpty, "server without tools: \(none)")
    }
}

Task {
    do { try await run() } catch { check(false, "error: \(error)") }
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
