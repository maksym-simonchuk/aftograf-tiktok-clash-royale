import AVFoundation
import PlanKit

/// Music+SFX+voice mixing (plan §6 M5). Ports render.py:264-345,372-379 minus
/// ducking/loudnorm/limiter, which need the actual mix in place first and land
/// in M7 (task #9). ffmpeg's filtergraph becomes composition tracks + a flat
/// AVMutableAudioMix: one track per layer (music, each SFX cue, each voice
/// cue), volumes/fades as ramps, no sidechaincompress.
///
/// Voice cues are text+timing only here -- RenderKit doesn't depend on VoiceKit
/// (Package.swift is out of this task's zone), so synthesizing `VoiceCue.text`
/// to a file and mixing it in via `build(voice:)` is the caller's job.
public enum AudioMix {
    public enum VoiceCueKind: Sendable, Equatable {
        case caption
        case adlib
    }

    /// A caption/adlib waiting to be spoken. `start` is already offset for
    /// adlibs (render.py:298: a beat into the shot it reacts to).
    public struct VoiceCue: Sendable, Equatable {
        public var kind: VoiceCueKind
        public var text: String
        public var start: Double
    }

    private static let sfxSuffixes: Set<String> = ["wav", "mp3", "m4a", "aac", "ogg"]
    private static let musicVolume: Float = 0.9
    private static let musicFadeIn = 0.25
    private static let musicFadeOut = 0.8
    private static let sfxVolume: Float = 1.1
    private static let sfxTrim = 1.6
    private static let voiceVolume: Float = 1.7
    private static let adlibOffset = 0.25

    /// One per hit/hook moment, cycling whatever's in `sfxDirectory` in name
    /// order (render.py:264-278). An empty/missing folder means no SFX layer.
    public static func sfxCues(group: Group, sfxDirectory: URL?) -> [(url: URL, start: Double)] {
        guard let sfxDirectory,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: sfxDirectory, includingPropertiesForKeys: nil
              )
        else { return [] }
        let files = entries
            .filter { sfxSuffixes.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { return [] }

        let hits = group.timeline().filter { $0.segment.kind == "hit" || $0.segment.kind == "hook" }
        return hits.enumerated().map { i, entry in (files[i % files.count], max(entry.start, 0.0)) }
    }

    /// Narrated captions plus the adlibs between them (render.py:281-298).
    public static func voiceCues(group: Group) -> [VoiceCue] {
        var cues: [VoiceCue] = []
        for (seg, start) in group.timeline() {
            if seg.narrate, !seg.caption.isEmpty {
                cues.append(VoiceCue(kind: .caption, text: seg.caption, start: max(start, 0.0)))
            }
            if !seg.adlib.isEmpty {
                cues.append(VoiceCue(kind: .adlib, text: seg.adlib, start: max(start + adlibOffset, 0.0)))
            }
        }
        return cues
    }

    /// Adds music (looped+trimmed to `total`, fade in/out, volume 0.9), SFX
    /// cues (1.6s trim, volume 1.1) and voice cues (volume 1.7) onto
    /// `composition` as new audio tracks, and returns a flat AVMutableAudioMix
    /// -- no ducking, no loudnorm/limiter (M7). `sfx`/`voice` are resolved
    /// (file URL, absolute timeline offset) pairs, e.g. from `sfxCues(_:_:)`
    /// and a VoiceKit synthesis of `voiceCues(_:)`.
    public static func build(
        composition: AVMutableComposition,
        total: Double,
        musicURL: URL?,
        sfx: [(url: URL, start: Double)] = [],
        voice: [(url: URL, start: Double)] = []
    ) async throws -> AVMutableAudioMix {
        var params: [AVMutableAudioMixInputParameters] = []

        if let musicURL {
            let track = try await addLoopedTrack(to: composition, url: musicURL, total: total)
            let p = AVMutableAudioMixInputParameters(track: track)
            addFade(to: p, total: total)
            params.append(p)
        }
        for cue in sfx {
            let track = try await addCueTrack(to: composition, url: cue.url, start: cue.start, trim: sfxTrim)
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(sfxVolume, at: .zero)
            params.append(p)
        }
        for cue in voice {
            let track = try await addCueTrack(to: composition, url: cue.url, start: cue.start, trim: nil)
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(voiceVolume, at: .zero)
            params.append(p)
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return mix
    }

    /// Fade in 0->musicVolume over musicFadeIn, hold, fade out to 0 over the
    /// last musicFadeOut seconds (render.py:337-338).
    private static func addFade(to params: AVMutableAudioMixInputParameters, total: Double) {
        let fadeIn = min(musicFadeIn, total)
        let fadeOutStart = max(total - musicFadeOut, fadeIn)
        ramp(params, from: 0, to: musicVolume, start: 0, duration: fadeIn)
        ramp(params, from: musicVolume, to: musicVolume, start: fadeIn, duration: fadeOutStart - fadeIn)
        ramp(params, from: musicVolume, to: 0, start: fadeOutStart, duration: max(total - fadeOutStart, 0))
    }

    private static func ramp(
        _ params: AVMutableAudioMixInputParameters, from: Float, to: Float, start: Double, duration: Double
    ) {
        guard duration > 0 else { return }
        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        params.setVolumeRamp(fromStartVolume: from, toEndVolume: to, timeRange: range)
    }

    /// Repeats `url`'s audio (ffmpeg's `-stream_loop -1`) until `total` is
    /// covered, then the last repeat is trimmed to fit exactly.
    private static func addLoopedTrack(
        to composition: AVMutableComposition, url: URL, total: Double
    ) async throws -> AVMutableCompositionTrack {
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RenderError.writerFailed("could not add music track")
        }
        // Keep the asset alive: a temporary `AVURLAsset(url:).loadTracks(...)` chain
        // can deallocate before insertTimeRange(_:of:at:) reads from srcTrack.
        let srcAsset = AVURLAsset(url: url)
        guard let srcTrack = try await srcAsset.loadTracks(withMediaType: .audio).first else {
            return track
        }
        let srcDuration = try await srcTrack.load(.timeRange).duration.seconds
        guard srcDuration > 0 else { return track }

        var covered = 0.0
        while covered + 1e-3 < total {
            let sliceDuration = min(srcDuration, total - covered)
            let sourceRange = CMTimeRange(
                start: .zero, duration: CMTime(seconds: sliceDuration, preferredTimescale: 600)
            )
            try track.insertTimeRange(
                sourceRange, of: srcTrack, at: CMTime(seconds: covered, preferredTimescale: 600)
            )
            covered += sliceDuration
        }
        return track
    }

    /// Places `trim ?? full` seconds of `url`'s audio at absolute time `start`.
    private static func addCueTrack(
        to composition: AVMutableComposition, url: URL, start: Double, trim: Double?
    ) async throws -> AVMutableCompositionTrack {
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RenderError.writerFailed("could not add cue track")
        }
        // See addLoopedTrack: keep the asset alive past loadTracks.
        let srcAsset = AVURLAsset(url: url)
        guard let srcTrack = try await srcAsset.loadTracks(withMediaType: .audio).first else {
            return track
        }
        let srcDuration = try await srcTrack.load(.timeRange).duration.seconds
        let sliceDuration = trim.map { min($0, srcDuration) } ?? srcDuration
        guard sliceDuration > 0 else { return track }

        let sourceRange = CMTimeRange(start: .zero, duration: CMTime(seconds: sliceDuration, preferredTimescale: 600))
        try track.insertTimeRange(
            sourceRange, of: srcTrack, at: CMTime(seconds: max(0, start), preferredTimescale: 600)
        )
        return track
    }
}
