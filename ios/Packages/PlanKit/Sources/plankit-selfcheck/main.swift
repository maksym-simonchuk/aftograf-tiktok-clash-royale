import Foundation
@testable import PlanKit

// Framework-free mirror of PlanKitTests/{PlanBehaviorTests,GoldenParityTests}.swift's
// assertions, runnable without XCTest/swift-testing: `swift run plankit-selfcheck`.
// Keep in sync with the Tests/ files, which are the ones `swift test` runs.

final class Counter: @unchecked Sendable {
    var failures = 0
}
let counter = Counter()

func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    if !condition() {
        counter.failures += 1
        print("FAIL \(file):\(line): \(message)")
    }
}

func checkThrows(_ message: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
    do {
        try body()
        counter.failures += 1
        print("FAIL \(file):\(line): \(message) (expected a throw, none happened)")
    } catch {
        // expected
    }
}

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

func run(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
    } catch {
        counter.failures += 1
        print("FAIL \(name): unexpected error \(error)")
    }
}

// MARK: - Behavioral (port of tests/test_plan.py, synthetic fixtures)

run("montageHitsTargetDurationWhenMaterialAllows") {
    let events = (0..<10).map { 20.0 + 25.0 * Double($0) }
    let plan = try buildPlan([makeAnalysis("a", duration: 300.0, events: events)],
                              PlanConfig(targetDuration: 42.0))
    check(plan.groups.map { $0.name } == ["montage_v1", "montage_v2", "montage_v3"], "group names")
    check(abs(plan.groups[0].outDuration - 42.0) <= 3.0, "outDuration near target")
}

run("noCaptionIsReusedAcrossVariants") {
    let events = (0..<10).map { 20.0 + 25.0 * Double($0) }
    let plan = try buildPlan([makeAnalysis("a", duration: 300.0, events: events)],
                              PlanConfig(targetDuration: 42.0))
    let lines = plan.groups.flatMap { g in g.segments.dropFirst().compactMap { $0.caption.isEmpty ? nil : $0.caption } }
    check(lines.count > 12, "enough captions")
    check(Set(lines).count == lines.count, "no repeated caption")
}

run("adlibsAreSpokenBetweenTheCaptionsAndNeverRepeat") {
    let events = (0..<10).map { 20.0 + 25.0 * Double($0) }
    let plan = try buildPlan([makeAnalysis("a", duration: 300.0, events: events)],
                              PlanConfig(targetDuration: 42.0))
    let lines = plan.groups.flatMap { g in g.segments.compactMap { $0.adlib.isEmpty ? nil : $0.adlib } }
    check(lines.count >= 3, "enough adlibs")
    check(Set(lines).count == lines.count, "no repeated adlib")
    for g in plan.groups {
        for s in g.segments {
            check(!(!s.adlib.isEmpty && !s.caption.isEmpty), "adlib/caption never overlap")
        }
    }
}

run("variantsDifferInLengthAndOpening") {
    let events = (0..<10).map { 20.0 + 25.0 * Double($0) }
    let plan = try buildPlan([makeAnalysis("a", duration: 300.0, events: events)],
                              PlanConfig(targetDuration: 42.0))
    let durations = plan.groups.map { $0.outDuration }
    check(durations[1] < durations[0], "v2 shorter than v1")
    check(durations[0] < durations[2], "v1 shorter than v3")
    check(Set(plan.groups.map { $0.segments[0].start }).count == 3, "distinct openings")
    check(Set(plan.groups.map { $0.title }).count == 3, "distinct titles")
}

run("trimmingConvergesOnAnExtremeTarget") {
    let events = (0..<10).map { 20.0 + 25.0 * Double($0) }
    let plan = try buildPlan([makeAnalysis("a", duration: 300.0, events: events)],
                              PlanConfig(targetDuration: 2.0))
    check(plan.groups[0].outDuration < 6.0, "trim converges")
}

run("shortMaterialYieldsAShorterMontageNeverPadding") {
    let analyses = [makeAnalysis("a", duration: 180.0, events: [30.0, 75.0])]
    let plan = try buildPlan(analyses, PlanConfig(targetDuration: 42.0))
    check(plan.groups[0].outDuration > 0, "non-empty")
    check(plan.groups[0].outDuration < 42.0, "no padding")
}

run("montageOpensWithTheBestMoment") {
    let analyses = [makeAnalysis("a", duration: 180.0, events: [30.0, 75.0, 120.0, 160.0])]
    let segments = try buildPlan(analyses, PlanConfig()).groups[0].segments
    check(segments[0].kind == "hook", "opens with hook")
    check(segments[0].outDuration <= 1.5, "hook is short")
    check(segments[0].score == segments.map { $0.score }.max(), "hook is the best score")
}

