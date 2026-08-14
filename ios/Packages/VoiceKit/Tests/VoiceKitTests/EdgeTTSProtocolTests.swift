import XCTest
@testable import VoiceKit

final class EdgeTTSProtocolTests: XCTestCase {
    func testFullVoiceNameRewrite() {
        XCTAssertEqual(
            EdgeTTSWire.fullVoiceName("ru-RU-DmitryNeural"),
            "Microsoft Server Speech Text to Speech Voice (ru-RU, DmitryNeural)"
        )
        XCTAssertEqual(
            EdgeTTSWire.fullVoiceName("en-US-AndrewMultilingualNeural"),
            "Microsoft Server Speech Text to Speech Voice (en-US, AndrewMultilingualNeural)"
        )
    }

    func testEscapeXMLEscapesReservedCharacters() {
        XCTAssertEqual(EdgeTTSWire.escapeXML("A & B < C > D"), "A &amp; B &lt; C &gt; D")
    }

    func testEscapeXMLStripsControlCharacters() {
        let withControl = "hello\u{0001}world\u{000B}!"
        XCTAssertEqual(EdgeTTSWire.escapeXML(withControl), "hello world !")
    }

    func testSSMLEmbedsVoiceRateAndPitch() {
        let ssml = EdgeTTSWire.ssml(text: "hi & bye", voice: "ru-RU-DmitryNeural", rate: -8, pitch: -6)
        XCTAssertTrue(ssml.contains("Microsoft Server Speech Text to Speech Voice (ru-RU, DmitryNeural)"))
        XCTAssertTrue(ssml.contains("rate='-8%'"))
        XCTAssertTrue(ssml.contains("pitch='-6Hz'"))
        XCTAssertTrue(ssml.contains("hi &amp; bye"))
    }

    func testPathParsesHeaderOnlyFrame() {
        let header = "X-RequestId:r\r\nContent-Type:application/json; charset=utf-8\r\nPath:turn.end\r\n\r\n{}"
        XCTAssertEqual(EdgeTTSWire.path(ofHeaderText: header), "turn.end")
    }

    func testPathReturnsNilWhenMissing() {
        XCTAssertNil(EdgeTTSWire.path(ofHeaderText: "X-RequestId:r\r\n\r\n{}"))
    }
}
