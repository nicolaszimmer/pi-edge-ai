import Foundation

// Tool use: the model asks for a tool (web search, read a page), the app runs
// it on the Pi through llama-server's /tools endpoint and sends the result back.
// Everything here is plain Swift, so ios/Tests/run.sh can test it anywhere.

/// Any JSON value, kept as it came, so the tool definitions the server lists
/// go back to it unchanged.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// A tool the server offers, as GET /tools lists it.
struct ServerTool: Decodable, Equatable, Sendable {
    let tool: String
    let display_name: String?
    let type: String?
    let permissions: [String: Bool]?
    /// The OpenAI-style definition the model gets to see.
    let definition: JSONValue

    /// The app can offer the model only tools from MCP servers in the Pi's
    /// mcp.json (such as web search), and only when the server says they don't
    /// write. llama-server's own file and shell tools (`--tools`) are never
    /// offered, and a tool that doesn't say is left out too.
    ///
    /// llama-server marks every MCP tool as not writing, whatever the tool
    /// does, so this is no promise that it only reads. That is why only the
    /// Pi's own web tools are switched on to begin with (`isOnByDefault`), any
    /// other tool waits until the person switches it on in Settings, and each
    /// one still asks before it runs, unless the person chose Always allow.
    var isUsableByApp: Bool { type == "mcp" && permissions?["write"] == false }

    /// The tools of the Pi's own web-search server (`./web-search.sh on`).
    /// llama-server names each MCP tool "<server>_<tool>" and skips a name it
    /// already has, so these can only be the tools of the server called "web"
    /// in mcp.json: the one web-search.sh writes.
    static let piWebTools: Set<String> = ["web_search", "web_fetch"]

    /// On until the person switches it off: the Pi's web search and page reading.
    var isOnByDefault: Bool { Self.piWebTools.contains(tool) }
}

/// A tool call, written the OpenAI way:
/// {"id": "…", "type": "function", "function": {"name": "…", "arguments": "{…}"}}
struct ToolCall: Codable, Equatable, Sendable {
    var id: String
    var name: String
    /// The arguments as the model wrote them: a JSON object, in a string.
    var arguments: String

    init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey { case id, type, function }
    private struct Function: Codable { var name: String; var arguments: String }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let f = try c.decode(Function.self, forKey: .function)
        name = f.name
        arguments = f.arguments
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode("function", forKey: .type)
        try c.encode(Function(name: name, arguments: arguments), forKey: .function)
    }

    /// The arguments read as JSON; an empty object if the model wrote something else.
    var parameters: JSONValue { objectArguments ?? .object([:]) }

    /// The arguments, if they are a JSON object.
    var objectArguments: JSONValue? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)),
              case .object = value else { return nil }
        return value
    }
}

/// One piece of a tool call in a streamed answer. The first piece of a call
/// carries its id and name, the following ones add to its arguments.
struct ToolCallDelta: Decodable, Sendable {
    struct Function: Decodable, Sendable {
        let name: String?
        let arguments: String?
    }
    let index: Int?
    let id: String?
    let function: Function?
}

/// Puts the pieces of streamed tool calls back together.
struct ToolCallAccumulator {
    private var calls: [Int: ToolCall] = [:]
    private var order: [Int] = []

    mutating func add(_ deltas: [ToolCallDelta]) {
        for delta in deltas {
            // OpenAI-style servers number the calls; without a number, a piece
            // with an id starts a new call and any other piece adds to the last one.
            let index = delta.index ?? (delta.id != nil || order.isEmpty ? order.count : order[order.count - 1])
            if calls[index] == nil {
                calls[index] = ToolCall(id: "", name: "", arguments: "")
                order.append(index)
            }
            if let id = delta.id, !id.isEmpty { calls[index]?.id = id }
            if let name = delta.function?.name { calls[index]?.name += name }
            if let arguments = delta.function?.arguments { calls[index]?.arguments += arguments }
        }
    }

    /// The finished calls, in order. A call without a name is dropped; one
    /// without an id gets one, since the result has to name the call it answers.
    /// Arguments that aren't a JSON object (none at all, or cut off) become
    /// {}: that is what the tool gets, and llama-server can refuse anything
    /// else when the call goes back with the history.
    var result: [ToolCall] {
        order.enumerated().compactMap { n, index in
            guard var call = calls[index], !call.name.isEmpty else { return nil }
            if call.id.isEmpty { call.id = "call_\(n)" }
            if call.objectArguments == nil { call.arguments = "{}" }
            return call
        }
    }
}

/// What POST /tools sends back, as the text the model gets: the tool's
/// plain-text answer, its error, or else the JSON as it came.
enum ToolResult {
    static func text(from data: Data) -> (text: String, failed: Bool) {
        if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            if let text = value["plain_text_response"]?.string { return (text, false) }
            if let error = value["error"]?.string { return (error, true) }
        }
        return (String(decoding: data, as: UTF8.self), false)
    }
}

/// How the chat names a tool step, from the call: what it is doing, did,
/// or asks to do.
struct ToolLabel: Equatable {
    /// "Searching the web for “weather Berlin”"
    let running: String
    /// "Searched the web for “weather Berlin”"
    let done: String
    /// "search the web for “weather Berlin”", for "The model wants to …"
    let ask: String
    /// The full address of a page to read, shown with the question.
    let detail: String?

    init(name: String, arguments: String) {
        let parameters = ToolCall(id: "", name: name, arguments: arguments).parameters
        let short = name.split(separator: "_").last.map(String.init) ?? name
        if short == "search", let query = parameters["query"]?.string, !query.isEmpty {
            let q = "“\(Self.clipped(query, 60))”"
            running = "Searching the web for \(q)"
            done = "Searched the web for \(q)"
            ask = "search the web for \(q)"
            detail = nil
        } else if short == "fetch", let url = parameters["url"]?.string, !url.isEmpty {
            let host = URL(string: url.contains("://") ? url : "https://" + url)?.host ?? Self.clipped(url, 40)
            running = "Reading \(host)"
            done = "Read \(host)"
            ask = "read a page on \(host)"
            detail = url
        } else {
            running = "Using \(name)"
            done = "Used \(name)"
            ask = "use \(name)"
            detail = arguments.isEmpty || arguments == "{}" ? nil : arguments
        }
    }

    private static func clipped(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