run("bodyIsChronologicalAfterTheHook") {
    let analyses = [makeAnalysis("a", duration: 180.0, events: [30.0, 75.0, 120.0, 160.0])]
    let body = try buildPlan(analyses, PlanConfig()).groups[0].segments.dropFirst()
    let starts = body.map { $0.start }
    check(starts == starts.sorted(), "chronological")
}

run("planIsDeterministic") {
    let analyses = [makeAnalysis("a", duration: 180.0, events: [30.0, 75.0, 120.0, 160.0])]
    let first = try buildPlan(analyses, PlanConfig())
    let second = try buildPlan(analyses, PlanConfig())
    check(first.groups.map { $0.name } == second.groups.map { $0.name }, "same names")
    for (g1, g2) in zip(first.groups, second.groups) {
        check(g1.segments.map { $0.start } == g2.segments.map { $0.start }, "same starts")
        check(g1.segments.map { $0.end } == g2.segments.map { $0.end }, "same ends")
    }
}

run("aClipBundlesUpToThreeEvents") {
    let analyses = [makeAnalysis("a", duration: 90.0, events: [20.0, 45.0, 70.0])]
    let plan = try buildPlan(analyses, PlanConfig(mode: "clips"))
    check(plan.groups.map { $0.name } == ["a_01"], "single group")
    check(plan.groups[0].segments.filter { $0.kind == "hit" }.count == 3, "3 hits")
    check(plan.groups[0].outDuration >= 8.0, "min out")
    check(plan.groups[0].outDuration <= 20.0, "max out")
}

run("aClipOpensColdOnItsBestMoment") {
    let analyses = [makeAnalysis("a", duration: 90.0, events: [20.0, 45.0, 70.0])]
    let group = try buildPlan(analyses, PlanConfig(mode: "clips")).groups[0]
    let first = group.segments[0]
    check(first.kind == "hook", "opens with hook")
    check(first.score == group.segments.map { $0.score }.max(), "hook is best score")
    check(group.segments[1].transIn == 0.0, "hard cut after hook")
    for s in group.segments where s.kind == "hit" {
        check(s.peak > 0, "hit has a peak")
    }
}

run("hookNeverReadsPastTheEndOfTheFile") {
    let analyses = [makeAnalysis("a", duration: 30.0, events: [10.0, 20.0, 29.9])]
    var hooks: [Segment] = []
    for cfg in [PlanConfig(mode: "clips"), PlanConfig()] {
        let groupHooks = try buildPlan(analyses, cfg).groups.map { $0.segments[0] }
        for h in groupHooks { check(h.kind == "hook", "is hook") }
        for h in groupHooks {
            check(h.start <= h.end, "start<=end")
            check(h.end <= 30.0, "clamped to EOF")
        }
        hooks += groupHooks
    }
    check(hooks.contains { $0.end == 30.0 }, "clamp actually engaged")
}

run("fourEventsSplitIntoBalancedPairs") {
    let analyses = [makeAnalysis("a", duration: 200.0, events: [20.0, 60.0, 100.0, 140.0])]
    let plan = try buildPlan(analyses, PlanConfig(mode: "clips"))
    let hits = plan.groups.map { g in g.segments.filter { $0.kind == "hit" }.count }
    check(hits == [2, 2], "2+2 split")
}

run("clipsNeverRunPastTheCapEvenSnappedToASlowGrid") {
    let analyses = [makeAnalysis("a", duration: 240.0, events: [30.0, 36.0, 90.0, 96.0, 150.0])]
    let beats = (0..<400).map { round3(Double($0) * 0.674) }
    let plan = try buildPlan(analyses, PlanConfig(mode: "clips"), tracks: ["slow.mp3"], grids: [beats])
    check(!plan.groups.isEmpty, "non-empty")
    for group in plan.groups {
        check(group.outDuration <= 20.0 + 1e-3, "under cap")
    }
}

run("chainedHighlightsKeepEveryMoment") {
    let analyses = [makeAnalysis("a", duration: 120.0, events: [20.0, 30.0, 40.0, 50.0, 60.0, 63.0])]
    let plan = try buildPlan(analyses, PlanConfig(mode: "clips"))
    check(plan.groups.map { g in g.segments.filter { $0.kind == "hit" }.count } == [3, 2], "3+2 split")
    let starts = plan.groups.flatMap { $0.segments.dropFirst().map { $0.start } }
    check(starts == starts.sorted(), "chronological")
}

run("clipsAreSplitPerMatchAndChronological") {
    let analyses = [
        makeAnalysis("МАТЧ 1", duration: 200.0, events: [60.0, 30.0, 90.0, 120.0, 150.0]),
        makeAnalysis("b", duration: 90.0, events: [40.0]),
    ]
    let plan = try buildPlan(analyses, PlanConfig(mode: "clips"))
    check(plan.groups.map { $0.name } == ["МАТЧ_1_01", "МАТЧ_1_02", "b_01"], "sanitized names")
    for group in plan.groups {
        check(Set(group.segments.map { $0.src }).count == 1, "one match per clip")
        let starts = group.segments.dropFirst().map { $0.start }
        check(starts == starts.sorted(), "chronological")
    }
    check(plan.groups[0].segments.last!.end <= plan.groups[1].segments[1].start, "clip order")
}

