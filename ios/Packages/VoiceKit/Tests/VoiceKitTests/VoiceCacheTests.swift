import XCTest
@testable import VoiceKit

final class VoiceCacheTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func testWriteReadRoundtrip() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = VoiceCache(directory: dir)

        let key = VoiceCache.key(text: "hi", voice: "v", rate: 0, pitch: 0)
        let missing = await cache.read(key)
        XCTAssertNil(missing)

        await cache.write(key, data: Data([1, 2, 3]))
        let hit = await cache.read(key)
        XCTAssertEqual(hit, Data([1, 2, 3]))
    }

    func testKeyDependsOnAllFields() {
        let base = VoiceCache.key(text: "hi", voice: "v", rate: 0, pitch: 0)
        XCTAssertNotEqual(base, VoiceCache.key(text: "bye", voice: "v", rate: 0, pitch: 0))
        XCTAssertNotEqual(base, VoiceCache.key(text: "hi", voice: "v2", rate: 0, pitch: 0))
        XCTAssertNotEqual(base, VoiceCache.key(text: "hi", voice: "v", rate: 1, pitch: 0))
        XCTAssertNotEqual(base, VoiceCache.key(text: "hi", voice: "v", rate: 0, pitch: 1))
    }

    func testEvictsOldestFirstWhenOverBudget() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 10 bytes/entry, budget for ~2 entries -> writing a 3rd must evict the oldest.
        let cache = VoiceCache(directory: dir, maxBytes: 25)

        await cache.write("old", data: Data(repeating: 0, count: 10))
        await cache.write("mid", data: Data(repeating: 0, count: 10))
        await cache.write("new", data: Data(repeating: 0, count: 10))

        let old = await cache.read("old")
        let mid = await cache.read("mid")
        let new = await cache.read("new")
        XCTAssertNil(old, "oldest entry should have been evicted")
        XCTAssertNotNil(mid)
        XCTAssertNotNil(new)
    }
}
