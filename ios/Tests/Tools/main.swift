// Tests for ToolCalls.swift and LlamaWire.swift: the tool list, streamed tool
// calls and the JSON sent back, against what llama-server really sent
// (Fixtures/tools.json, Fixtures/tool-call-stream.txt). Run with ios/Tests/run.sh.
import Foundation
var failures = 0
func check(_ c: Bool, _ m: String, line: Int = #line) { if !c { failures += 1; print("FAIL \(line): \(m)") } }
func json(_ value: some Encodable) -> Any {
    try! JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}

let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])

// The tool list, and its definitions going back unchanged
let toolsData = try! Data(contentsOf: fixtures.appendingPathComponent("tools.json"))
let tools = try! JSONDecoder().decode([ServerTool].self, from: toolsData)
check(tools.map(\.tool) == ["web_search", "web_fetch"], "tool names: \(tools.map(\.tool))")
check(tools.allSatisfy(\.isOfferedByApp), "the Pi's MCP tools are offered")
check(tools[0].definition["function"]?["name"]?.string == "web_search", "definition name")
let original = (try! JSONSerialization.jsonObject(with: toolsData) as! [[String: Any]]).map { $0["definition"]! }
check(NSArray(array: json(tools.map(\.definition)) as! [Any]).isEqual(to: original), "definitions round-trip unchanged")
let writer = try! JSONDecoder().decode(ServerTool.self, from: Data(#"{"tool":"write_file","permissions":{"write":true},"definition":{}}"#.utf8))
check(!writer.isOfferedByApp, "a tool that writes is not offered")
for raw in [#"{"tool":"read_file","type":"server","permissions":{"write":false},"definition":{}}"#,
            #"{"tool":"mystery","type":"mcp","definition":{}}"#,
            #"{"tool":"mystery","type":"mcp","permissions":{},"definition":{}}"#] {
    let t = try! JSONDecoder().decode(ServerTool.self, from: Data(raw.utf8))
    check(!t.isOfferedByApp, "not offered: \(raw)")
}

// JSONValue keeps every kind of value
let mixed = #"{"a":null,"b":true,"c":3,"d":2.5,"e":"x","f":[1,"y",false],"g":{"h":{}}}"#
let decoded = try! JSONDecoder().decode(JSONValue.self, from: Data(mixed.utf8))
check(decoded["b"] == .bool(true) && decoded["c"] == .int(3) && decoded["d"] == .double(2.5), "kinds: \(decoded)")
let sorted = JSONEncoder()
sorted.outputFormatting = .sortedKeys
check(String(decoding: try! sorted.encode(decoded), as: UTF8.self) == mixed, "JSONValue round-trip")

// A streamed tool call, as Gemma 4 E2B sent it through llama-server
let stream = try! String(contentsOf: fixtures.appendingPathComponent("tool-call-stream.txt"), encoding: .utf8)
var accumulator = ToolCallAccumulator()
var content = "", finish: String?, sawDone = false, sawTimings = false
for line in stream.split(separator: "\n", omittingEmptySubsequences: false) {
    switch LlamaClient.parseSSELine(String(line)) {
    case .chunk(let chunk):
        if let delta = chunk.choices?.first?.delta {
            content += delta.content ?? ""
            if let pieces = delta.tool_calls { accumulator.add(pieces) }
        }
        if let f = chunk.choices?.first?.finish_reason { finish = f }
        if chunk.timings != nil { sawTimings = true }
    case .done: sawDone = true
    case .error(let e): check(false, "error line: \(e)")
    case nil: break
    }
}
let calls = accumulator.result
check(calls.count == 1 && calls[0].name == "web_search", "one web_search call: \(calls)")
check(calls.first?.parameters["query"]?.string == "weather forecast for Berlin tomorrow", "query: \(calls.first?.arguments ?? "")")
check(calls.first?.id.count == 32, "id from the server: \(calls.first?.id ?? "")")
check(content.isEmpty && finish == "tool_calls" && sawDone && sawTimings, "rest of the stream")

// Pieces without index or id, and two calls in one answer
var two = ToolCallAccumulator()
two.add([ToolCallDelta(index: nil, id: nil, function: .init(name: "web_fetch", arguments: "{\"url\":"))])
two.add([ToolCallDelta(index: nil, id: nil, function: .init(name: nil, arguments: "\"https://example.com\"}"))])
two.add([ToolCallDelta(index: 1, id: "b", function: .init(name: "web_search", arguments: "{}"))])
two.add([ToolCallDelta(index: 2, id: "c", function: .init(name: nil, arguments: "{}"))])
check(two.result.map(\.id) == ["call_0", "b"] && two.result[0].parameters["url"]?.string == "https://example.com", "assembled: \(two.result)")
check(ToolCall(id: "x", name: "n", arguments: "not json").parameters == .object([:]), "bad arguments become {}")

// The messages sent back: an answer that asked for a tool, and the tool's result
let call = ToolCall(id: "abc", name: "web_search", arguments: #"{"query":"q"}"#)
let asked = json(LlamaClient.WireMessage(role: "assistant", text: "", toolCalls: [call])) as! [String: Any]
check(asked["content"] as? String == "", "assistant content")
let wireCalls = asked["tool_calls"] as? [[String: Any]]
check(wireCalls?.first?["id"] as? String == "abc" && wireCalls?.first?["type"] as? String == "function", "tool_calls id and type")
check((wireCalls?.first?["function"] as? [String: Any])?["arguments"] as? String == #"{"query":"q"}"#, "arguments as a string")
let result = json(LlamaClient.WireMessage(role: "tool", text: "results", toolCallID: "abc")) as! [String: Any]
check(result["tool_call_id"] as? String == "abc" && result["content"] as? String == "results" && result["tool_calls"] == nil, "tool result")
let plain = json(LlamaClient.WireMessage(role: "user", text: "hi")) as! [String: Any]
check(plain.keys.sorted() == ["content", "role"], "plain message unchanged: \(plain.keys)")
let back = try! JSONDecoder().decode(ToolCall.self, from: JSONEncoder().encode(call))
check(back == call, "ToolCall round-trip")

// The request: tools only when there are some
let without = json(LlamaClient.ChatRequest(model: "m", messages: [], chat_template_kwargs: ["enable_thinking": false])) as! [String: Any]
check(without["tools"] == nil && without["stream"] as? Bool == true, "no tools key")
let with = json(LlamaClient.ChatRequest(model: "m", messages: [], chat_template_kwargs: [:], tools: tools.map(\.definition))) as! [String: Any]
check((with["tools"] as? [Any])?.count == 2, "tools sent")
let toolRequest = json(LlamaClient.ToolRequest(tool: call.name, params: call.parameters)) as! [String: Any]
check(toolRequest["tool"] as? String == "web_search" && (toolRequest["params"] as? [String: Any])?["query"] as? String == "q", "POST /tools body")

// What POST /tools answers
check(ToolResult.text(from: Data(#"{"plain_text_response":"Web results"}"#.utf8)) == ("Web results", false), "plain text")
check(ToolResult.text(from: Data(#"{"error":"query is empty"}"#.utf8)) == ("query is empty", true), "error")
check(ToolResult.text(from: Data(#"{"rows":[1]}"#.utf8)) == (#"{"rows":[1]}"#, false), "other JSON as it came")

// How the chat names the steps
let search = ToolLabel(name: "web_search", arguments: #"{"query":"Wetter Berlin morgen"}"#)
check(search.running == "Searching the web for “Wetter Berlin morgen”" && search.done == "Searched the web for “Wetter Berlin morgen”", "search: \(search)")
check(search.ask == "search the web for “Wetter Berlin morgen”" && search.detail == nil, "search ask")
let fetch = ToolLabel(name: "web_fetch", arguments: #"{"url":"https://en.wikipedia.org/wiki/Raspberry_Pi"}"#)
check(fetch.running == "Reading en.wikipedia.org" && fetch.done == "Read en.wikipedia.org", "fetch: \(fetch)")
check(fetch.ask == "read a page on en.wikipedia.org" && fetch.detail == "https://en.wikipedia.org/wiki/Raspberry_Pi", "fetch ask")
check(ToolLabel(name: "web_fetch", arguments: #"{"url":"example.com/a"}"#).done == "Read example.com", "fetch without scheme")
let other = ToolLabel(name: "home_lights", arguments: #"{"room":"kitchen"}"#)
check(other.running == "Using home_lights" && other.detail == #"{"room":"kitchen"}"#, "other tool: \(other)")
check(ToolLabel(name: "web_search", arguments: "{}").running == "Using web_search", "search without query")
let long = ToolLabel(name: "web_search", arguments: "{\"query\":\"\(String(repeating: "a", count: 100))\"}")
check(long.done.count < 90 && long.done.hasSuffix("…”"), "long query clipped: \(long.done)")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
