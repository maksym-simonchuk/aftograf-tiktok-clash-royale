import Foundation

// Port of src/crcut/plan.py:316-606 (build_plan and its helpers).

/// `tracks` rotate over the groups and each group snaps to its own grid in `grids`.
///
/// A montage is three variants over three different songs, and a cut is only on the
/// beat of the song it is actually playing over -- one shared grid would put two of
/// the three variants off it. (plan.py:316-412)
public func buildPlan(
    _ analyses: [AnalysisInput],
    _ cfg: PlanConfig,
    tracks: [String] = [],
    grids: [[Double]] = []
) throws -> EditPlan {
    func musicOf(_ i: Int) -> String? {
        tracks.isEmpty ? nil : tracks[i % tracks.count]
    }
    func gridOf(_ i: Int) -> [Double]? {
        grids.isEmpty ? nil : grids[i % grids.count]
    }

    let sources = analyses.map { $0.path }
    let durs = analyses.map { $0.duration }
    let windows = buildWindows(analyses, cfg)
    if windows.isEmpty {
        // run with --debug and inspect out/debug/ (plan.py:340)
        throw PlanError.noHighlightWindows
    }

    let ranked = windows.sorted { $0.score > $1.score }
    let seed = sources.map { basename($0) }.joined(separator: "|")

    var groups: [Group] = []
    var cursor = 0 // walks the caption pool across groups, so no line is reused in one run
    var adCursor = 0

    if cfg.mode == "clips" {
        // per source and chronological, not by score: the output is one folder per
        // match, uploaded a folder at a time, so clips must read in match order
        var i = 0
        var stems = Set<String>()
        for (src, path) in sources.enumerated() {
            var stem = sanitizedStem(path)
            if stem.isEmpty { stem = "src\(src)" }
            if stems.contains(stem) { // two inputs with one stem would overwrite each other
                stem = "\(stem)_\(src)"
            }
            stems.insert(stem)

            let ws = windows.filter { $0.src == src }.sorted { $0.peak < $1.peak }
            var k = 1
            for chunk in chunked(ws, size: cfg.clipEvents) {
                let title = titleFor(cfg.lang, "\(seed)#\(stem)#\(k)")
                // cold open: the payoff shows first, the story explains it after --
                // a chronological build-up loses the viewer before the first hit
                let best = firstMax(chunk, by: { $0.score })
                let hook = hookSeg(best, cfg, durs[best.src])
                // a hair under the cap: beat snapping grows cuts, and the trim
                // that enforces the promise must find padding, not the payoff
                let budget = (cfg.clipMax - 2 * cfg.beatSnap - hook.outDuration)
                    / Double(chunk.count)
                let raw = [hook] + chunk.flatMap { segmentsFor($0, cfg, budget: budget) }
                var segments = decorate(raw, title, cfg, captionFrom: cursor, adlibFrom: adCursor)
                cursor += captionsUsed(segments)
                adCursor += adlibsUsed(segments)
                // snap first, cap second: the cap is a promise ("до 20 секунд"),
                // and the shot it may shorten ends the clip, where nothing is cut
                // to the beat anyway -- the music just fades out
                segments = snapped(segments, gridOf(i), cfg)
                segments = trimToTarget(segments, cfg.clipMax, cfg.minSegment,
                                         slack: 0.0, spareHits: true)
                let name = "\(stem)_\(String(format: "%02d", k))"
                groups.append(Group(name: name, title: title, hashtags: hashtagsFor(cfg.lang),
                                     segments: segments, music: musicOf(i)))
                i += 1
                k += 1
            }
        }
    } else {
        // several ready-to-post cuts, not one: different cold open, length and
        // copy, so there is something to pick between without re-running anything
        for v in 0..<max(1, cfg.variants) {
            let title = titleFor(cfg.lang, "\(seed)#\(v)")
            let target = cfg.targetDuration * variantScale[v % variantScale.count]
            var segments = montageSegments(ranked, cfg, target, durs, hook: v)
            segments = decorate(segments, title, cfg, shift: v,
                                 captionFrom: cursor, adlibFrom: adCursor)
            segments = trimToTarget(segments, target, cfg.minSegment)
            cursor += captionsUsed(segments)
            adCursor += adlibsUsed(segments)
            groups.append(
                Group(name: "montage_v\(v + 1)", title: title, hashtags: hashtagsFor(cfg.lang),
                      segments: snapped(segments, gridOf(v), cfg), music: musicOf(v))
            )
        }
    }

    var events: [String: [Double]] = [:]
    for a in analyses { events[basename(a.path)] = a.highlights }

    return EditPlan(
        version: planVersion,
        mode: cfg.mode,
        lang: cfg.lang,
        width: cfg.width,
        height: cfg.height,
        fps: cfg.fps,
        music: musicOf(0),
        voice: cfg.voice,
        voiceStyle: cfg.voiceStyle,
        sources: sources,
        groups: groups,
        events: events
    )
}

