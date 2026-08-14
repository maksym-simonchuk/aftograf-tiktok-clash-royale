import Foundation
@testable import VoiceKit

/// Replays a canned frame queue over `EdgeTTSTransport`/`EdgeTTSSession` -- no
/// sockets, no network. Set `openError` to simulate a connection failure (the
/// path that should drive `Speaker` to its `LocalTTS` fallback).
final class MockTransport: EdgeTTSTransport, @unchecked Sendable {
    private let frames: [EdgeTTSFrame]
    private let openError: Error?
    private(set) var opened = false
    private(set) var sent: [String] = []

    init(frames: [EdgeTTSFrame] = [], openError: Error? = nil) {
        self.frames = frames
        self.openError = openError
    }

    func open(url: URL, headers: [String: String]) async throws -> any EdgeTTSSession {
        opened = true
        if let openError { throw openError }
        return MockSession(frames: frames, onSend: { [weak self] text in self?.sent.append(text) })
    }
}

private final class MockSession: EdgeTTSSession, @unchecked Sendable {
    private var frames: [EdgeTTSFrame]
    private let onSend: (String) -> Void

    init(frames: [EdgeTTSFrame], onSend: @escaping (String) -> Void) {
        self.frames = frames
        self.onSend = onSend
    }

    func send(_ text: String) async throws {
        onSend(text)
    }

    func next() async throws -> EdgeTTSFrame {
        guard !frames.isEmpty else { return .closed }
        return frames.removeFirst()
    }

    func close() {}
}

/// Builds a binary audio frame matching the wire layout `EdgeTTSClient` expects:
/// [2-byte BE header length][header text ending "Path:audio\r\n"][mp3 payload] --
/// verified live against speech.platform.bing.com (see EdgeTTSClient.swift).
func makeAudioFrame(payload: Data) -> Data {
    let header = "X-RequestId:test\r\nContent-Type:audio/mpeg\r\nX-Timing:0\r\nPath:audio\r\n"
    let headerData = Data(header.utf8)
    var frame = Data()
    frame.append(UInt8((headerData.count >> 8) & 0xFF))
    frame.append(UInt8(headerData.count & 0xFF))
    frame.append(headerData)
    frame.append(payload)
    return frame
}

func makeTextFrame(path: String) -> String {
    "X-RequestId:test\r\nContent-Type:application/json; charset=utf-8\r\nPath:\(path)\r\n\r\n{}"
}

/// A plain `var` captured mutably by a `@Sendable` closure (e.g. `onFallback`) is
/// rejected under strict concurrency even in single-threaded test code -- this box
/// gives the closure somewhere safe to record its result.
final class LockedBox<T>: @unchecked Sendable {
    private var value: T?
    private let lock = NSLock()
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}
