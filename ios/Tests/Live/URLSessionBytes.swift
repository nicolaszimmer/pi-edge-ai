// Linux only: URLSession has no bytes(for:) there. This reads the whole answer
// and then hands it out byte by byte and line by line, which is all
// LlamaClient uses. The code that reads the stream is the same, it just gets
// everything at once instead of token by token.
#if canImport(FoundationNetworking)
import Foundation
import FoundationNetworking

struct WholeBodyBytes: AsyncSequence, Sendable {
    typealias Element = UInt8
    let data: Data

    struct AsyncIterator: AsyncIteratorProtocol {
        let data: Data
        var index: Data.Index
        mutating func next() async -> UInt8? {
            guard index < data.endIndex else { return nil }
            defer { index = data.index(after: index) }
            return data[index]
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(data: data, index: data.startIndex) }

    var lines: AsyncStream<String> {
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        return AsyncStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}

extension URLSession {
    func bytes(for request: URLRequest) async throws -> (WholeBodyBytes, URLResponse) {
        let (data, response) = try await data(for: request)
        return (WholeBodyBytes(data: data), response)
    }
}
#endif
