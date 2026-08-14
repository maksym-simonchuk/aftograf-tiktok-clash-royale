import Foundation
@testable import PlanKit

/// Loads tests/golden/{analysis,labels,plan_clips,plan_montage}.json (written by
/// scripts/export_golden.py) for GoldenParityTests. Kept out of the @Test file on
/// purpose: swift-testing's Foundation overlay (`_Testing_Foundation.framework`)
/// ships as an empty shell on a Command Line Tools-only Mac (no Modules/ dir), so
/// any file that `import Testing` AND `import Foundation` together trips Swift's
/// cross-import overlay and fails with "no such module '_Testing_Foundation'".
/// Splitting the Foundation-touching code into its own file with no `import
/// Testing` sidesteps that -- same root cause as DetectKit's GoldenTests.swift.
enum GoldenFixture {
    private static var repoRoot: URL {
        // #filePath here is .../ios/Packages/PlanKit/Tests/PlanKitTests/GoldenFixture.swift;
        // 6x deleteLastPathComponent: file -> PlanKitTests -> Tests -> PlanKit -> Packages -> ios -> repo root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }

    private static var goldenDir: URL { repoRoot.appendingPathComponent("tests/golden") }

    struct Segment: Decodable {
        let src: Int
        let start: Double
        let end: Double
        let speed: Double
        let kind: String
        let peak: Double
        let trans_in: Double
    }

    struct Group: Decodable {
        let name: String
        let segments: [Segment]
    }

    struct Plan: Decodable {
        let sources: [String]
        let groups: [Group]
    }

    private struct Analysis: Decodable {
        let t: [Double]
        let hype: [Double]
        let highlights: [Double]
        let action_start: Double
        let action_end: Double
    }

    private struct Labels: Decodable {
        let duration: Double
    }

    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: goldenDir.appendingPathComponent(name).path)
    }

    static func load<T: Decodable>(_ name: String) throws -> T {
        let data = try Data(contentsOf: goldenDir.appendingPathComponent(name))
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// sources[0] in plan_clips.json/plan_montage.json is the fixture's absolute
    /// path; any golden plan file carries it, use plan_clips.json for it.
    static func fixtureAnalysis() throws -> AnalysisInput {
        let analysis: Analysis = try load("analysis.json")
        let labels: Labels = try load("labels.json")
        let clips: Plan = try load("plan_clips.json")
        return AnalysisInput(
            path: clips.sources[0], duration: labels.duration, t: analysis.t,
            hype: analysis.hype, highlights: analysis.highlights,
            actionStart: analysis.action_start, actionEnd: analysis.action_end
        )
    }
}
