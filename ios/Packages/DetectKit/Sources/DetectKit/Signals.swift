import Accelerate
import MediaKit

/// Port of `detect.py:86-104` `compute_signals` — per-frame motion energy,
/// bright-flash ratio and camera-shake magnitude.
public enum Signals {
    public static func computeSignals(
        frames: GrayFrames, cfg: DetectConfig
    ) -> (motion: [Double], flash: [Double], shake: [Double]) {
        let n = frames.count
        var motion = [Double](repeating: 0, count: n)
        var flash = [Double](repeating: 0, count: n)
        var shake = [Double](repeating: 0, count: n)
        guard n > 0 else { return (motion, flash, shake) }

        let h = frames.height, w = frames.width
        let arenaTop = Int(Double(h) * cfg.arenaTop)
        let arenaBottom = Int(Double(h) * cfg.arenaBottom)
        let arenaHeight = arenaBottom - arenaTop
        guard arenaHeight > 0, w > 0 else { return (motion, flash, shake) }
        let arenaCount = arenaHeight * w

        var arenas = [[Float]]()
        arenas.reserveCapacity(n)
        for i in 0..<n {
            let f = frames.frame(i)
            let base = f.startIndex
            var arena = [Float](repeating: 0, count: arenaCount)
            for r in 0..<arenaHeight {
                let rowStart = base + (arenaTop + r) * w
                for c in 0..<w {
                    arena[r * w + c] = Float(f[rowStart + c])
                }
            }
            arenas.append(arena)

            var brightCount = 0
            for v in arena where v > 240 { brightCount += 1 }
            flash[i] = Double(brightCount) / Double(arenaCount)
        }

        guard n >= 2 else { return (motion, flash, shake) }

        let correlator = PhaseCorrelator(width: w, height: arenaHeight)
        var diff = [Float](repeating: 0, count: arenaCount)
        for i in 1..<n {
            vDSP_vsub(arenas[i - 1], 1, arenas[i], 1, &diff, 1, vDSP_Length(arenaCount))
            vDSP_vabs(diff, 1, &diff, 1, vDSP_Length(arenaCount))
            var meanAbsDiff: Float = 0
            vDSP_meanv(diff, 1, &meanAbsDiff, vDSP_Length(arenaCount))
            motion[i] = Double(meanAbsDiff)

            let (dx, dy) = correlator.correlate(arenas[i - 1], arenas[i])
            shake[i] = (dx * dx + dy * dy).squareRoot()
        }
        motion[0] = motion[1]
        shake[0] = shake[1]
        return (motion, flash, shake)
    }
}
