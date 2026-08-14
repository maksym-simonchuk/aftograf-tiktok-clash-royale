import AVFoundation
import Testing
import PlanKit
@testable import RenderKit

/// End-to-end acceptance check for plan §6 M7 (mix polish): renders the
/// golden fixture with a synthesized music bed + voice cue through
/// Composer -> AudioMix -> a ducking/loudness pass -> Encoder (the same
/// Encoder.audioMix wiring CRCut/Pipeline/Pipeline.swift uses), then reads
/// the actual output audio back and checks (a) the music track visibly dips
/// under the voice cue and (b) the rendered mix lands near render.py's
/// loudnorm I=-14 target. Pipeline.swift's `polish` is app-target-private
/// and unreachable from this package, so its DSP steps are mirrored here
/// against RenderKit's public Composer/AudioMix/Encoder/Loudness API.
@Suite struct M7PolishTests {
    private static let sampleRate = 48_000.0
    private static let targetLUFS: Float = -14
    private static let ceilingDB: Float = -1.5
    private static let voiceVolume: Float = 1.7

    @Test(.enabled(if: M7PolishTests.goldenFixturesExist()))
    func renderedMixDucksUnderVoiceAndHitsLoudnessTarget() async throws {
        let repoRoot = Self.repoRoot()
        let fixtureURL = repoRoot.appendingPathComponent("tests/golden/fixture.mp4")
        let planURL = repoRoot.appendingPathComponent("tests/golden/plan_clips.json")
        let golden = try JSONDecoder().decode(GoldenPlan.self, from: Data(contentsOf: planURL))
        let goldenGroup = try #require(golden.groups.first)
        let group = goldenGroup.toPlanKitGroup()
        let target = RenderTarget(width: golden.width, height: golden.height, fps: golden.fps)

        let (composition, videoComposition) = try await Composer.build(
            group: group, sources: [fixtureURL], target: target, mode: "clips"
        )
        // Composer.joinedDuration(segments:) is a separate Double estimate
        // that can drift from the composition's true CMTime end by more than
        // one 1/600s tick -- sizing the audio bed to composition.duration
        // (mirroring Pipeline.swift's render) keeps every audio track from
        // extending past what the video composition's instructions cover
        // (AVAssetReader error -11841).
        let total = composition.duration.seconds

        let musicURL = try Self.makeTone(duration: total, frequency: 220, amplitude: 0.5)
        let voiceStart = min(3.0, total / 2)
        let voiceDuration = min(2.0, total - voiceStart)
        let voiceURL = try Self.makeTone(duration: voiceDuration, frequency: 880, amplitude: 0.8)
        defer {
            try? FileManager.default.removeItem(at: musicURL)
            try? FileManager.default.removeItem(at: voiceURL)
        }

        let mix = try await AudioMix.build(
            composition: composition, total: total, musicURL: musicURL, sfx: [], voice: [(voiceURL, voiceStart)]
        )
        #expect(mix.inputParameters.count == 2) // music (index 0, per AudioMix.build's append order) + voice

        // -- mirror Pipeline.polish's offline PCM estimate --
        let rate = Self.sampleRate
        let sampleCount = Int((total * rate).rounded(.up)) + 1
        var voiceBuf = [Float](repeating: 0, count: sampleCount)
        let voiceStartIdx = Int(voiceStart * rate)
        for i in 0..<Int(voiceDuration * rate) where voiceStartIdx + i < sampleCount {
            let phase: Double = 2 * Double.pi * 880 * Double(i) / rate
            voiceBuf[voiceStartIdx + i] = 0.8 * Float(sin(phase))
        }
        let duck = Loudness.duckingGain(voice: voiceBuf, music: [Float](repeating: 0, count: sampleCount), sampleRate: rate)

        var musicBuf = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let phase: Double = 2 * Double.pi * 220 * Double(i) / rate
            let tone: Float = 0.5 * Float(sin(phase))
            musicBuf[i] = tone * duck[i]
        }
        var estimate = musicBuf
        for i in 0..<min(estimate.count, voiceBuf.count) {
            estimate[i] += voiceBuf[i] * Self.voiceVolume
        }
        // mirrors Pipeline.polish: measure/peak off the RAW estimate, not a
        // soft-limited copy -- AVAudioMix never applies a real limiter, so
        // makeupGain must be derived from the same (unlimited) signal that
        // actually gets scaled, or it systematically overshoots the target.
        let measuredEstimate = Loudness.integratedLUFS(samples: estimate, sampleRate: rate)
        let peak = estimate.reduce(into: Float(0)) { $0 = max($0, abs($1)) }
        let ceiling = powf(10, Self.ceilingDB / 20)
        var makeupGain = powf(10, (Self.targetLUFS - measuredEstimate) / 20)
        if peak > 0 { makeupGain = min(makeupGain, ceiling / peak) }

