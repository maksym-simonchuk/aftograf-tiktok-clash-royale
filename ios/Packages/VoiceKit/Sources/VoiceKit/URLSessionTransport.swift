import Foundation

/// Real network transport for `EdgeTTSClient`. Never used by `swift test` --
/// only by `voicekit-smoke` and by `Speaker` at app runtime.
public struct URLSessionEdgeTTSTransport: EdgeTTSTransport {
    public init() {}

    public func open(url: URL, headers: [String: String]) async throws -> any EdgeTTSSession {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        return URLSessionEdgeTTSSession(task: task)
    }
}

final class URLSessionEdgeTTSSession: EdgeTTSSession, Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func next() async throws -> EdgeTTSFrame {
        let message = try await task.receive()
        switch message {
        case .string(let text):
            return .text(text)
        case .data(let data):
            return .binary(data)
        @unknown default:
            throw VoiceKitError.malformedFrame
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
