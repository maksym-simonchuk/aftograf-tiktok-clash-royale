import Testing
@testable import PlanKit

// Reference offsets computed in Python:
// int(hashlib.sha1(seed.encode()).hexdigest()[:8], 16) % n
@Suite struct MusicResolveTests {
    private let grids5: [String: [Double]] = [
        "a.mp3": [0], "b.mp3": [0], "c.mp3": [0], "d.mp3": [0], "e.mp3": [0],
    ]

    @Test func favsComeFirst() {
        let picked = resolveMusic(fav: ["fav.mp3"], grids: ["fav.mp3": [1, 2], "a.mp3": [0]], wanted: 1, seed: "x")
        #expect(picked.map { $0.name } == ["fav.mp3"])
        #expect(picked[0].beats == [1, 2])
    }

    @Test func rotationOffsetMatchesPythonReference() {
        // pool = [a,b,c,d,e] (5), off("a.mp4#0", 5) = 0 -> picks a.mp3
        let picked = resolveMusic(fav: [], grids: grids5, wanted: 1, seed: "a.mp4#0")
        #expect(picked.map { $0.name } == ["a.mp3"])

        // off("a.mp4#1", 5) = 1 -> picks b.mp3
        let picked2 = resolveMusic(fav: [], grids: grids5, wanted: 1, seed: "a.mp4#1")
        #expect(picked2.map { $0.name } == ["b.mp3"])

        // off("clip-seed-42", 5) = 3 -> picks d.mp3
        let picked3 = resolveMusic(fav: [], grids: grids5, wanted: 1, seed: "clip-seed-42")
        #expect(picked3.map { $0.name } == ["d.mp3"])
    }

    @Test func rotationWrapsAroundThePool() {
        // pool of 3 (a,b,c), off("s1", 3) = 2 -> indices 2,0,1 (wraps past the end)
        let picked = resolveMusic(
            fav: [], grids: ["a.mp3": [0], "b.mp3": [0], "c.mp3": [0]], wanted: 3, seed: "s1"
        )
        #expect(picked.map { $0.name } == ["c.mp3", "a.mp3", "b.mp3"])
    }

    @Test func favFillsThenPoolRotationTopsUpRemainder() {
        // pool = grids keys minus beds minus favs -- fav.mp3 is excluded, so
        // pool is still [a,b,c,d,e] (5), off("a.mp4#0", 5) = 0 -> a.mp3.
        let picked = resolveMusic(fav: ["fav.mp3"], grids: grids5.merging(["fav.mp3": [9]]) { a, _ in a }, wanted: 2, seed: "a.mp4#0")
        #expect(picked.map { $0.name } == ["fav.mp3", "a.mp3"])
    }

    @Test func favDoesNotDuplicateViaRotation() {
        // pool excludes "x" (it's a fav), so pool = [a,b,c] (3). wanted =
        // pool.count + 1 = 4 forces remaining=3 to consume the whole pool --
        // "x" must appear exactly once, not again via rotation.
        let grids: [String: [Double]] = ["x": [0], "a.mp3": [0], "b.mp3": [0], "c.mp3": [0]]
        let picked = resolveMusic(fav: ["x"], grids: grids, wanted: 4, seed: "dup-seed")
        #expect(picked.filter { $0.name == "x" }.count == 1)
        #expect(Set(picked.map { $0.name }) == ["x", "a.mp3", "b.mp3", "c.mp3"])
    }

    @Test func fallsBackToBedsWhenNoFavsOrPool() {
        let grids: [String: [Double]] = [
            "bed_dark_140bpm.wav": [0, 1], "bed_drive_140bpm.wav": [0, 1], "bed_rush_140bpm.wav": [0, 1],
        ]
        let picked = resolveMusic(fav: [], grids: grids, wanted: 2, seed: "s")
        #expect(picked.map { $0.name } == ["bed_dark_140bpm.wav", "bed_drive_140bpm.wav"])
    }

    @Test func wantedZeroTreatedAsOne() {
        let picked = resolveMusic(fav: ["fav.mp3"], grids: ["fav.mp3": [0]], wanted: 0, seed: "s")
        #expect(picked.count == 1)
    }

    @Test func emptyEverythingReturnsEmpty() {
        #expect(resolveMusic(fav: [], grids: [:], wanted: 3, seed: "s").isEmpty)
    }
}