/// Cross-fades, on-screen captions and the reactions only the narrator says. (plan.py:415-425)
func decorate(
    _ segments: [Segment], _ title: String, _ cfg: PlanConfig,
    shift: Int = 0, captionFrom: Int = 0, adlibFrom: Int = 0
) -> [Segment] {
    let withCaptions = assignCaptions(assignTransitions(segments, cfg, shift: shift),
                                       title, cfg, start: captionFrom)
    return assignAdlibs(withCaptions, cfg, start: adlibFrom)
}

/// Cross-fade only where the picture actually jumps.
///
/// Inside one window lead/hit/tail are contiguous source frames, so a fade there
/// would read as a stutter rather than a transition. (plan.py:428-446)
func assignTransitions(_ segments: [Segment], _ cfg: PlanConfig, shift: Int = 0) -> [Segment] {
    var segments = segments
    for i in segments.indices {
        guard i > 0 else { continue }
        let prev = segments[i - 1]
        if segments[i].src == prev.src && abs(segments[i].start - prev.end) < 0.05 { continue }
        if prev.kind == "hook" && cfg.mode == "clips" { continue } // a melt would soften the cut
        // a fade longer than a third of either shot swallows the shot itself
        let dur = min(min(cfg.transition, prev.outDuration / 3.0), segments[i].outDuration / 3.0)
        if dur < 0.12 { continue }
        segments[i].transIn = round3(dur)
        segments[i].transKind = transitions[(i + shift) % transitions.count]
    }
    return segments
}

/// `start` is a running position in the pool, not a per-group restart: two cuts
/// of the same match must not be captioned with the same lines. (plan.py:449-464)
func assignCaptions(_ segments: [Segment], _ title: String, _ cfg: PlanConfig, start: Int = 0) -> [Segment] {
    var segments = segments
    let pool = captions[cfg.lang] ?? captions["ru"]!
    var shown = 0
    for i in segments.indices {
        if i == 0 { // the hook in a montage, the opening shot in a clip
            segments[i].caption = plainText(title)
            segments[i].narrate = true // the opening line always gets read: it sets the voice up
        } else if segments[i].kind == "hit" {
            segments[i].caption = pool[(start + shown) % pool.count]
            segments[i].narrate = shown % 2 == 0 // the rest are read every other time
            shown += 1
        }
    }
    return segments
}

/// Spoken reactions that are never written on screen.
///
/// They sit on the tail of a moment: the caption is read as the hit lands, the
/// old man comments right after it, so the two never talk over each other. (plan.py:467-480)
func assignAdlibs(_ segments: [Segment], _ cfg: PlanConfig, start: Int = 0) -> [Segment] {
    var segments = segments
    let pool = adlibs[cfg.lang] ?? adlibs["ru"]!
    var used = 0
    var tailIndex = 0
    for i in segments.indices where segments[i].kind == "tail" {
        defer { tailIndex += 1 }
        if tailIndex % 3 != 0 { continue } // every third tail -- more often and he never shuts up
        segments[i].adlib = pool[(start + used) % pool.count]
        used += 1
    }
    return segments
}

func captionsUsed(_ segments: [Segment]) -> Int {
    segments.dropFirst().filter { $0.kind == "hit" }.count
}

func adlibsUsed(_ segments: [Segment]) -> Int {
    segments.filter { !$0.adlib.isEmpty }.count
}

/// Teaser of the strongest moment. The end is clamped to the file: past EOF
/// ffmpeg silently delivers fewer frames than the plan declares, and every
/// cut and xfade offset after that drifts. (plan.py:491-497)
func hookSeg(_ best: Window, _ cfg: PlanConfig, _ dur: Double) -> Segment {
    let end = min(best.peak + cfg.hookLen / 2, dur)
    return Segment(src: best.src, start: max(0.0, end - cfg.hookLen), end: end,
                   speed: cfg.hookSpeed, kind: "hook", score: best.score)
}

// plan.py:500-519
func montageSegments(
    _ ranked: [Window], _ cfg: PlanConfig, _ target: Double, _ durs: [Double], hook: Int = 0
) -> [Segment] {
    var chosen: [Window] = []
    var total = 0.0
    for w in ranked {
        chosen.append(w)
        total += segmentsFor(w, cfg).reduce(0.0) { $0 + $1.outDuration }
        if total >= target { break }
    }

    let best = ranked[hook % ranked.count]
    let hookSegment = hookSeg(best, cfg, durs[best.src])

    var body: [Segment] = []
    for w in chosen.sorted(by: { ($0.src, $0.start) < ($1.src, $1.start) }) {
        body.append(contentsOf: segmentsFor(w, cfg))
    }

    return [hookSegment] + body
}

