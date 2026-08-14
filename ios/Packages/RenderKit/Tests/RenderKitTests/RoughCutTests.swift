import AVFoundation
import Testing
import PlanKit
@testable import RenderKit

/// Progress callbacks fire from the encoder's own serial pump queue, not the
/// calling test's task -- a lock-protected accumulator (Swift 6 strict
/// concurrency doesn't let a plain `var` cross that boundary) rather than the
/// `nonisolated(unsafe)` rebind Encoder.swift uses for its own AVFoundation
/// objects, since this needs synchronized append, not just a trusted hop.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    func values() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Lets a test suspend until the render's progress callback has fired at
/// least once, so cancellation is triggered deterministically mid-render
/// instead of racing a sleep against however fast this machine encodes.
/// Same NSLock-guarded idiom as `ProgressLog` above, extended to also park a
/// continuation.
private final class FirstProgressSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fire() {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        continuation?.resume()
        continuation = nil
    }

    /// NSLock's lock()/unlock() are unavailable directly inside `async`
    /// function bodies (Swift pushes toward scoped locking there) -- this
    /// non-async helper does the locked check-and-store so `wait()` itself
    /// never calls lock()/unlock() textually.
    private func storeContinuationIfNotFired(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        self.continuation = continuation
        return true
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            if !storeContinuationIfNotFired(continuation) {
                continuation.resume()
            }
        }
    }
}

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

        let progressLog = ProgressLog()
        try await RoughCut.render(
            group: group, sources: [fixtureURL], target: target, mode: "clips", to: outputURL,
            progress: { progressLog.record($0) }
        )

        let progressValues = progressLog.values()
        #expect(!progressValues.isEmpty)
        #expect(progressValues == progressValues.sorted(), "progress should be non-decreasing")
        #expect(progressValues.last == 1.0)

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

    @Test(.enabled(if: RoughCutTests.goldenFixturesExist()))
    func cancellingRenderThrowsAndRemovesPartialOutput() async throws {
        let repoRoot = Self.repoRoot()
        let fixtureURL = repoRoot.appendingPathComponent("tests/golden/fixture.mp4")
        let planURL = repoRoot.appendingPathComponent("tests/golden/plan_clips.json")

        let golden = try JSONDecoder().decode(GoldenPlan.self, from: Data(contentsOf: planURL))
        let goldenGroup = try #require(golden.groups.first)
        let group = goldenGroup.toPlanKitGroup()

        let target = RenderTarget(width: golden.width, height: golden.height, fps: golden.fps)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let firstProgress = FirstProgressSignal()
        let task = Task {
            try await RoughCut.render(
                group: group, sources: [fixtureURL], target: target, mode: "clips", to: outputURL,
                progress: { _ in firstProgress.fire() }
            )
        }

        await firstProgress.wait()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: outputURL.path), "cancelled render should not leave a partial output file")
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
