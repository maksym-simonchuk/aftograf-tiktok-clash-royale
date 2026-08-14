import AVFoundation
import Testing
import PlanKit
@testable import RenderKit

/// Reads tests/golden/{fixture.mp4,plan_clips.json} from the repo root
/// (plan §5 -- no fixture duplication) and renders a real rough cut on this
/// Mac: AVAssetReader/Writer both work outside Xcode, only the iOS app
/// build needs Xcode.
@Suite struct RoughCutTests {
    @Test(.enabled(if: RoughCutTests.goldenFixturesExist()))
    func roughCutDurationMatchesGoldenPlan() async throws {
        let repoRoot = Self.repoRoot()
        let fixtureURL = repoRoot.appendingPathComponent("tests/golden/fixture.mp4")
        let planURL = repoRoot.appendingPathComponent("tests/golden/plan_clips.json")

        let golden = try JSONDecoder().decode(GoldenPlan.self, from: Data(contentsOf: planURL))
        let goldenGroup = try #require(golden.groups.first)
        let group = goldenGroup.toPlanKitGroup()
        let expectedDuration = Composer.joinedDuration(segments: group.segments)

        let target = RenderTarget(width: golden.width, height: golden.height, fps: golden.fps)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try await RoughCut.render(group: group, sources: [fixtureURL], target: target, mode: "clips", to: outputURL)

        let outAsset = AVURLAsset(url: outputURL)
        let duration = try await outAsset.load(.duration).seconds
        #expect(abs(duration - expectedDuration) <= 0.1, "output duration should match sum of segment out_duration")

        let videoTracks = try await outAsset.loadTracks(withMediaType: .video)
        #expect(videoTracks.count == 1)
        if let videoTrack = videoTracks.first {
            let naturalSize = try await videoTrack.load(.naturalSize)
            #expect(Int(naturalSize.width) == target.width)
            #expect(Int(naturalSize.height) == target.height)
            let nominalFPS = try await videoTrack.load(.nominalFrameRate)
            #expect(abs(Double(nominalFPS) - Double(target.fps)) <= 2.0)
        }

        // the synthetic fixture has no audio stream, so the rough cut is video-only
        let audioTracks = try await outAsset.loadTracks(withMediaType: .audio)
        #expect(audioTracks.isEmpty)
    }

    @Test func emptyGroupThrows() async throws {
        let group = Group(name: "empty", title: "", hashtags: [], segments: [])
        let target = RenderTarget(width: 1080, height: 1920, fps: 30)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")

        await #expect(throws: RenderError.self) {
            try await RoughCut.render(group: group, sources: [], target: target, mode: "clips", to: outputURL)
        }
    }

    private static func repoRoot() -> URL {
        // Tests/RenderKitTests/<file>.swift -> Tests -> RenderKit -> Packages -> ios -> repo root
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }

    private static func goldenFixturesExist() -> Bool {
        let root = repoRoot()
        let fm = FileManager.default
        return fm.fileExists(atPath: root.appendingPathComponent("tests/golden/fixture.mp4").path)
            && fm.fileExists(atPath: root.appendingPathComponent("tests/golden/plan_clips.json").path)
    }
}
