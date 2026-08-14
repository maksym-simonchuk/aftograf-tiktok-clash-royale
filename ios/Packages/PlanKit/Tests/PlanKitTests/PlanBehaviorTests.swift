import Darwin
import Testing
@testable import PlanKit

// Behavioral port of tests/test_plan.py (synthetic fixtures, no golden dependency).
// `import Darwin` (not Foundation) for `exp` -- see GoldenFixture.swift's header
// for why a Testing file can't also `import Foundation` here.

func makeAnalysis(_ name: String, duration: Double, events: [Double]) -> AnalysisInput {
    var t: [Double] = []
    var x = 0.0
    while x < duration {
        t.append(x)
        x += 0.1
    }
    let hype: [Double] = t.map { ti in
        events.reduce(0.0) { acc, e in
            let d = (ti - e) / 1.5
            return acc + exp(-(d * d)) * 4.0
        }
    }
    return AnalysisInput(
        path: "/tmp/\(name).mp4", duration: duration, t: t, hype: hype,
        highlights: events, actionStart: 0.0, actionEnd: duration - 2.0
    )
}

@Suite struct PlanBehaviorTests {
    @Test func montageHitsTargetDurationWhenMaterialAllows() throws {
        let events = (0..<10).map { 20.0 + 25.0 * Double($0) }
        let plan = try buildPlan([makeAnalysis("a", duration: 300.0, events: events)],
                                  PlanConfig(targetDuration: 42.0))
        #expect(plan.groups.map { $0.name } == ["montage_v1", "montage_v2", "montage_v3"])
        #expect(abs(plan.groups[0].outDuration - 42.0) <= 3.0)
    }

    @Test func noCaptionIsReusedAcrossVariants() throws {
        let events = (0..<10).map { 20.0 + 25.0 * Double($0) }
        let plan = try buildPlan([makeAnalysis("a", duration: 300.0, events: events)],
                                  PlanConfig(targetDuration: 42.0))
        let lines = plan.groups.flatMap { g in g.segments.dropFirst().compactMap { $0.caption.isEmpty ? nil : $0.caption } }
        #expect(lines.count > 12)
        #expect(Set(lines).count == lines.count)
    }

    @Test func adlibsAreSpokenBetweenTheCaptionsAndNeverRepeat() throws {
        let events = (0..<10).map { 20.0 + 25.0 * Double($0) }
        let plan = try buildPlan([makeAnalysis("a", duration: 300.0, events: events)],
                                  PlanConfig(targetDuration: 42.0))
        let lines = plan.groups.flatMap { g in g.segments.compactMap { $0.adlib.isEmpty ? nil : $0.adlib } }
        #expect(lines.count >= 3)
        #expect(Set(lines).count == lines.count)
        // spoken reactions live where nothing is written, so the two never overlap
        for g in plan.groups {
            for s in g.segments {
                #expect(!(!s.adlib.isEmpty && !s.caption.isEmpty))
            }
        }
    }

    @Test func variantsDifferInLengthAndOpening() throws {
        let events = (0..<10).map { 20.0 + 25.0 * Double($0) }
        let plan = try buildPlan([makeAnalysis("a", duration: 300.0, events: events)],
                                  PlanConfig(targetDuration: 42.0))
        let durations = plan.groups.map { $0.outDuration }
        #expect(durations[1] < durations[0])
        #expect(durations[0] < durations[2])
        #expect(Set(plan.groups.map { $0.segments[0].start }).count == 3)
        #expect(Set(plan.groups.map { $0.title }).count == 3)
    }

    @Test func trimmingConvergesOnAnExtremeTarget() throws {
        // Regression: float dust in the trim loop used to hang the whole run.
        let events = (0..<10).map { 20.0 + 25.0 * Double($0) }
        let plan = try buildPlan([makeAnalysis("a", duration: 300.0, events: events)],
                                  PlanConfig(targetDuration: 2.0))
        #expect(plan.groups[0].outDuration < 6.0)
    }

    @Test func shortMaterialYieldsAShorterMontageNeverPadding() throws {
        let analyses = [makeAnalysis("a", duration: 180.0, events: [30.0, 75.0])]
        let plan = try buildPlan(analyses, PlanConfig(targetDuration: 42.0))
        #expect(plan.groups[0].outDuration > 0)
        #expect(plan.groups[0].outDuration < 42.0)
    }

