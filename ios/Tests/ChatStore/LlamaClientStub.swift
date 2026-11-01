import Foundation
/// Stand-in for LlamaClient: streams "one two three … ten" slowly.
struct LlamaClient: Sendable {
    let baseURL: URL
    let apiKey: String
    struct ModelInfo: Decodable, Identifiable, Hashable, Sendable { let id: String }
    struct Timings: Decodable, Sendable { let prompt_n: Int?; let prompt_per_second: Double?; let predicted_n: Int?; let predicted_per_second: Double? }
    enum StreamEvent: Sendable { case content(String); case reasoning(String); case done(Timings?) }
    struct WireMessage: Sendable { let role: String; let text: String; var imageJPEG: Data? = nil }
    nonisolated(unsafe) static var lastWire: [WireMessage] = []
    static func normalizedBaseURL(_ raw: String) -> URL? { URL(string: raw) }
    func models() async throws -> [ModelInfo] { [ModelInfo(id: "m")] }
    func streamChat(model: String, messages: [WireMessage], thinking: Bool) -> AsyncThrowingStream<StreamEvent, Error> {
        Self.lastWire = messages
        return AsyncThrowingStream { c in
            let t = Task {
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
