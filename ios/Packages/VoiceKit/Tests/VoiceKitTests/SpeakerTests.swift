import XCTest
@testable import VoiceKit

final class SpeakerTests: XCTestCase {
    private func tempCacheDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func testCacheHitSkipsNetwork() async throws {
        let dir = tempCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = VoiceCache(directory: dir)

        // Pre-seed the cache under the exact key speak() will look up (jitter is
        // off for VoiceStyles.clean, so rate/pitch are deterministic).
        let key = VoiceCache.key(text: "hi", voice: "ru-RU-DmitryNeural", rate: 0, pitch: 0)
        await cache.write(key, data: Data([7, 7, 7]))

        // Transport that throws if it's ever opened -- proves speak() never touched the network.
        let transport = MockTransport(openError: NSError(domain: "unexpected-network", code: 1))
        let speaker = Speaker(transport: transport, cache: cache, localSynthesize: { _, _, _ in
            XCTFail("local fallback should not run on a cache hit")
            return Data()
        })

        let wav = await speaker.speak(text: "hi", voice: "ru-RU-DmitryNeural", language: "ru-RU", style: VoiceStyles.clean)

        XCTAssertEqual(wav, Data([7, 7, 7]))
        XCTAssertFalse(transport.opened)
    }

    func testTransportFailureFallsBackToLocalAndCachesResult() async throws {
        let dir = tempCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = VoiceCache(directory: dir)

        struct Boom: Error {}
        let transport = MockTransport(openError: Boom())

        let fallbackError = LockedBox<Error>()
        let speaker = Speaker(
            transport: transport,
            cache: cache,
            onFallback: { fallbackError.set($0) },
            localSynthesize: { text, language, _ in
                XCTAssertEqual(text, "hi")
                XCTAssertEqual(language, "ru-RU")
                return Data([9, 9, 9])
            }
        )

        let wav = await speaker.speak(text: "hi", voice: "ru-RU-DmitryNeural", language: "ru-RU", style: VoiceStyles.clean)

        XCTAssertEqual(wav, Data([9, 9, 9]))
        XCTAssertTrue(fallbackError.get() is Boom)

        // Result must be cached so a second call skips both network and local synth.
        let key = VoiceCache.key(text: "hi", voice: "ru-RU-DmitryNeural", rate: 0, pitch: 0)
        let cached = await cache.read(key)
        XCTAssertEqual(cached, Data([9, 9, 9]))
    }

    func testLocalFallbackFailureReturnsEmptyDataWithoutCrashing() async throws {
        let dir = tempCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = VoiceCache(directory: dir)

        struct Boom: Error {}
        let transport = MockTransport(openError: Boom())
        let speaker = Speaker(transport: transport, cache: cache, localSynthesize: { _, _, _ in
            throw Boom()
        })

        let wav = await speaker.speak(text: "hi", voice: "ru-RU-DmitryNeural", language: "ru-RU", style: VoiceStyles.clean)

        XCTAssertTrue(wav.isEmpty)
    }
}
