import Foundation
import VoiceKit

// Offline, no-network self-check -- see Package.swift for why this exists
// instead of `swift test` in this sandbox. Exercises the same behaviors as
// Tests/VoiceKitTests/*.swift through VoiceKit's public API. Exits 1 if any
// check fails.

// Plain `var failures` would be implicitly @MainActor-isolated in a main.swift
// file, but closures handed to Speaker/EdgeTTSClient run off-actor -- so
// mutation goes through this thread-safe box instead.
final class FailureBox: @unchecked Sendable {
    private var items: [String] = []
    private let lock = NSLock()
    func add(_ name: String) {
        lock.lock(); items.append(name); lock.unlock()
    }
    var all: [String] {
        lock.lock(); defer { lock.unlock() }; return items
    }
}
let failures = FailureBox()

final class FallbackErrorBox: @unchecked Sendable {
    private var stored: Error?
    private let lock = NSLock()
    func set(_ error: Error) { lock.lock(); stored = error; lock.unlock() }
    func get() -> Error? { lock.lock(); defer { lock.unlock() }; return stored }
}

func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("OK   \(name)")
    } else {
        print("FAIL \(name)")
        failures.add(name)
    }
}

func expectThrows<T>(_ name: String, _ body: () async throws -> T) async {
    do {
        _ = try await body()
        print("FAIL \(name) (expected a throw, got a value)")
        failures.add(name)
    } catch {
        print("OK   \(name) threw \(error)")
    }
}

// -- mock EdgeTTSTransport, matching Tests/VoiceKitTests/MockTransport.swift --

final class SelfCheckTransport: EdgeTTSTransport, @unchecked Sendable {
    private let frames: [EdgeTTSFrame]
    private let openError: Error?
    private(set) var opened = false

    init(frames: [EdgeTTSFrame] = [], openError: Error? = nil) {
        self.frames = frames
        self.openError = openError
    }

    func open(url: URL, headers: [String: String]) async throws -> any EdgeTTSSession {
        opened = true
        if let openError { throw openError }
        return SelfCheckSession(frames: frames)
    }
}

final class SelfCheckSession: EdgeTTSSession, @unchecked Sendable {
    private var frames: [EdgeTTSFrame]
    init(frames: [EdgeTTSFrame]) { self.frames = frames }
    func send(_ text: String) async throws {}
    func next() async throws -> EdgeTTSFrame {
        guard !frames.isEmpty else { return .closed }
        return frames.removeFirst()
    }
    func close() {}
}

func audioFrame(_ payload: Data) -> Data {
    let header = "X-RequestId:test\r\nContent-Type:audio/mpeg\r\nPath:audio\r\n"
    let headerData = Data(header.utf8)
    var frame = Data()
    frame.append(UInt8((headerData.count >> 8) & 0xFF))
    frame.append(UInt8(headerData.count & 0xFF))
    frame.append(headerData)
    frame.append(payload)
    return frame
}

func textFrame(path: String) -> String {
    "X-RequestId:test\r\nContent-Type:application/json; charset=utf-8\r\nPath:\(path)\r\n\r\n{}"
}

struct Boom: Error {}

// -- 1. jitter recipe, cross-checked against Python voice.py::_edge_recipe --

let hello = EdgeRecipe.rateAndPitch(style: VoiceStyles.story, text: "hello")
check("jitter('hello') matches python (-4,-7)", hello.rate == -4 && hello.pitch == -7)

let goodbye = EdgeRecipe.rateAndPitch(style: VoiceStyles.story, text: "goodbye world")
check("jitter('goodbye world') matches python (-10,-7)", goodbye.rate == -10 && goodbye.pitch == -7)

let clean = EdgeRecipe.rateAndPitch(style: VoiceStyles.clean, text: "anything")
check("no-jitter style returns base values", clean.rate == 0 && clean.pitch == 0)

check("named() falls back to story for unknown", VoiceStyles.named("nope") == VoiceStyles.story)

// -- 2. EdgeTTSClient over a mocked transport --

do {
    let payloadA = Data([0x01, 0x02, 0x03])
    let payloadB = Data([0x04, 0x05])
    let transport = SelfCheckTransport(frames: [
        .text(textFrame(path: "turn.start")),
        .binary(audioFrame(payloadA)),
        .binary(audioFrame(payloadB)),
        .text(textFrame(path: "turn.end")),
    ])
    let client = EdgeTTSClient(transport: transport)
    let audio = try await client.synthesize(text: "hi", voice: "ru-RU-DmitryNeural", rate: -8, pitch: -6)
    check("client collects audio across binary frames", audio == payloadA + payloadB)
    check("client opened the mock transport", transport.opened)
}

