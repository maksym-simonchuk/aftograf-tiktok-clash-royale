import XCTest
@testable import VoiceKit

final class EdgeTTSClientTests: XCTestCase {
    func testSynthesizeCollectsAudioAcrossFrames() async throws {
        let payloadA = Data([0x01, 0x02, 0x03])
        let payloadB = Data([0x04, 0x05])
        let frames: [EdgeTTSFrame] = [
            .text(makeTextFrame(path: "turn.start")),
            .text(makeTextFrame(path: "response")),
            .binary(makeAudioFrame(payload: payloadA)),
            .binary(makeAudioFrame(payload: payloadB)),
            .text(makeTextFrame(path: "turn.end")),
        ]
        let transport = MockTransport(frames: frames)
        let client = EdgeTTSClient(transport: transport)

        let audio = try await client.synthesize(text: "hi", voice: "ru-RU-DmitryNeural", rate: -8, pitch: -6)

        XCTAssertEqual(audio, payloadA + payloadB)
        XCTAssertTrue(transport.opened)
        XCTAssertEqual(transport.sent.count, 2, "speech.config + ssml")
    }

    func testSynthesizeThrowsWhenNoAudioReceived() async {
        let transport = MockTransport(frames: [.text(makeTextFrame(path: "turn.end"))])
        let client = EdgeTTSClient(transport: transport)
        do {
            _ = try await client.synthesize(text: "hi", voice: "ru-RU-DmitryNeural", rate: 0, pitch: 0)
            XCTFail("expected noAudioReceived")
        } catch VoiceKitError.noAudioReceived {
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testSynthesizeThrowsOnConnectionFailure() async {
        struct Boom: Error {}
        let transport = MockTransport(openError: Boom())
        let client = EdgeTTSClient(transport: transport)
        do {
            _ = try await client.synthesize(text: "hi", voice: "ru-RU-DmitryNeural", rate: 0, pitch: 0)
            XCTFail("expected Boom")
        } catch is Boom {
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testMalformedBinaryFrameThrows() async {
        let transport = MockTransport(frames: [.binary(Data([0x00]))])
        let client = EdgeTTSClient(transport: transport)
        do {
            _ = try await client.synthesize(text: "hi", voice: "ru-RU-DmitryNeural", rate: 0, pitch: 0)
            XCTFail("expected malformedFrame")
        } catch VoiceKitError.malformedFrame {
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testConnectionClosedBeforeTurnEndThrows() async {
        let transport = MockTransport(frames: [.text(makeTextFrame(path: "turn.start"))])
        let client = EdgeTTSClient(transport: transport)
        do {
            _ = try await client.synthesize(text: "hi", voice: "ru-RU-DmitryNeural", rate: 0, pitch: 0)
            XCTFail("expected connectionClosed")
        } catch VoiceKitError.connectionClosed {
        } catch { XCTFail("wrong error: \(error)") }
    }
}
