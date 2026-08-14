import AVFoundation
import Testing
import PlanKit
@testable import RenderKit

/// No golden fixture needed: cue timing is pure math over a Group, and the
/// render-level check only needs *some* real audio file (tests/golden/fixture.mp4
/// has no audio track -- see RoughCutTests.swift), so we synthesize one.
@Suite struct AudioMixTests {
    private func segment(kind: String, start: Double, end: Double, transIn: Double = 0,
                          caption: String = "", narrate: Bool = false, adlib: String = "") -> Segment {
        Segment(src: 0, start: start, end: end, speed: 1.0, kind: kind, transIn: transIn,
                caption: caption, narrate: narrate, adlib: adlib)
    }

    // MARK: - sfxCues

    @Test func sfxCuesFiresOnHitsAndHooksOnly() throws {
        let group = Group(name: "g", title: "", hashtags: [], segments: [
            segment(kind: "hit", start: 0, end: 2),
            segment(kind: "b-roll", start: 2, end: 4),
            segment(kind: "hook", start: 4, end: 6),
        ])
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.touch(dir.appendingPathComponent("a.wav"))
        try Self.touch(dir.appendingPathComponent("b.wav"))

        let cues = AudioMix.sfxCues(group: group, sfxDirectory: dir)
        #expect(cues.count == 2)
        #expect(cues[0].start == 0)
        #expect(cues[1].start == 4)
    }

    @Test func sfxCuesCyclesThroughSortedFiles() throws {
        let group = Group(name: "g", title: "", hashtags: [], segments: [
            segment(kind: "hit", start: 0, end: 1),
            segment(kind: "hit", start: 1, end: 2),
            segment(kind: "hit", start: 2, end: 3),
        ])
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.touch(dir.appendingPathComponent("a.wav"))
        try Self.touch(dir.appendingPathComponent("b.wav"))

        let cues = AudioMix.sfxCues(group: group, sfxDirectory: dir)
        #expect(cues.map { $0.url.lastPathComponent } == ["a.wav", "b.wav", "a.wav"])
    }

    @Test func sfxCuesEmptyWhenDirectoryMissingOrEmpty() throws {
        let group = Group(name: "g", title: "", hashtags: [], segments: [segment(kind: "hit", start: 0, end: 1)])
        #expect(AudioMix.sfxCues(group: group, sfxDirectory: nil).isEmpty)

        let empty = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(AudioMix.sfxCues(group: group, sfxDirectory: empty).isEmpty)
    }

    // MARK: - voiceCues

    @Test func voiceCuesCaptionOnlyWhenNarrated() {
        let group = Group(name: "g", title: "", hashtags: [], segments: [
            segment(kind: "b-roll", start: 0, end: 2, caption: "drawn only", narrate: false),
            segment(kind: "hit", start: 2, end: 4, caption: "spoken", narrate: true),
        ])
        let cues = AudioMix.voiceCues(group: group)
        #expect(cues.count == 1)
        #expect(cues[0] == AudioMix.VoiceCue(kind: .caption, text: "spoken", start: 2))
    }

    @Test func voiceCuesAdlibOffsetQuarterSecondIntoSegment() {
        let group = Group(name: "g", title: "", hashtags: [], segments: [
            segment(kind: "hit", start: 0, end: 2, adlib: "Oh boy!"),
        ])
        let cues = AudioMix.voiceCues(group: group)
        #expect(cues == [AudioMix.VoiceCue(kind: .adlib, text: "Oh boy!", start: 0.25)])
    }

    @Test func voiceCuesRespectTimelineOffsetsAcrossSegments() {
        let group = Group(name: "g", title: "", hashtags: [], segments: [
            segment(kind: "b-roll", start: 0, end: 3, caption: "one", narrate: true),
            segment(kind: "hit", start: 3, end: 5, transIn: 0, adlib: "two"),
        ])
        let cues = AudioMix.voiceCues(group: group)
        #expect(cues == [
            AudioMix.VoiceCue(kind: .caption, text: "one", start: 0),
            AudioMix.VoiceCue(kind: .adlib, text: "two", start: 3.25),
        ])
    }

    // MARK: - build (real AVFoundation composition)

    @Test func buildLoopsAndTrimsMusicToTotalDuration() async throws {
        let musicURL = try Self.makeTone(duration: 1.0)
        defer { try? FileManager.default.removeItem(at: musicURL) }

        let composition = AVMutableComposition()
        let mix = try await AudioMix.build(composition: composition, total: 3.3, musicURL: musicURL)

        let audioTracks = composition.tracks(withMediaType: .audio)
        #expect(audioTracks.count == 1)
        let duration = audioTracks[0].timeRange.duration.seconds
        #expect(abs(duration - 3.3) < 0.05)
        #expect(mix.inputParameters.count == 1)
    }

    @Test func buildAddsOneTrackPerSfxAndVoiceCue() async throws {
        let toneURL = try Self.makeTone(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: toneURL) }

        let composition = AVMutableComposition()
        let mix = try await AudioMix.build(
            composition: composition, total: 2.0, musicURL: nil,
            sfx: [(toneURL, 0.0), (toneURL, 1.0)],
            voice: [(toneURL, 0.5)]
        )

        #expect(composition.tracks(withMediaType: .audio).count == 3)
        #expect(mix.inputParameters.count == 3)
    }

    @Test func buildWithNoLayersReturnsEmptyMix() async throws {
        let composition = AVMutableComposition()
        let mix = try await AudioMix.build(composition: composition, total: 2.0, musicURL: nil)
        #expect(composition.tracks(withMediaType: .audio).isEmpty)
        #expect(mix.inputParameters.isEmpty)
    }

    // MARK: - fixtures

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func touch(_ url: URL) throws {
        try Data().write(to: url)
    }

    /// A short real audio file (silence is fine -- these tests check timing, not content).
    private static func makeTone(duration: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        // AVAudioFile's *processing* format (what write(from:) expects) isn't
        // necessarily `settings` verbatim -- it defaults to float32, not the
        // int16 file format above. Build the buffer from the file itself.
        let frameCount = AVAudioFrameCount(duration * file.processingFormat.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        try file.write(from: buffer)
        return url
    }
}