await expectThrows("client throws noAudioReceived on empty turn.end") {
    let transport = SelfCheckTransport(frames: [.text(textFrame(path: "turn.end"))])
    return try await EdgeTTSClient(transport: transport).synthesize(text: "hi", voice: "v", rate: 0, pitch: 0)
}

await expectThrows("client throws malformedFrame on short binary frame") {
    let transport = SelfCheckTransport(frames: [.binary(Data([0x00]))])
    return try await EdgeTTSClient(transport: transport).synthesize(text: "hi", voice: "v", rate: 0, pitch: 0)
}

await expectThrows("client propagates transport open() failure") {
    let transport = SelfCheckTransport(openError: Boom())
    return try await EdgeTTSClient(transport: transport).synthesize(text: "hi", voice: "v", rate: 0, pitch: 0)
}

// -- 3. VoiceCache --

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = VoiceCache(directory: dir)
    let key = VoiceCache.key(text: "hi", voice: "v", rate: 0, pitch: 0)

    let miss = await cache.read(key)
    check("cache miss returns nil", miss == nil)

    await cache.write(key, data: Data([1, 2, 3]))
    let hit = await cache.read(key)
    check("cache roundtrip returns written bytes", hit == Data([1, 2, 3]))
}

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = VoiceCache(directory: dir, maxBytes: 25)
    await cache.write("old", data: Data(repeating: 0, count: 10))
    await cache.write("mid", data: Data(repeating: 0, count: 10))
    await cache.write("new", data: Data(repeating: 0, count: 10))
    let old = await cache.read("old")
    let mid = await cache.read("mid")
    let latest = await cache.read("new")
    check("eviction drops the oldest entry first", old == nil && mid != nil && latest != nil)
}

// -- 4. Speaker: cache hit skips network, transport failure falls back locally --

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = VoiceCache(directory: dir)
    let key = VoiceCache.key(text: "hi", voice: "ru-RU-DmitryNeural", rate: 0, pitch: 0)
    await cache.write(key, data: Data([7, 7, 7]))

    let transport = SelfCheckTransport(openError: Boom()) // would throw if ever opened
    let speaker = Speaker(transport: transport, cache: cache, localSynthesize: { _, _, _ in
        failures.add("cache-hit called local fallback")
        print("FAIL cache-hit called local fallback")
        return Data()
    })
    let wav = await speaker.speak(text: "hi", voice: "ru-RU-DmitryNeural", language: "ru-RU", style: VoiceStyles.clean)
    check("speak() returns cached bytes without opening transport", wav == Data([7, 7, 7]) && !transport.opened)
}

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = VoiceCache(directory: dir)
    let transport = SelfCheckTransport(openError: Boom())
    let fallbackError = FallbackErrorBox()
    let speaker = Speaker(
        transport: transport,
        cache: cache,
        onFallback: { fallbackError.set($0) },
        localSynthesize: { _, _, _ in Data([9, 9, 9]) }
    )
    let wav = await speaker.speak(text: "hi", voice: "ru-RU-DmitryNeural", language: "ru-RU", style: VoiceStyles.clean)
    check("speak() falls back to local synth on transport error", wav == Data([9, 9, 9]))
    check("speak() reports the transport error via onFallback", fallbackError.get() is Boom)

    let key = VoiceCache.key(text: "hi", voice: "ru-RU-DmitryNeural", rate: 0, pitch: 0)
    let cached = await cache.read(key)
    check("speak() caches the fallback result", cached == Data([9, 9, 9]))
}

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = VoiceCache(directory: dir)
    let transport = SelfCheckTransport(openError: Boom())
    let speaker = Speaker(transport: transport, cache: cache, localSynthesize: { _, _, _ in throw Boom() })
    let wav = await speaker.speak(text: "hi", voice: "ru-RU-DmitryNeural", language: "ru-RU", style: VoiceStyles.clean)
    check("speak() returns empty data (not a crash) when local fallback also fails", wav.isEmpty)
}

print("")
let failed = failures.all
if failed.isEmpty {
    print("ALL CHECKS PASSED")
    exit(0)
} else {
    print("\(failed.count) CHECK(S) FAILED: \(failed)")
    exit(1)
}
