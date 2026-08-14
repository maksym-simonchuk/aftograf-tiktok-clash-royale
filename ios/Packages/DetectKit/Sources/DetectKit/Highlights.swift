/// Port of `detect.py:138-172` — robust z-score, weighted combine, box-smoothed
/// greedy highlight selection.
public enum Highlights {
    /// `detect.py:138-139` `combine`.
    public static func combine(motion: [Double], flash: [Double], shake: [Double]) -> [Double] {
        let zm = robustZ(motion)
        let zf = robustZ(flash)
        let zs = robustZ(shake)
        let n = zm.count
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = zm[i] + 0.8 * zf[i] + 1.2 * zs[i]
        }
        return out
    }

    /// `detect.py:142-147` `_z` — robust z-score (MAD-scaled), clipped so one
    /// scene cut can't swamp a whole match.
    public static func robustZ(_ x: [Double]) -> [Double] {
        guard !x.isEmpty else { return [] }
        let med = median(x)
        let absDeviation = x.map { abs($0 - med) }
        let mad = median(absDeviation)
        let scale: Double
        if mad > 1e-9 {
            scale = 1.4826 * mad
        } else {
            let std = standardDeviation(x)
            scale = std != 0 ? std : 1.0
        }
        return x.map { min(max(($0 - med) / scale, -3.0), 6.0) }
    }

    /// `detect.py:150-172` `find_highlights` — box-smooth, then greedily pick
    /// the loudest live moments at least `minGap` apart. The single loudest
    /// in-match moment always survives, however quiet the match was; after that,
    /// candidates below `minHype` stop the search.
    public static func findHighlights(t: [Double], hype: [Double], live: [Bool], cfg: DetectConfig) -> [Double] {
        guard t.count >= 2 else { return [] }

        let fps = 1.0 / max(t[1] - t[0], 1e-6)
        let k = max(1, min(t.count, Int(cfg.smooth * fps)))
        let smoothed = boxSmoothSame(hype, k: k)

        let order = (0..<smoothed.count).sorted { smoothed[$0] > smoothed[$1] }
        var picked: [Double] = []
        for i in order {
            guard live[i] else { continue }
            if !picked.isEmpty, smoothed[i] < cfg.minHype { break }
            let moment = t[i]
            if picked.allSatisfy({ abs(moment - $0) >= cfg.minGap }) {
                picked.append(moment)
            }
            if picked.count >= cfg.maxHighlights { break }
        }
        return picked.sorted().map { ($0 * 1000).rounded() / 1000 }
    }

    /// numpy `convolve(x, ones(k)/k, mode="same")` — a centered box filter,
    /// left-biased by one sample when `k` is even (numpy's convention).
    static func boxSmoothSame(_ x: [Double], k: Int) -> [Double] {
        let n = x.count
        guard n > 0, k > 0 else { return x }
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + x[i] }
        let offset = (k - 1) / 2
        var out = [Double](repeating: 0, count: n)
        for j in 0..<n {
            let center = j + offset
            let lo = max(0, center - k + 1)
            let hi = min(n - 1, center)
            if hi >= lo {
                out[j] = (prefix[hi + 1] - prefix[lo]) / Double(k)
            }
        }
        return out
    }

    /// numpy `.std()` default (population std, ddof=0).
    static func standardDeviation(_ x: [Double]) -> Double {
        let n = Double(x.count)
        guard n > 0 else { return 0 }
        let mean = x.reduce(0, +) / n
        let variance = x.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        return variance.squareRoot()
    }
}