run("aSparseGridNeverCostsAHighlightItsHit") {
    let analyses = [makeAnalysis("a", duration: 240.0, events: [30.0, 36.0, 90.0, 96.0, 150.0])]
    let beats = (0..<200).map { round3(Double($0) * 4.0) }
    let plan = try buildPlan(analyses, PlanConfig(mode: "clips"), tracks: ["slow.mp3"], grids: [beats])
    check(plan.groups.map { g in g.segments.filter { $0.kind == "hit" }.count } == [3, 2], "3+2 split")
    for group in plan.groups {
        check(group.segments.last!.kind != "lead", "never ends on lead")
        check(group.outDuration <= 20.0 + 1e-3, "under cap")
    }
}

run("snappingNeverRewindsAcrossEventsInOneClip") {
    let analyses = [makeAnalysis("a", duration: 130.0,
                                  events: [31.08, 59.83, 60.77, 69.18, 110.94, 116.34, 116.41])]
    let beats = (0..<300).map { round3(Double($0) * 0.5809) }
    let plan = try buildPlan(analyses, PlanConfig(mode: "clips"), tracks: ["t.mp3"], grids: [beats])
    for group in plan.groups {
        for (prev, seg) in zip(group.segments, group.segments.dropFirst()) {
            if seg.kind == "lead", seg.src == prev.src, prev.kind != "hook" {
                check(seg.start >= prev.end - 1e-6, "no rewind")
            }
        }
    }
}

checkThrows("noHighlightsIsAClearError") {
    _ = try buildPlan([makeAnalysis("a", duration: 120.0, events: [])], PlanConfig())
}

run("multipleSourcesAreIndexedAndOrdered") {
    let analyses = [makeAnalysis("a", duration: 90.0, events: [30.0]),
                     makeAnalysis("b", duration: 90.0, events: [40.0])]
    let plan = try buildPlan(analyses, PlanConfig(targetDuration: 60.0))
    let body = plan.groups[0].segments.dropFirst()
    check(plan.sources.count == 2, "2 sources")
    check(Set(body.map { $0.src }) == Set([0, 1]), "both used")
    let pairs = body.map { ($0.src, $0.start) }
    let sortedPairs = pairs.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
    check(zip(pairs, sortedPairs).allSatisfy { $0.0 == $0.1 }, "src-major ordering")
}

run("beatSnappingMovesCutsOntoBeats") {
    let analyses = [makeAnalysis("a", duration: 180.0, events: [30.0, 75.0, 120.0])]
    let beats = (0..<200).map { round3(Double($0) * 0.5) }
    let plan = try buildPlan(analyses, PlanConfig(targetDuration: 40.0), grids: [beats])
    var offsets: [Double] = []
    let timeline = plan.groups[0].timeline()
    for (seg, start) in timeline.dropLast() {
        let cut = start + seg.outDuration
        offsets.append(beats.map { abs(cut - $0) }.min()!)
    }
    check(offsets.max()! < 0.05, "cuts on beats")
}

run("eachVariantSnapsToTheGridOfItsOwnTrack") {
    let analyses = [makeAnalysis("a", duration: 180.0, events: [30.0, 75.0, 120.0])]
    let grids = [(0..<400).map { round3(Double($0) * 0.5) },
                 (0..<500).map { round3(Double($0) * 0.4) }]
    let plan = try buildPlan(analyses, PlanConfig(targetDuration: 40.0, variants: 2),
                              tracks: ["a.mp3", "b.mp3"], grids: grids)
    check(plan.groups.map { $0.music } == ["a.mp3", "b.mp3"], "own track per variant")
    for (group, beats) in zip(plan.groups, grids) {
        let cuts = group.timeline().dropLast().map { $0.start + $0.segment.outDuration }
        let worst = cuts.map { c in beats.map { abs(c - $0) }.min()! }.max()!
        check(worst < 0.05, "snapped to own grid")
    }
}

run("aSlowTrackStillGetsEveryCutOnABeat") {
    let beats = (0..<300).map { round3(Double($0) * 0.674) }
    let plan = try buildPlan([makeAnalysis("a", duration: 180.0, events: [30.0, 75.0, 120.0])],
                              PlanConfig(targetDuration: 40.0, variants: 1),
                              tracks: ["slow.mp3"], grids: [beats])
    let cuts = plan.groups[0].timeline().dropLast().map { $0.start + $0.segment.outDuration }
    let worst = cuts.map { c in beats.map { abs(c - $0) }.min()! }.max()!
    check(worst < 0.05, "snapped even on slow grid")
}

