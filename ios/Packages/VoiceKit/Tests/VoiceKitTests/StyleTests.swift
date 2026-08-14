import XCTest
@testable import VoiceKit

final class StyleTests: XCTestCase {
    /// Cross-checked against Python `voice.py::_edge_recipe` for the same inputs:
    ///   recipe("hello", -8, -6)         -> (-4, -7)
    ///   recipe("goodbye world", -8, -6) -> (-10, -7)
    func testJitterMatchesPythonReference() {
        let a = EdgeRecipe.rateAndPitch(style: VoiceStyles.story, text: "hello")
        XCTAssertEqual(a.rate, -4)
        XCTAssertEqual(a.pitch, -7)

        let b = EdgeRecipe.rateAndPitch(style: VoiceStyles.story, text: "goodbye world")
        XCTAssertEqual(b.rate, -10)
        XCTAssertEqual(b.pitch, -7)
    }

    func testJitterIsDeterministicPerText() {
        let first = EdgeRecipe.rateAndPitch(style: VoiceStyles.story, text: "same line")
        let second = EdgeRecipe.rateAndPitch(style: VoiceStyles.story, text: "same line")
        XCTAssertEqual(first.rate, second.rate)
        XCTAssertEqual(first.pitch, second.pitch)
    }

    func testNoJitterStylesReturnBaseValuesUnchanged() {
        let (rate, pitch) = EdgeRecipe.rateAndPitch(style: VoiceStyles.clean, text: "anything at all")
        XCTAssertEqual(rate, 0)
        XCTAssertEqual(pitch, 0)
    }

    func testNamedFallsBackToStoryForUnknownName() {
        XCTAssertEqual(VoiceStyles.named("does-not-exist"), VoiceStyles.story)
        XCTAssertEqual(VoiceStyles.named("hype"), VoiceStyles.hype)
    }
}