    @Test func montageOpensWithTheBestMoment() throws {
        let analyses = [makeAnalysis("a", duration: 180.0, events: [30.0, 75.0, 120.0, 160.0])]
        let segments = try buildPlan(analyses, PlanConfig()).groups[0].segments
        #expect(segments[0].kind == "hook")
        #expect(segments[0].outDuration <= 1.5)
        #expect(segments[0].score == segments.map { $0.score }.max())
    }

    @Test func bodyIsChronologicalAfterTheHook() throws {
        let analyses = [makeAnalysis("a", duration: 180.0, events: [30.0, 75.0, 120.0, 160.0])]
        let body = try buildPlan(analyses, PlanConfig()).groups[0].segments.dropFirst()
        let starts = body.map { $0.start }
        #expect(starts == starts.sorted())
    }

    @Test func planIsDeterministic() throws {
        let analyses = [makeAnalysis("a", duration: 180.0, events: [30.0, 75.0, 120.0, 160.0])]
        let first = try buildPlan(analyses, PlanConfig())
        let second = try buildPlan(analyses, PlanConfig())
        #expect(first.groups.map { $0.name } == second.groups.map { $0.name })
        for (g1, g2) in zip(first.groups, second.groups) {
            #expect(g1.segments.map { $0.start } == g2.segments.map { $0.start })
            #expect(g1.segments.map { $0.end } == g2.segments.map { $0.end })
        }
    }

    @Test func aClipBundlesUpToThreeEvents() throws {
        let analyses = [makeAnalysis("a", duration: 90.0, events: [20.0, 45.0, 70.0])]
        let plan = try buildPlan(analyses, PlanConfig(mode: "clips"))
        #expect(plan.groups.map { $0.name } == ["a_01"])
        #expect(plan.groups[0].segments.filter { $0.kind == "hit" }.count == 3)
        #expect(plan.groups[0].outDuration >= 8.0)
        #expect(plan.groups[0].outDuration <= 20.0)
    }

    @Test func aClipOpensColdOnItsBestMoment() throws {
        // payoff first: a teaser of the strongest hit, hard-cut into the chronology
        let analyses = [makeAnalysis("a", duration: 90.0, events: [20.0, 45.0, 70.0])]
        let group = try buildPlan(analyses, PlanConfig(mode: "clips")).groups[0]
        let first = group.segments[0]
        #expect(first.kind == "hook")
        #expect(first.score == group.segments.map { $0.score }.max())
        #expect(group.segments[1].transIn == 0.0) // a melt would soften the cut
        for s in group.segments where s.kind == "hit" {
            #expect(s.peak > 0)
        }
    }