func outTotal(_ segments: [Segment]) -> Double {
    segments.reduce(0.0) { $0 + ($1.outDuration - $1.transIn) }
}

/// `slack` is how far past `target` is tolerable: a montage length is a taste,
/// a clip length is a promise. (plan.py:526-565)
func trimToTarget(
    _ segments: [Segment], _ target: Double, _ minSegment: Double,
    slack: Double = 1.5, spareHits: Bool = false
) -> [Segment] {
    var segments = segments
    // epsilon, not 0: a room of ~1e-17 leaves out_duration unchanged after the
    // subtraction and the loop never converges
    let eps = 1e-3
    if spareHits, segments.count > 1 {
        // a bundled clip runs close to the cap by construction, so cutting blindly
        // from the end would eat the last event's hit -- the payoff. Shave the
        // padding first: tails from their end, leads from their start, so every
        // event stays contiguous with its own hit and only blank footage goes
        for idx in stride(from: segments.count - 1, through: 1, by: -1) {
            let overshoot = outTotal(segments) - target
            if overshoot <= slack + eps { return segments }
            if segments[idx].kind == "hit" { continue }
            let give = min(segments[idx].outDuration - minSegment, overshoot) * segments[idx].speed
            if give <= eps { continue }
            if segments[idx].kind == "tail" {
                segments[idx].end -= give
            } else {
                segments[idx].start += give
            }
        }
    }
    var overshoot = outTotal(segments) - target
    while overshoot > slack + eps, segments.count > 1 {
        let lastIdx = segments.count - 1
        let room = segments[lastIdx].outDuration - minSegment
        if room <= eps {
            segments.removeLast()
        } else {
            segments[lastIdx].end -= min(room, overshoot) * segments[lastIdx].speed
        }
        overshoot = outTotal(segments) - target
    }
    return segments
}

// plan.py:568-606
func snapped(_ segments: [Segment], _ beats: [Double]?, _ cfg: PlanConfig) -> [Segment] {
    guard let beats, !beats.isEmpty else { return segments }

    // a fixed window cannot always reach the grid: at 89 bpm the beats are 0.67s
    // apart, so a cut may sit 0.34s from the nearest one and 0.30s of tolerance
    // never closes it. Half a beat always reaches, and never pulls further.
    let period = beats.count > 1 ? median(diffs(beats)) : 0.0
    let snap = max(cfg.beatSnap, period / 2)

    var segments = segments
    var outT = 0.0
    for i in segments.indices {
        outT -= segments[i].transIn
        let desired = outT + segments[i].outDuration
        // numpy argmin keeps the first minimal index on a tie; Swift's min(by:)
        // does the same (unlike max(by:), which keeps the last).
        let nearest = beats.min(by: { abs($0 - desired) < abs($1 - desired) })!
        let newLen = nearest - outT
        if abs(nearest - desired) <= snap, newLen >= cfg.minSegment {
            let delta = (newLen - segments[i].outDuration) * segments[i].speed
            // neighbouring events share the clip, so a stretched cut must stop at
            // the neighbour's footage: past it the clip visibly rewinds on screen.
            // Clamp only when the neighbour really was on the other side before the
            // stretch -- a montage hook sits anywhere in source time and is no wall
            if segments[i].kind == "tail" {
                let old = segments[i].end
                segments[i].end += delta
                if i + 1 < segments.count {
                    let nxt = segments[i + 1]
                    if nxt.src == segments[i].src, old <= nxt.start, nxt.start < segments[i].end {
                        segments[i].end = nxt.start
                    }
                }
            } else {
                let old = segments[i].start
                segments[i].start -= delta
                if segments[i].kind == "lead", i > 0 {
                    let prev = segments[i - 1]
                    if prev.src == segments[i].src, segments[i].start < prev.end, prev.end <= old {
                        segments[i].start = prev.end
                    }
                }
                if segments[i].start < 0 { segments[i].start = 0.0 }
            }
        }
        outT += segments[i].outDuration
    }
    return segments
}

// -- filesystem-name helpers (Path(...).name / Path(...).stem / re.sub) --

func basename(_ path: String) -> String {
    (path as NSString).lastPathComponent
}

/// `re.sub(r"[^\w-]+", "_", Path(path).stem)` (plan.py:353). ICU's `\w` is
/// Unicode-aware like Python's, so Cyrillic stems ("МАТЧ 1" -> "МАТЧ_1") match.
func sanitizedStem(_ path: String) -> String {
    let stem = (basename(path) as NSString).deletingPathExtension
    guard let regex = try? NSRegularExpression(pattern: "[^\\w-]+") else { return stem }
    let range = NSRange(stem.startIndex..., in: stem)
    return regex.stringByReplacingMatches(in: stem, range: range, withTemplate: "_")
}
