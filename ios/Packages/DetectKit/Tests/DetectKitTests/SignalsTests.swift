import Testing
@testable import DetectKit
@testable import MediaKit

@Suite struct SignalsTests {
    @Test func flashCountsBrightPixelsAboveThreshold() {
        // one 4x4 frame, half bright (>240), half dark.
        var data = [UInt8](repeating: 0, count: 4 * 4)
        for i in 0..<8 { data[i] = 255 }
        let frames = GrayFrames(count: 1, height: 4, width: 4, data: data)
        var cfg = DetectConfig()
        cfg.arenaTop = 0.0
        cfg.arenaBottom = 1.0
        let (_, flash, _) = Signals.computeSignals(frames: frames, cfg: cfg)
        #expect(abs(flash[0] - 0.5) < 1e-9)
    }

    @Test func motionIsZeroForIdenticalConsecutiveFrames() {
        let one = [UInt8](repeating: 128, count: 4 * 4)
        var data = [UInt8]()
        data.append(contentsOf: one)
        data.append(contentsOf: one)
        data.append(contentsOf: one)
        let frames = GrayFrames(count: 3, height: 4, width: 4, data: data)
        var cfg = DetectConfig()
        cfg.arenaTop = 0.0
        cfg.arenaBottom = 1.0
        let (motion, _, _) = Signals.computeSignals(frames: frames, cfg: cfg)
        #expect(motion == [0, 0, 0])
    }

    @Test func motionReflectsMeanAbsoluteDifference() {
        var data = [UInt8]()
        data.append(contentsOf: [UInt8](repeating: 0, count: 4 * 4))
        data.append(contentsOf: [UInt8](repeating: 10, count: 4 * 4)) // uniform +10 shift
        let frames = GrayFrames(count: 2, height: 4, width: 4, data: data)
        var cfg = DetectConfig()
        cfg.arenaTop = 0.0
        cfg.arenaBottom = 1.0
        let (motion, _, _) = Signals.computeSignals(frames: frames, cfg: cfg)
        // motion[0] mirrors motion[1] per detect.py:103.
        #expect(abs(motion[1] - 10.0) < 1e-4)
        #expect(motion[0] == motion[1])
    }

    @Test func shakeDetectsATranslatedArena() {
        // 32x32 frame with a bright square; second frame shifts it by (3, 2).
        let w = 32, h = 32
        func blank() -> [UInt8] { [UInt8](repeating: 20, count: w * h) }
        var f0 = blank()
        var f1 = blank()
        for r in 10..<20 {
            for c in 10..<20 { f0[r * w + c] = 220 }
        }
        for r in 12..<22 {
            for c in 13..<23 { f1[r * w + c] = 220 }
        }
        var data = [UInt8]()
        data.append(contentsOf: f0)
        data.append(contentsOf: f1)
        let frames = GrayFrames(count: 2, height: h, width: w, data: data)
        var cfg = DetectConfig()
        cfg.arenaTop = 0.0
        cfg.arenaBottom = 1.0
        let (_, _, shake) = Signals.computeSignals(frames: frames, cfg: cfg)
        // exact subpixel shift isn't asserted (FFT peak is integer-resolution);
        // the signal must clearly react to a real translation.
        #expect(shake[1] > 1.0)
    }

    @Test func emptyAndSingleFrameInputsDoNotCrash() {
        let empty = GrayFrames(count: 0, height: 4, width: 4, data: [])
        let (m0, f0, s0) = Signals.computeSignals(frames: empty, cfg: DetectConfig())
        #expect(m0.isEmpty && f0.isEmpty && s0.isEmpty)

        let single = GrayFrames(count: 1, height: 4, width: 4, data: [UInt8](repeating: 0, count: 16))
        let (m1, f1, s1) = Signals.computeSignals(frames: single, cfg: DetectConfig())
        #expect(m1 == [0])
        #expect(s1 == [0])
        #expect(f1.count == 1)
    }
}