run("langFlagSwitchesCopy") {
    let analyses = [makeAnalysis("a", duration: 180.0, events: [30.0, 75.0, 120.0])]
    let ru = try buildPlan(analyses, PlanConfig(lang: "ru")).groups[0]
    let en = try buildPlan(analyses, PlanConfig(lang: "en")).groups[0]
    check(titles["ru"]!.contains(ru.title), "ru title from ru pool")
    check(titles["en"]!.contains(en.title), "en title from en pool")
    check(ru.hashtags.contains("#рек"), "ru hashtags")
    check(en.hashtags.contains("#fyp"), "en hashtags")
}

do {
    let empty = AnalysisInput(path: "/tmp/x.mp4", duration: 1.0, t: [], hype: [],
                               highlights: [], actionStart: 0.0, actionEnd: 0.0)
    checkThrows("emptyAnalysisRaises") {
        _ = try buildPlan([empty], PlanConfig())
    }
}

// MARK: - Golden parity (scripts/export_golden.py output, tests/golden/*.json)

private struct GoldenAnalysis: Decodable {
    let t: [Double]; let hype: [Double]; let highlights: [Double]
    let action_start: Double; let action_end: Double
}
private struct GoldenLabels: Decodable { let duration: Double }
private struct GoldenSegment: Decodable {
    let src: Int; let start: Double; let end: Double; let speed: Double
    let kind: String; let peak: Double; let trans_in: Double
}
private struct GoldenGroup: Decodable { let name: String; let segments: [GoldenSegment] }
private struct GoldenPlan: Decodable { let sources: [String]; let groups: [GoldenGroup] }

private func repoRoot() -> URL {
    // #filePath is .../ios/Packages/PlanKit/Sources/plankit-selfcheck/main.swift;
    // 6x deleteLastPathComponent: file -> plankit-selfcheck -> Sources -> PlanKit -> Packages -> ios -> repo root.
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { url.deleteLastPathComponent() }
    return url
}

private func goldenPath(_ name: String) -> URL {
    repoRoot().appendingPathComponent("tests/golden").appendingPathComponent(name)
}

private func loadGolden<T: Decodable>(_ name: String) throws -> T? {
    let url = goldenPath(name)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

private func assertMatches(_ plan: EditPlan, golden: GoldenPlan, label: String) {
    check(plan.groups.map { $0.name } == golden.groups.map { $0.name }, "\(label) group names")
    for (group, goldenGroup) in zip(plan.groups, golden.groups) {
        check(group.segments.count == goldenGroup.segments.count, "\(label)/\(group.name) segment count")
        for (seg, gseg) in zip(group.segments, goldenGroup.segments) {
            check(seg.src == gseg.src, "\(label)/\(group.name) src")
            check(seg.kind == gseg.kind, "\(label)/\(group.name) kind")
            check(abs(round3(seg.start) - gseg.start) < 1e-6, "\(label)/\(group.name) start")
            check(abs(round3(seg.end) - gseg.end) < 1e-6, "\(label)/\(group.name) end")
            check(abs(round3(seg.speed) - gseg.speed) < 1e-6, "\(label)/\(group.name) speed")
            check(abs(round3(seg.peak) - gseg.peak) < 1e-6, "\(label)/\(group.name) peak")
            check(abs(round3(seg.transIn) - gseg.trans_in) < 1e-6, "\(label)/\(group.name) trans_in")
        }
    }
}

run("goldenParity") {
    guard let analysis: GoldenAnalysis = try loadGolden("analysis.json"),
          let labels: GoldenLabels = try loadGolden("labels.json"),
          let clips: GoldenPlan = try loadGolden("plan_clips.json") else {
        print("SKIP goldenParity: tests/golden/*.json not generated yet (scripts/export_golden.py)")
        return
    }
    let fixture = AnalysisInput(
        path: clips.sources[0], duration: labels.duration, t: analysis.t,
        hype: analysis.hype, highlights: analysis.highlights,
        actionStart: analysis.action_start, actionEnd: analysis.action_end
    )
    let clipsPlan = try buildPlan([fixture], PlanConfig(mode: "clips", targetDuration: 12.0))
    assertMatches(clipsPlan, golden: clips, label: "clips")

    if let montage: GoldenPlan = try loadGolden("plan_montage.json") {
        let montagePlan = try buildPlan([fixture], PlanConfig(mode: "montage", targetDuration: 12.0))
        assertMatches(montagePlan, golden: montage, label: "montage")
    }
}

if counter.failures == 0 {
    print("OK: all checks passed")
    exit(0)
} else {
    print("FAILED: \(counter.failures) check(s) failed")
    exit(1)
}
