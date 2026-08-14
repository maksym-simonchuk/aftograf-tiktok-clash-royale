import Foundation

/// Locates `tests/golden/*` in the repo root, independent of `swift test`'s
/// working directory. `#filePath` for this source file is
/// `.../ios/Packages/DetectKit/Tests/MediaKitTests/GoldenFixture.swift`;
/// walking up 6 path components lands on the repo root (Tests/MediaKitTests ->
/// Tests -> DetectKit -> Packages -> ios -> repo root).
enum GoldenFixture {
    struct Paths {
        let video: URL
        let analysis: URL
        let labels: URL
    }

    struct Labels: Decodable {
        let hits: [Double]
        let live: [Double]
        let duration: Double
        let width: Int
        let height: Int
    }

    static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }

    /// Returns nil (caller should `XCTSkip`) if the golden fixtures haven't
    /// landed yet (task #1, produced by `scripts/export_golden.py`).
    static func locate() -> Paths? {
        let golden = repoRoot().appendingPathComponent("tests/golden")
        let paths = Paths(
            video: golden.appendingPathComponent("fixture.mp4"),
            analysis: golden.appendingPathComponent("analysis.json"),
            labels: golden.appendingPathComponent("labels.json")
        )
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.video.path),
              fm.fileExists(atPath: paths.analysis.path),
              fm.fileExists(atPath: paths.labels.path)
        else { return nil }
        return paths
    }

    static func loadLabels(_ url: URL) throws -> Labels {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Labels.self, from: data)
    }
}
