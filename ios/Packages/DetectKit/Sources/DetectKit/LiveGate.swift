import Accelerate
import MediaKit

/// Port of `detect.py:107-135` `live_window`/`_longest_run` — the HUD-median
/// match-live gate.
public enum LiveGate {
    public static func liveWindow(frames: GrayFrames, t: [Double], cfg: DetectConfig) -> (Double, Double) {
        let n = frames.count
        guard n >= 8 else {
            return n > 0 ? (t[0], t[n - 1]) : (0.0, 0.0)
        }
        let h = frames.height, w = frames.width
        let hudTopRows = Int(Double(h) * cfg.hudTop)
        let hudBottomStart = Int(Double(h) * cfg.hudBottom)
        let bottomRows = h - hudBottomStart
        let hudRowCount = hudTopRows + bottomRows
        guard hudRowCount > 0, w > 0 else { return (t[0], t[n - 1]) }
        let elemCount = hudRowCount * w

        var hud = [[Float]](repeating: [], count: n)
        for i in 0..<n {
            let f = frames.frame(i)
            let base = f.startIndex
            var buf = [Float](repeating: 0, count: elemCount)
            var idx = 0
            for r in 0..<hudTopRows {
                let rowStart = base + r * w
                for c in 0..<w { buf[idx] = Float(f[rowStart + c]); idx += 1 }
            }
            for r in hudBottomStart..<h {
                let rowStart = base + r * w
                for c in 0..<w { buf[idx] = Float(f[rowStart + c]); idx += 1 }
            }
            hud[i] = buf
        }

        // reference = elementwise median over the middle half of the clip
        let lo = n / 4, hi = (3 * n) / 4
        var reference = [Float](repeating: 0, count: elemCount)
        var column = [Float](repeating: 0, count: hi - lo)
        for e in 0..<elemCount {
            for (k, i) in (lo..<hi).enumerated() { column[k] = hud[i][e] }
            reference[e] = medianFloat(&column)
        }

        var dissimilarity = [Double](repeating: 0, count: n)
        var diff = [Float](repeating: 0, count: elemCount)
        for i in 0..<n {
            vDSP_vsub(reference, 1, hud[i], 1, &diff, 1, vDSP_Length(elemCount))
            vDSP_vabs(diff, 1, &diff, 1, vDSP_Length(elemCount))
            var meanAbsDiff: Float = 0
            vDSP_meanv(diff, 1, &meanAbsDiff, vDSP_Length(elemCount))
            dissimilarity[i] = Double(meanAbsDiff)
        }

        let med = median(dissimilarity)
        let threshold = max(med * cfg.liveRatio, 1.0)
        let live = dissimilarity.map { $0 < threshold }
        let (first, last) = longestRun(live)
        return (t[first], t[last])
    }

    /// Port of `detect.py:124-135` `_longest_run`.
    static func longestRun(_ mask: [Bool]) -> (Int, Int) {
        var best = (0, mask.count - 1)
        var bestLen = 0
        var start: Int? = nil
        var extended = mask
        extended.append(false)
        for (i, on) in extended.enumerated() {
            if on, start == nil {
                start = i
            } else if !on, let s = start {
                if i - s > bestLen {
                    bestLen = i - s
                    best = (s, i - 1)
                }
                start = nil
            }
        }
        return best
    }
}

/// numpy-compatible median (average of the two middle elements when the count
/// is even). Sorts a copy; input order is untouched.
func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let n = sorted.count
    if n % 2 == 1 { return sorted[n / 2] }
    return (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
}

/// Same as `median(_:[Double])` but in/out `Float`, in place (mutates the
/// caller's scratch buffer — the caller owns and reuses it).
func medianFloat(_ values: inout [Float]) -> Float {
    guard !values.isEmpty else { return 0 }
    values.sort()
    let n = values.count
    if n % 2 == 1 { return values[n / 2] }
    return (values[n / 2 - 1] + values[n / 2]) / 2.0
}
