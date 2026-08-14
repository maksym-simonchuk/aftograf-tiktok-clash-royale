import AVFoundation
import DetectKit
import Foundation
import MediaKit
import Photos
import PlanKit
import RenderKit
import VoiceKit

/// Full on-device pipeline (plan §6 M3-M7): probe -> detect -> plan -> rough-cut
/// render -> music/SFX/voice mix -> ducking/loudness polish -> Photos.
enum PipelineError: Error {
    case photoLibraryDenied
    case noRenderableGroup
    case missingBeatGrids
}

private struct BeatGrids: Decodable {
    let fav: [String]
    let grids: [String: [Double]]
}

enum Pipeline {
    private static let sampleRate = 48_000.0

    // voice.py:103-105 EDGE_VOICES -- primary edge-tts voice per language.
    private static let edgeVoices: [String: String] = [
        "ru": "ru-RU-DmitryNeural",
        "en": "en-US-AndrewMultilingualNeural",
    ]

    // render.py:26,337-338 -- music bed volume + fade in/out, read verbatim
    // (not from AudioMix.swift's private copies) since M7's ducking/loudness
    // ramp has to recompute the music track's whole gain curve from scratch.
    private static let musicVolume: Float = 0.9
    private static let musicFadeIn = 0.25
    private static let musicFadeOut = 0.8
    private static let voiceVolume: Float = 1.7
    private static let targetLUFS: Float = -14
    private static let ceilingDB: Float = -1.5

