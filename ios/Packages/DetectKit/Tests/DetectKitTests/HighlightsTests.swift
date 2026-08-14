import Testing
@testable import DetectKit

@Suite struct HighlightsTests {
    // Cross-checked against `crcut.detect._z` (numpy) for the same input: n=6
    // is even, so np.median averages the two middle sorted values -> median=3.5,
    // mad=median(|x-3.5|)=1.5 -> scale=1.4826*1.5=2.2239; z=(x-3.5)/scale, clipped [-3,6].
    @Test func robustZMatchesPythonReference() {
        let x: [Double] = [1, 2, 3, 4, 5, 100]
        let z = Highlights.robustZ(x)
        let expected: [Double] = [
            -1.1241512657943253, -0.6744907594765952, -0.22483025315886507,
            0.22483025315886507, 0.6744907594765952, 6.0, // clipped
        ]
        #expect(z.count == expected.count)
        for (got, want) in zip(z, expected) {
            #expect(abs(got - want) < 1e-6)
        }
    }

    @Test func robustZFallsBackToStdDevWhenMADIsZero() {
        // constant-ish signal with one outlier: MAD of [0,0,0,0,10] is 0 -> use std.
        let x: [Double] = [0, 0, 0, 0, 10]
        let z = Highlights.robustZ(x)
        let std = Highlights.standardDeviation(x)
        #expect(abs(z[0] - (0 - 0) / std) < 1e-9)
        #expect(abs(z[4] - min((10 - 0) / std, 6.0)) < 1e-9)
    }

    @Test func boxSmoothSameMatchesNumpyConvolveSame() {
        // Verified against `np.convolve(x, np.ones(k)/k, mode="same")` in Python.
        let x: [Double] = [1, 2, 3, 4, 5, 6, 7]
        let k3 = Highlights.boxSmoothSame(x, k: 3)
        let wantK3: [Double] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 4.333333333333333]
        for (got, want) in zip(k3, wantK3) { #expect(abs(got - want) < 1e-9) }

        let k4 = Highlights.boxSmoothSame(x, k: 4)
        let wantK4: [Double] = [0.75, 1.5, 2.5, 3.5, 4.5, 5.5, 4.5]
        for (got, want) in zip(k4, wantK4) { #expect(abs(got - want) < 1e-9) }
    }

    @Test func findHighlightsEnforcesMinGapAndMaxCount() {
        var cfg = DetectConfig()
        cfg.smooth = 0.0001 // effectively no smoothing, isolate greedy-select logic
        cfg.minGap = 6.0
        cfg.maxHighlights = 6
        cfg.minHype = 0.5

        // frames every 1s for 30s; spikes at 5,6 (too close -> only one survives),
        // 15, 25; everything else near zero.
        let t = (0..<30).map { Double($0) }
        var hype = [Double](repeating: 0.0, count: 30)
        hype[5] = 5.0
        hype[6] = 4.9 // within min_gap of the t=5 spike, must be rejected
        hype[15] = 3.0
        hype[25] = 2.0
        let live = [Bool](repeating: true, count: 30)

        let picked = Highlights.findHighlights(t: t, hype: hype, live: live, cfg: cfg)
        #expect(picked == [5.0, 15.0, 25.0])
    }

    @Test func findHighlightsAlwaysKeepsTheBestMomentEvenBelowMinHype() {
        var cfg = DetectConfig()
        cfg.smooth = 0.0001
        cfg.minGap = 6.0
        cfg.minHype = 0.5

        let t = (0..<10).map { Double($0) }
        var hype = [Double](repeating: 0.0, count: 10)
        hype[3] = 0.1 // below min_hype, but it's the loudest -> must still be picked
        let live = [Bool](repeating: true, count: 10)

        let picked = Highlights.findHighlights(t: t, hype: hype, live: live, cfg: cfg)
        #expect(picked == [3.0])
    }

    @Test func findHighlightsExcludesNonLiveFrames() {
        var cfg = DetectConfig()
        cfg.smooth = 0.0001
        cfg.minGap = 6.0
        cfg.minHype = 0.5

        let t = (0..<10).map { Double($0) }
        var hype = [Double](repeating: 0.0, count: 10)
        hype[2] = 10.0 // loudest overall, but not live -> excluded
        hype[7] = 1.0
        var live = [Bool](repeating: true, count: 10)
        live[2] = false

        let picked = Highlights.findHighlights(t: t, hype: hype, live: live, cfg: cfg)
        #expect(picked == [7.0])
    }

    @Test func findHighlightsReturnsSortedResults() {
        var cfg = DetectConfig()
        cfg.smooth = 0.0001
        cfg.minGap = 6.0
        cfg.minHype = 0.5

        let t = (0..<20).map { Double($0) }
        var hype = [Double](repeating: 0.0, count: 20)
        hype[18] = 1.0
        hype[2] = 3.0
        hype[10] = 2.0
        let live = [Bool](repeating: true, count: 20)

        let picked = Highlights.findHighlights(t: t, hype: hype, live: live, cfg: cfg)
        #expect(picked == picked.sorted())
        #expect(picked == [2.0, 10.0, 18.0])
    }
}