    @Test func hookNeverReadsPastTheEndOfTheFile() throws {
        // a peak at the last frame must not ask ffmpeg for frames past EOF --
        // it silently under-delivers and every offset after the hook drifts
        let analyses = [makeAnalysis("a", duration: 30.0, events: [10.0, 20.0, 29.9])]
        var hooks: [Segment] = []
        for cfg in [PlanConfig(mode: "clips"), PlanConfig()] {
            let groupHooks = try buildPlan(analyses, cfg).groups.map { $0.segments[0] }
            for h in groupHooks { #expect(h.kind == "hook") }
            for h in groupHooks { #expect(h.start <= h.end); #expect(h.end <= 30.0) }
            hooks += groupHooks
        }
        #expect(hooks.contains { $0.end == 30.0 }) // the clamp actually engaged
    }

    @Test func fourEventsSplitIntoBalancedPairs() throws {
        // 2+2, not 3+1: a lone trailing one-event clip reads as a leftover
        let analyses = [makeAnalysis("a", duration: 200.0, events: [20.0, 60.0, 100.0, 140.0])]
        let plan = try buildPlan(analyses, PlanConfig(mode: "clips"))
        let hits = plan.groups.map { g in g.segments.filter { $0.kind == "hit" }.count }
        #expect(hits == [2, 2])
    }

    @Test func clipsNeverRunPastTheCapEvenSnappedToASlowGrid() throws {
        // merged windows make the longest clips; the slow grid stretches cuts outward,
        // so the cap has to hold after snapping, not before
        let analyses = [makeAnalysis("a", duration: 240.0, events: [30.0, 36.0, 90.0, 96.0, 150.0])]
        let beats = (0..<400).map { round3(Double($0) * 0.674) }
        let plan = try buildPlan(analyses, PlanConfig(mode: "clips"),
                                  tracks: ["slow.mp3"], grids: [beats])
        #expect(!plan.groups.isEmpty)
        for group in plan.groups {
            #expect(group.outDuration <= 20.0 + 1e-3)
        }
    }

    @Test func chainedHighlightsKeepEveryMoment() throws {
        // 10s apart: windows overlap (+-8/4) and chain-merged into a single window,
        // losing five moments of six; same-moment peaks (3s) still merge. Five
        // surviving windows then bundle 3+2 into two clips
        let analyses = [makeAnalysis("a", duration: 120.0, events: [20.0, 30.0, 40.0, 50.0, 60.0, 63.0])]
        let plan = try buildPlan(analyses, PlanConfig(mode: "clips"))
        #expect(plan.groups.map { g in g.segments.filter { $0.kind == "hit" }.count } == [3, 2])
        let starts = plan.groups.flatMap { $0.segments.dropFirst().map { $0.start } } // [0] is the hook
        #expect(starts == starts.sorted())
    }

    @Test func clipsAreSplitPerMatchAndChronological() throws {
        let analyses = [
            makeAnalysis("МАТЧ 1", duration: 200.0, events: [60.0, 30.0, 90.0, 120.0, 150.0]),
            makeAnalysis("b", duration: 90.0, events: [40.0]),
        ]
        let plan = try buildPlan(analyses, PlanConfig(mode: "clips"))
        #expect(plan.groups.map { $0.name } == ["МАТЧ_1_01", "МАТЧ_1_02", "b_01"])
        for group in plan.groups {
            #expect(Set(group.segments.map { $0.src }).count == 1) // a clip is one match
            let starts = group.segments.dropFirst().map { $0.start } // [0] is the cold-open hook
            #expect(starts == starts.sorted())
        }
        #expect(plan.groups[0].segments.last!.end <= plan.groups[1].segments[1].start)
    }

    @Test func aSparseGridNeverCostsAHighlightItsHit() throws {
        // period 4.0s: the snap window is half of that, wide enough that the trim
        // used to pop the last event's hit and leave a clip ending on a dangling lead
        let analyses = [makeAnalysis("a", duration: 240.0, events: [30.0, 36.0, 90.0, 96.0, 150.0])]
        let beats = (0..<200).map { round3(Double($0) * 4.0) }
        let plan = try buildPlan(analyses, PlanConfig(mode: "clips"),
                                  tracks: ["slow.mp3"], grids: [beats])
        #expect(plan.groups.map { g in g.segments.filter { $0.kind == "hit" }.count } == [3, 2])
        for group in plan.groups {
            #expect(group.segments.last!.kind != "lead")
            #expect(group.outDuration <= 20.0 + 1e-3)
        }
    }

    @Test func snappingNeverRewindsAcrossEventsInOneClip() throws {
        // a stretched tail of one event used to cross into the next event's lead:
        // the rendered clip visibly jumped backwards between two moments
        let analyses = [makeAnalysis("a", duration: 130.0,
                                      events: [31.08, 59.83, 60.77, 69.18, 110.94, 116.34, 116.41])]
        let beats = (0..<300).map { round3(Double($0) * 0.5809) } // 103.3 bpm
        let plan = try buildPlan(analyses, PlanConfig(mode: "clips"),
                                  tracks: ["t.mp3"], grids: [beats])
        for group in plan.groups {
            for (prev, seg) in zip(group.segments, group.segments.dropFirst()) {
                if seg.kind == "lead", seg.src == prev.src, prev.kind != "hook" {
                    #expect(seg.start >= prev.end - 1e-6)
                }
            }
        }
    }

    @Test func noHighlightsIsAClearError() {
        #expect(throws: (any Error).self) {
            try buildPlan([makeAnalysis("a", duration: 120.0, events: [])], PlanConfig())
        }
    }

    @Test func multipleSourcesAreIndexedAndOrdered() throws {
        let analyses = [makeAnalysis("a", duration: 90.0, events: [30.0]),
                         makeAnalysis("b", duration: 90.0, events: [40.0])]
        let plan = try buildPlan(analyses, PlanConfig(targetDuration: 60.0))
        let body = plan.groups[0].segments.dropFirst()
        #expect(plan.sources.count == 2)
        #expect(Set(body.map { $0.src }) == Set([0, 1]))
        let pairs = body.map { ($0.src, $0.start) }
        let sortedPairs = pairs.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        #expect(zip(pairs, sortedPairs).allSatisfy { $0.0 == $0.1 })
    }

    @Test func beatSnappingMovesCutsOntoBeats() throws {
        let analyses = [makeAnalysis("a", duration: 180.0, events: [30.0, 75.0, 120.0])]
        let beats = (0..<200).map { round3(Double($0) * 0.5) }
        let plan = try buildPlan(analyses, PlanConfig(targetDuration: 40.0), grids: [beats])
        var offsets: [Double] = []
        let timeline = plan.groups[0].timeline()
        for (seg, start) in timeline.dropLast() {
            let cut = start + seg.outDuration
            offsets.append(beats.map { abs(cut - $0) }.min()!)
        }
        #expect(offsets.max()! < 0.05)
    }

    @Test func eachVariantSnapsToTheGridOfItsOwnTrack() throws {
        let analyses = [makeAnalysis("a", duration: 180.0, events: [30.0, 75.0, 120.0])]
        let grids = [(0..<400).map { round3(Double($0) * 0.5) },  // 120 bpm
                     (0..<500).map { round3(Double($0) * 0.4) }]  // 150 bpm, off the other grid
        let plan = try buildPlan(analyses, PlanConfig(targetDuration: 40.0, variants: 2),
                                  tracks: ["a.mp3", "b.mp3"], grids: grids)
        #expect(plan.groups.map { $0.music } == ["a.mp3", "b.mp3"])
        for (group, beats) in zip(plan.groups, grids) {
            let cuts = group.timeline().dropLast().map { $0.start + $0.segment.outDuration }
            let worst = cuts.map { c in beats.map { abs(c - $0) }.min()! }.max()!
            #expect(worst < 0.05)
        }
    }

    @Test func aSlowTrackStillGetsEveryCutOnABeat() throws {
        // 89 bpm: beats 0.674s apart, so a cut can sit 0.337s from the nearest one --
        // further than the fixed 0.30s window, which is how real tracks fell off the grid
        let beats = (0..<300).map { round3(Double($0) * 0.674) }
        let plan = try buildPlan([makeAnalysis("a", duration: 180.0, events: [30.0, 75.0, 120.0])],
                                  PlanConfig(targetDuration: 40.0, variants: 1),
                                  tracks: ["slow.mp3"], grids: [beats])
        let cuts = plan.groups[0].timeline().dropLast().map { $0.start + $0.segment.outDuration }
        let worst = cuts.map { c in beats.map { abs(c - $0) }.min()! }.max()!
        #expect(worst < 0.05)
    }

    @Test func langFlagSwitchesCopy() throws {
        let analyses = [makeAnalysis("a", duration: 180.0, events: [30.0, 75.0, 120.0])]
        let ru = try buildPlan(analyses, PlanConfig(lang: "ru")).groups[0]
        let en = try buildPlan(analyses, PlanConfig(lang: "en")).groups[0]
        #expect(titles["ru"]!.contains(ru.title))
        #expect(titles["en"]!.contains(en.title))
        #expect(ru.hashtags.contains("#рек"))
        #expect(en.hashtags.contains("#fyp"))
    }

    @Test func emptyAnalysisRaises() {
        let empty = AnalysisInput(path: "/tmp/x.mp4", duration: 1.0, t: [], hype: [],
                                   highlights: [], actionStart: 0.0, actionEnd: 0.0)
        #expect(throws: (any Error).self) {
            try buildPlan([empty], PlanConfig())
        }
    }
}