    /// A4: pause BETWEEN queue items (never mid-render) while the device is
    /// thermally throttled, resuming once it cools to .fair/.nominal. No
    /// render.py analog (desktop encode, not battery/thermal constrained).
    /// Coarse polling is fine here -- this only ever runs in QueueView's
    /// between-item gap, not on a hot path.
    static func waitOutThermalThrottle() async {
        while ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// One imported source video in, one rendered .mov out. Each QueueItem
    /// runs this independently (one source = one plan = one group), matching
    /// the batch model in QueueView. `idx` is the item's position within the
    /// current batch, forwarded to descFor so a multi-video batch rotates
    /// through the description pool instead of repeating a line.
    static func roughCutRender(source: URL, idx: Int = 0) async throws -> (url: URL, caption: String) {
        let meta = try await Probe.probe(url: source)
        let analysis = try await Detect.analyze(meta: meta)
        let input = AnalysisInput(
            path: meta.path, duration: meta.duration, t: analysis.t,
            hype: analysis.hype, highlights: analysis.highlights,
            actionStart: analysis.actionStart, actionEnd: analysis.actionEnd
        )

        var cfg = PlanConfig()
        cfg.voice = edgeVoices[cfg.lang] // cli.py:94-96 _resolve_voice, edge-tts always available on iOS

        // cli.py:103-106: seed + wanted-track-count, before _resolve_music.
        let seed = source.lastPathComponent
        let wanted = cfg.mode == "clips"
            ? Int((Double(analysis.highlights.count) / Double(cfg.clipEvents)).rounded(.up))
            : cfg.variants
        let resolved = try resolveMusicTracks(wanted: wanted, seed: seed)

        let plan = try buildPlan(
            [input], cfg, tracks: resolved.map(\.name), grids: resolved.map(\.beats)
        )
        guard let group = plan.groups.first else {
            throw PipelineError.noRenderableGroup
        }

        let target = RenderTarget(width: plan.width, height: plan.height, fps: plan.fps)
        let outDir = try outputDirectory()
        let outputURL = outDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        try await render(
            group: group, sources: [source], target: target, mode: plan.mode,
            voice: plan.voice, voiceStyle: plan.voiceStyle, lang: cfg.lang, to: outputURL
        )

        // cli.py:57-60 .txt sidecar format, ported verbatim: title, then a
        // rotating desc line, then the hashtags. Seed matches plan.sources
        // exactly ("|".join(plan.sources), full paths -- NOT the basename-only
        // `seed` Plan.swift uses internally for title_for during group build).
        let descSeed = plan.sources.joined(separator: "|")
        let caption = group.title + "\n" + descFor(plan.lang, descSeed, idx: idx) + "\n\n" + group.hashtags.joined(separator: " ") + "\n"
        return (outputURL, caption)
    }

    /// Rough cut + music/SFX/voice mix + M7 polish (ducking, loudness,
    /// limiter), replacing RoughCut.render so the finished AVAudioMix can be
    /// handed to Encoder.export. Ports render.py:76-99 (audio bus wiring) and
    /// render.py:301-369 (`_audio_graph`'s ducking/mix/limiter/loudnorm tail).
    private static func render(
        group: Group, sources: [URL], target: RenderTarget, mode: String,
        voice: String?, voiceStyle: String, lang: String, to outputURL: URL
    ) async throws {
        let (composition, videoComposition) = try await Composer.build(
            group: group, sources: sources, target: target, mode: mode
        )

        // Composer.joinedDuration(segments:) is a separate Double estimate of
        // the same value and can drift from the composition's true CMTime end
        // by more than one 1/600s tick (rounding, not accounted for by that
        // formula) -- sizing the audio bed to composition.duration instead
        // keeps every audio track from ever extending past what the video
        // composition's instructions cover (AVAssetReader error -11841).
        let total = composition.duration.seconds
        let musicURL = group.music.flatMap(bundledMusicURL)
        // No bundled SFX assets yet (ios/CRCut/Resources has no sfx/ folder) --
        // sfxCues(sfxDirectory: nil) returns [] same as render.py's empty-folder case.
        let sfxCues = AudioMix.sfxCues(group: group, sfxDirectory: nil)
        let voiceCues = AudioMix.voiceCues(group: group)
        let voiceFiles = try await synthesize(cues: voiceCues, voice: voice, style: voiceStyle, lang: lang)

        let mix = try await AudioMix.build(
            composition: composition, total: total, musicURL: musicURL,
            sfx: sfxCues, voice: voiceFiles
        )

        if !mix.inputParameters.isEmpty {
            try await polish(mix: mix, composition: composition, musicURL: musicURL, voiceFiles: voiceFiles, total: total)
        }

        try await Encoder.export(
            composition: composition, videoComposition: videoComposition,
            target: target, group: group, audioMix: mix.inputParameters.isEmpty ? nil : mix,
            to: outputURL
        )
    }

    /// M7: sidechain ducking on the music bed + a single loudness-normalizing
    /// gain (measured off-line on a hand-mixed PCM estimate) folded into every
    /// track's volume, then a soft peak ceiling on that same estimate keeps the
    /// makeup gain from re-introducing overs. Not bit-exact with ffmpeg's
    /// sidechaincompress/alimiter/loudnorm chain -- an audible duck and a
    /// loudness target within tolerance, per plan §6 M7's acceptance bar.
    private static func polish(
        mix: AVMutableAudioMix, composition: AVMutableComposition, musicURL: URL?,
        voiceFiles: [(url: URL, start: Double)], total: Double
    ) async throws {
        let sampleCount = Int((total * sampleRate).rounded(.up)) + 1

        var voiceBuf = [Float](repeating: 0, count: sampleCount)
        for cue in voiceFiles {
            let samples = try await decodeMonoFloat(url: cue.url, sampleRate: sampleRate)
            accumulate(&voiceBuf, with: samples, at: cue.start)
        }
        let duck = musicURL != nil && !voiceFiles.isEmpty
            ? Loudness.duckingGain(voice: voiceBuf, music: [Float](repeating: 0, count: sampleCount), sampleRate: sampleRate)
            : [Float](repeating: 1, count: sampleCount)

        var musicBuf = [Float](repeating: 0, count: sampleCount)
        if let musicURL {
            try await loopMusic(&musicBuf, url: musicURL, total: total)
            for i in 0..<sampleCount {
                musicBuf[i] *= musicGain(t: Double(i) / sampleRate, total: total) * duck[i]
            }
        }

        var estimate = musicBuf
        for i in 0..<min(estimate.count, voiceBuf.count) {
            estimate[i] += voiceBuf[i] * voiceVolume
        }
        // Measure/peak off the RAW estimate, not a soft-limited copy of it --
        // AVAudioMix only ever carries linear volume ramps (no limiter runs
        // on the real render), so makeupGain must be derived from the same
        // signal that actually gets scaled, or it systematically overshoots
        // the loudness target (softLimit's peak compression understates the
        // estimate's true LUFS, so the resulting gain is too hot once applied
        // to the real, unlimited mix).
        let measured = Loudness.integratedLUFS(samples: estimate, sampleRate: sampleRate)
        let peak = estimate.reduce(into: Float(0)) { $0 = max($0, abs($1)) }
        let ceiling = powf(10, ceilingDB / 20)
        var makeupGain = powf(10, (targetLUFS - measured) / 20)
        if peak > 0 {
            makeupGain = min(makeupGain, ceiling / peak)
        }

        // AudioMix.build appends the music track first when musicURL != nil
        // (RenderKit/AudioMix.swift:82-99) -- index 0 is always its params.
        // Every track's params already carries AudioMix.build's own ramps
        // spanning [0, total] (fade in/out for music, a flat setVolume point
        // for sfx/voice) -- AVMutableAudioMixInputParameters throws if a new
        // ramp overlaps an existing one on the SAME params object, so each
        // track gets a fresh params object (same underlying track) instead
        // of layering more ramps onto AudioMix.build's.
        for i in 0..<mix.inputParameters.count {
            guard let old = mix.inputParameters[i] as? AVMutableAudioMixInputParameters,
                  let track = composition.track(withTrackID: old.trackID)
            else { continue }
            let fresh = AVMutableAudioMixInputParameters(track: track)
            if i == 0, musicURL != nil {
                applyDuckedMusicRamp(to: fresh, duck: duck, total: total, makeupGain: makeupGain)
            } else {
                var start: Float = 0, end: Float = 0, range = CMTimeRange()
                guard old.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range) else { continue }
                fresh.setVolume(start * makeupGain, at: .zero)
            }
            mix.inputParameters[i] = fresh
        }
    }

