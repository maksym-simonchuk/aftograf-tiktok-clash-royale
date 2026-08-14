import Testing
@testable import DetectKit
@testable import MediaKit

@Suite struct LiveGateTests {
    @Test func longestRunPicksTheLongestContiguousTrueStretch() {
        //                        0      1     2      3     4     5     6
        let mask = [true, true, false, true, true, true, false]
        let (first, last) = LiveGate.longestRun(mask)
        #expect(first == 3)
        #expect(last == 5)
    }

    @Test func longestRunAllFalseFallsBackToFullRange() {
        let mask = [false, false, false]
        let (first, last) = LiveGate.longestRun(mask)
        #expect(first == 0)
        #expect(last == mask.count - 1)
    }

    @Test func liveWindowFindsMatchStretchAroundStableHUD() {
        // 20 synthetic frames, 8x8, HUD (top/bottom rows) stable in [4,16),
        // noisy outside; low-frame-count `n < 8` fallback not exercised here.
        let w = 8, h = 8
        let n = 20
        var data = [UInt8](repeating: 0, count: n * h * w)
        for i in 0..<n {
            let base = i * h * w
            let isLive = i >= 4 && i < 16
            for r in 0..<h {
                for c in 0..<w {
                    // arena rows (between hudTop=0.14*8~1 and hudBottom=0.85*8~6) irrelevant to gate
                    var value: UInt8 = 50
                    if r < 1 || r >= 7 {
                        // HUD rows: stable at 200 while live, wildly different otherwise
                        value = isLive ? 200 : UInt8((i * 37 + r * 11 + c) % 255)
                    }
                    data[base + r * w + c] = value
                }
            }
        }
        let frames = GrayFrames(count: n, height: h, width: w, data: data)
        let t = (0..<n).map { Double($0) }
        let cfg = DetectConfig()
        let (start, end) = LiveGate.liveWindow(frames: frames, t: t, cfg: cfg)
        #expect(start == 4.0)
        #expect(end == 15.0)
    }

    @Test func liveWindowShortClipFallsBackToFullRange() {
        let frames = GrayFrames(count: 3, height: 4, width: 4, data: [UInt8](repeating: 0, count: 3 * 4 * 4))
        let t = [0.0, 1.0, 2.0]
        let (start, end) = LiveGate.liveWindow(frames: frames, t: t, cfg: DetectConfig())
        #expect(start == 0.0)
        #expect(end == 2.0)
    }
}