        // -- apply duck x makeup onto the music track, makeup onto the voice track --
        // Every track's params already carries AudioMix.build's own ramps
        // spanning [0, total] -- AVMutableAudioMixInputParameters throws if a
        // new ramp overlaps an existing one on the SAME params object, so
        // each track gets a fresh params object (same underlying track).
        let oldMusicParams = try #require(mix.inputParameters[0] as? AVMutableAudioMixInputParameters)
        let musicTrack = try #require(composition.track(withTrackID: oldMusicParams.trackID))
        let musicParams = AVMutableAudioMixInputParameters(track: musicTrack)
        let step = 0.05
        var t = 0.0
        while t < total {
            let segEnd = min(t + step, total)
            let g0 = Self.duckSample(duck, t: t) * makeupGain
            let g1 = Self.duckSample(duck, t: segEnd) * makeupGain
            musicParams.setVolumeRamp(
                fromStartVolume: g0, toEndVolume: g1,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: t, preferredTimescale: 600),
                    duration: CMTime(seconds: segEnd - t, preferredTimescale: 600)
                )
            )
            t = segEnd
        }
        mix.inputParameters[0] = musicParams

        let oldVoiceParams = try #require(mix.inputParameters[1] as? AVMutableAudioMixInputParameters)
        let voiceTrack = try #require(composition.track(withTrackID: oldVoiceParams.trackID))
        let voiceParams = AVMutableAudioMixInputParameters(track: voiceTrack)
        var start: Float = 0, end: Float = 0, range = CMTimeRange()
        if oldVoiceParams.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range) {
            voiceParams.setVolume(start * makeupGain, at: .zero)
        }
        mix.inputParameters[1] = voiceParams

        // ducking is visible on the envelope before any rendering happens.
        var preStart: Float = 0, preEnd: Float = 0, preRange = CMTimeRange()
        #expect(musicParams.getVolumeRamp(for: CMTime(seconds: 0.5, preferredTimescale: 600), startVolume: &preStart, endVolume: &preEnd, timeRange: &preRange))
        var duckedStart: Float = 0, duckedEnd: Float = 0, duckedRange = CMTimeRange()
        #expect(musicParams.getVolumeRamp(for: CMTime(seconds: voiceStart + 0.3, preferredTimescale: 600), startVolume: &duckedStart, endVolume: &duckedEnd, timeRange: &duckedRange))
        #expect(duckedStart < preStart * 0.7, "music gain during the voice cue (\(duckedStart)) should be well below the pre-cue gain (\(preStart))")

        // -- render for real through Encoder, then measure the actual output --
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try await Encoder.export(
            composition: composition, videoComposition: videoComposition,
            target: target, group: group, audioMix: mix, to: outputURL
        )

        let outAsset = AVURLAsset(url: outputURL)
        let audioTracks = try await outAsset.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count == 1)

        let rendered = try await Self.decodeMonoFloat(url: outputURL, sampleRate: rate)
        #expect(!rendered.isEmpty)
        let outputLUFS = Loudness.integratedLUFS(samples: rendered, sampleRate: rate)
        #expect(abs(outputLUFS - Self.targetLUFS) <= 1.0, "rendered mix measured \(outputLUFS) LUFS, want within 1 LU of \(Self.targetLUFS)")
    }

    // MARK: - fixtures

    private static func duckSample(_ duck: [Float], t: Double) -> Float {
        guard !duck.isEmpty else { return 1 }
        let idx = min(duck.count - 1, max(0, Int(t * sampleRate)))
        return duck[idx]
    }

    /// A real sine-wave audio file at a given frequency/amplitude -- silence
    /// (as RoughCutTests/AudioMixTests use) can't exercise ducking or LUFS.
    private static func makeTone(duration: Double, frequency: Double, amplitude: Float) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frameCount = AVAudioFrameCount(duration * file.processingFormat.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            channel[i] = amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
        }
        try file.write(from: buffer)
        return url
    }

    private static func decodeMonoFloat(url: URL, sampleRate: Double) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &chunk)
            samples.append(contentsOf: chunk)
        }
        return samples
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