    /// Populates a fresh, ramp-free params object (see the call site) with a
    /// fade x duck x makeup-gain envelope, segment by segment.
    private static func applyDuckedMusicRamp(
        to params: AVMutableAudioMixInputParameters, duck: [Float], total: Double, makeupGain: Float
    ) {
        let step = 0.05
        var t = 0.0
        while t < total {
            let segEnd = min(t + step, total)
            let g0 = musicGain(t: t, total: total) * duckSample(duck, t: t) * makeupGain
            let g1 = musicGain(t: segEnd, total: total) * duckSample(duck, t: segEnd) * makeupGain
            params.setVolumeRamp(
                fromStartVolume: g0, toEndVolume: g1,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: t, preferredTimescale: 600),
                    duration: CMTime(seconds: segEnd - t, preferredTimescale: 600)
                )
            )
            t = segEnd
        }
    }

    private static func duckSample(_ duck: [Float], t: Double) -> Float {
        guard !duck.isEmpty else { return 1 }
        let idx = min(duck.count - 1, max(0, Int(t * sampleRate)))
        return duck[idx]
    }

    /// render.py:337-338's `afade=t=in:st=0:d=0.25,afade=t=out:...:d=0.8,volume=0.9`.
    private static func musicGain(t: Double, total: Double) -> Float {
        let fadeIn = min(musicFadeIn, total)
        let fadeOutStart = max(total - musicFadeOut, fadeIn)
        if t < fadeIn {
            return Float(t / fadeIn) * musicVolume
        } else if t < fadeOutStart {
            return musicVolume
        } else {
            let span = max(total - fadeOutStart, 1e-6)
            return musicVolume * Float(max(0, (total - t) / span))
        }
    }

    private static func accumulate(_ buffer: inout [Float], with samples: [Float], at start: Double) {
        let startIdx = Int(max(0, start) * sampleRate)
        for (i, s) in samples.enumerated() {
            let idx = startIdx + i
            guard idx < buffer.count else { break }
            buffer[idx] += s
        }
    }

    /// Mirrors AudioMix.addLoopedTrack's repeat-then-trim, decoded straight to
    /// PCM instead of composition tracks -- this buffer only feeds the M7
    /// loudness estimate, never the actual output audio.
    private static func loopMusic(_ buffer: inout [Float], url: URL, total: Double) async throws {
        let source = try await decodeMonoFloat(url: url, sampleRate: sampleRate)
        guard !source.isEmpty else { return }
        var covered = 0
        while covered < buffer.count {
            let n = min(source.count, buffer.count - covered)
            for i in 0..<n { buffer[covered + i] = source[i] }
            covered += n
        }
    }

    /// Decodes any AVFoundation-readable audio file to mono Float32 PCM at
    /// `sampleRate`, letting the reader's own converter handle resampling --
    /// used only for the off-line M7 ducking/loudness estimate, never for the
    /// exported audio itself (that stays on AudioMix's composition tracks).
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

    /// Synthesizes each voice cue via VoiceKit (edge-tts, local AVSpeech
    /// fallback on network failure) and writes it to a temp WAV file --
    /// AudioMix.build and the M7 ducking pass both need a file URL.
    private static func synthesize(
        cues: [AudioMix.VoiceCue], voice: String?, style: String, lang: String
    ) async throws -> [(url: URL, start: Double)] {
        guard let voice else { return [] }
        let speaker = Speaker(transport: URLSessionEdgeTTSTransport(), cache: VoiceCache())
        let voiceStyle = VoiceStyles.named(style)

        var files: [(url: URL, start: Double)] = []
        for cue in cues {
            let data = await speaker.speak(text: cue.text, voice: voice, language: lang, style: voiceStyle)
            guard !data.isEmpty else { continue }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
            try data.write(to: url)
            files.append((url: url, start: cue.start))
        }
        return files
    }

    private static func resolveMusicTracks(wanted: Int, seed: String) throws -> [(name: String, beats: [Double])] {
        // xcodegen 2.46.0 flattens CRCut/Resources/* to the bundle root (no
        // subdirectory preserved) -- no `subdirectory:` argument here.
        guard let url = Bundle.main.url(forResource: "beatgrids", withExtension: "json") else {
            throw PipelineError.missingBeatGrids
        }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(BeatGrids.self, from: data)
        return resolveMusic(fav: decoded.fav, grids: decoded.grids, wanted: wanted, seed: seed)
    }

    private static func bundledMusicURL(name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: nil)
    }

    /// Saves a rendered clip into the user's Photos library. Requests the
    /// iOS 14+ add-only authorization (`.addOnly`) — CRCut never reads or
    /// enumerates the existing library.
    static func saveToPhotos(_ videoURL: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PipelineError.photoLibraryDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
        }
    }

    private static func outputDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let outDir = documents.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        return outDir
    }

    /// Documents/inbox/ — where ImportView copies PHPicker selections before
    /// the pipeline touches them.
    static func inboxDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let inbox = documents.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }
}
