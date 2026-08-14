import Foundation

// Port of src/crcut/plan.py:199-267 (windows).

public func buildWindows(_ analyses: [AnalysisInput], _ cfg: PlanConfig) -> [Window] {
    let pre = cfg.mode == "clips" ? cfg.clipPre : cfg.pre
    let post = cfg.mode == "clips" ? cfg.clipPost : cfg.post

    var windows: [Window] = []
    for (src, an) in analyses.enumerated() {
        let limit = min(an.duration, an.actionEnd + 1.0)

        var raw: [Window] = []
        for peak in an.highlights {
            let start = max(an.actionStart, peak - pre)
            let end = min(limit, peak + post)
            if end - start < 2.0 { continue }
            raw.append(Window(src: src, start: start, end: end, peak: peak, score: 0.0))
        }

        let split = cfg.mode == "clips" ? splitWindows(raw) : mergeWindows(raw)
        for var w in split {
            w.score = score(w, an, limit)
            windows.append(w)
        }
    }

    return windows
}

// plan.py:222-231
func mergeWindows(_ windows: [Window]) -> [Window] {
    var out: [Window] = []
    for w in windows.sorted(by: { $0.start < $1.start }) {
        if !out.isEmpty, w.start <= out[out.count - 1].end {
            out[out.count - 1].end = max(out[out.count - 1].end, w.end)
            out[out.count - 1].peak = w.peak
        } else {
            out.append(w)
        }
    }
    return out
}

/// Every moment keeps its own clip: neighbours split halfway instead of merging.
///
/// Merging is right for a montage (one long cut, the last peak carries the merged
/// window) but wrong for clips -- six highlights chained by overlap collapsed into
/// one file and five moments vanished. Only peaks close enough to be the same
/// moment (a double tower crash) still merge. (plan.py:234-255)
func splitWindows(_ windows: [Window], minGap: Double = 5.0) -> [Window] {
    var out: [Window] = []
    for var w in windows.sorted(by: { $0.peak < $1.peak }) {
        if !out.isEmpty, w.peak - out[out.count - 1].peak < minGap {
            out[out.count - 1].end = max(out[out.count - 1].end, w.end)
            out[out.count - 1].peak = w.peak
        } else if !out.isEmpty, w.start < out[out.count - 1].end {
            let mid = round3((out[out.count - 1].peak + w.peak) / 2)
            out[out.count - 1].end = mid
            w.start = mid
            out.append(w)
        } else {
            out.append(w)
        }
    }
    return out
}

// plan.py:258-267
func score(_ w: Window, _ an: AnalysisInput, _ limit: Double) -> Double {
    var hype: [Double] = []
    for i in 0..<an.t.count where an.t[i] >= w.start && an.t[i] <= w.end {
        hype.append(max(0.0, an.hype[i]))
    }
    if hype.isEmpty { return 0.0 }

    let mean = hype.reduce(0.0, +) / Double(hype.count)
    var result = mean + hype.max()!
    if w.peak >= limit - 30.0 { // clutch / overtime finish
        result *= 1.5
    }
    return result
}
