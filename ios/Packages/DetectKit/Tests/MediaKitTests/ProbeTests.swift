import CoreGraphics
import Testing
@testable import MediaKit

@Suite struct ProbeTests {
    @Test func evenSizeRoundsToNearestEvenAndFloorsAtTwo() {
        // media.py:38 `_even`: max(2, round(n/2)*2). Python's `round` is
        // banker's rounding (half-to-even): round(119.5)=120, round(120.5)=120.
        #expect(evenSize(239) == 240)
        #expect(evenSize(240) == 240)
        #expect(evenSize(241) == 240)
        #expect(evenSize(0) == 2)
        #expect(evenSize(1) == 2)
    }

    @Test func rotationDegreesIdentity() {
        #expect(Probe.rotationDegrees(.identity) == 0)
    }

    @Test func rotationDegreesQuarterTurns() {
        // portrait recording transforms, as AVFoundation reports them.
        #expect(Probe.rotationDegrees(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)) == 90)
        #expect(Probe.rotationDegrees(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)) == 90)
        #expect(Probe.rotationDegrees(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)) == 180)
    }

    @Test(.enabled(if: GoldenFixture.locate() != nil))
    func probeReadsGoldenFixtureDimensionsAndDuration() async throws {
        guard let paths = GoldenFixture.locate() else { return }
        let labels = try GoldenFixture.loadLabels(paths.labels)
        let meta = try await Probe.probe(url: paths.video)
        #expect(meta.width == labels.width)
        #expect(meta.height == labels.height)
        #expect(abs(meta.duration - labels.duration) < 0.5)
    }
}
