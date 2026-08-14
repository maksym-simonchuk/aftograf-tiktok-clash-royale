import Foundation

// Port of src/crcut/plan.py:273-313 (segments).

public func segmentsFor(_ w: Window, _ cfg: PlanConfig, budget: Double? = nil) -> [Segment] {
    let leadSpeed = cfg.mode == "montage" ? cfg.leadSpeed : 1.25
    let hitStart = max(w.start, w.peak - cfg.hitPre)
    let hitEnd = min(w.end, w.peak + cfg.hitPost)
    let maxLead: Double
    let tailEnd: Double
    if cfg.mode == "montage" {
        // the lead is capped so a merged window does not become one long unedited shot
        maxLead = cfg.maxLead * leadSpeed
        tailEnd = w.end
    } else {
        // events share the clip: each gets `budget` output seconds. The hit is the
        // payoff and stays whole; what is left splits lead-heavy, because the
        // build-up has to read while the aftermath only lingers
        let room = max(0.0, (budget ?? cfg.clipMax) - (hitEnd - hitStart) / cfg.hitSpeed)
        maxLead = min(cfg.clipPre, room * 0.7 * leadSpeed)
        tailEnd = min(w.end, hitEnd + room * 0.3)
    }
    let leadStart = max(w.start, hitStart - maxLead)

    var out: [Segment] = []
    if hitStart - leadStart >= cfg.minSegment {
        out.append(Segment(src: w.src, start: leadStart, end: hitStart, speed: leadSpeed,
                            kind: "lead", score: w.score))
    }
    if hitEnd - hitStart >= cfg.minSegment {
        out.append(Segment(src: w.src, start: hitStart, end: hitEnd, speed: cfg.hitSpeed,
                            kind: "hit", score: w.score, peak: w.peak))
    }
    if tailEnd - hitEnd >= cfg.minSegment {
        out.append(Segment(src: w.src, start: hitEnd, end: tailEnd, speed: 1.0,
                            kind: "tail", score: w.score))
    }
    return out
}

/// Balanced chronological chunks: five windows make 3+2, never 3+1+1 -- a lone
/// trailing one-event clip reads as a leftover, not a story. (plan.py:301-313)
func chunked(_ windows: [Window], size: Int) -> [[Window]] {
    if windows.isEmpty { return [] }
    let count = (windows.count + size - 1) / size // ceil division, mirrors -(-n // size)
    let base = windows.count / count
    let extra = windows.count % count
    var out: [[Window]] = []
    var i = 0
    for j in 0..<count {
        let step = base + (j < extra ? 1 : 0)
        out.append(Array(windows[i..<(i + step)]))
        i += step
    }
    return out
}
