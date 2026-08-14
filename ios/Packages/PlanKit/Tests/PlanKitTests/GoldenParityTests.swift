import Testing
@testable import PlanKit

// Reads tests/golden/{analysis,plan_clips,plan_montage}.json from the repo root
// (written by scripts/export_golden.py) and checks that PlanKit's build_plan
// reproduces the same segment structure Python did, on the same fixture and
// PlanConfig(target_duration: 12.0) (see scripts/export_golden.py). Only
// numeric/structural fields are compared (src/start/end/speed/kind/peak/trans_in);
// title/caption/description text is bit-exact too (Copy.swift's stablePoolIndex)
// but scripts/export_golden.py never wrote it out, so it isn't asserted here.
//
// Foundation-touching JSON loading lives in GoldenFixture.swift, not here --
// see that file's header for why (missing _Testing_Foundation module).

@Suite struct GoldenParityTests {
    private func assertMatches(_ plan: EditPlan, golden: GoldenFixture.Plan) {
        #expect(plan.groups.map { $0.name } == golden.groups.map { $0.name })
        for (group, goldenGroup) in zip(plan.groups, golden.groups) {
            #expect(group.segments.count == goldenGroup.segments.count, "segment count mismatch in \(group.name)")
            for (seg, gseg) in zip(group.segments, goldenGroup.segments) {
                #expect(seg.src == gseg.src, "\(group.name) src")
                #expect(seg.kind == gseg.kind, "\(group.name) kind")
                #expect(abs(round3(seg.start) - gseg.start) < 1e-6, "\(group.name) start")
                #expect(abs(round3(seg.end) - gseg.end) < 1e-6, "\(group.name) end")
                #expect(abs(round3(seg.speed) - gseg.speed) < 1e-6, "\(group.name) speed")
                #expect(abs(round3(seg.peak) - gseg.peak) < 1e-6, "\(group.name) peak")
                #expect(abs(round3(seg.transIn) - gseg.trans_in) < 1e-6, "\(group.name) trans_in")
            }
        }
    }

    @Test(.enabled(if: GoldenFixture.exists("plan_clips.json")))
    func clipsMatchPythonGolden() throws {
        let golden: GoldenFixture.Plan = try GoldenFixture.load("plan_clips.json")
        let analysis = try GoldenFixture.fixtureAnalysis()
        let plan = try buildPlan([analysis], PlanConfig(mode: "clips", targetDuration: 12.0))
        assertMatches(plan, golden: golden)
    }

    @Test(.enabled(if: GoldenFixture.exists("plan_montage.json")))
    func montageMatchesPythonGolden() throws {
        let golden: GoldenFixture.Plan = try GoldenFixture.load("plan_montage.json")
        let analysis = try GoldenFixture.fixtureAnalysis()
        let plan = try buildPlan([analysis], PlanConfig(mode: "montage", targetDuration: 12.0))
        assertMatches(plan, golden: golden)
    }
}
