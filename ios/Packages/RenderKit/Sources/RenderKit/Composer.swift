import AVFoundation
import PlanKit

/// Cross-fade-aware composition + speed ramps + the custom compositor wiring
/// for punch/flash/pillarbox/xfade (plan §6 M4). Ports render.py:119-224
/// minus the audio graph (M5/M7, task #8/#9) and the meme branch of _stickers
/// (needs bundled PNGs that don't exist yet -- M5/M8).
public enum Composer {
    /// Builds a two-track AVMutableComposition (adjacent segments alternate
    /// tracks so a transition's overlap window can pull both frames at once)
    /// and a matching AVMutableVideoComposition whose instructions drive
    /// CRCutVideoCompositor -- geometry, punch, flash and xfade all happen
    /// per-frame in CIImage there, not via AVVideoCompositionLayerInstruction.
    public static func build(
        group: Group, sources: [URL], target: RenderTarget, mode: String
    ) async throws -> (composition: AVMutableComposition, videoComposition: AVMutableVideoComposition) {
        guard !group.segments.isEmpty else {
            throw RenderError.emptyGroup(group.name)
        }

        // Two tracks, alternating per segment, so an overlap window's "from"
        // and "to" frames always live on different tracks and can be pulled
        // simultaneously. Known limitation: this assumes no segment's own
        // leading+trailing overlaps ever reach back into the segment two
        // slots earlier on the same track -- true for realistic plans (trans_in
        // is small relative to segment length) but not proven for pathological
        // ones; insertTimeRange throws a catchable error rather than
        // corrupting output if it ever happens.
        let composition = AVMutableComposition()
        guard let trackA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1),
            let trackB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 2)
        else {
            throw RenderError.writerFailed("could not add composition video tracks")
        }

        let overlaps = overlapSeconds(segments: group.segments)
        let targetAspect = Double(target.width) / Double(target.height)

        // Pass 1: insert + per-track speed-scale each segment, collecting its
        // absolute (joined-timeline) range and render parameters.
        var renders: [SegmentRender] = []
        var ranges: [CMTimeRange] = []
        var cursorSeconds = 0.0

        for (i, seg) in group.segments.enumerated() {
            guard seg.src >= 0, seg.src < sources.count else {
                throw RenderError.sourceIndexOutOfRange(seg.src)
            }
            let url = sources[seg.src]
            let asset = AVURLAsset(url: url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let srcVideoTrack = videoTracks.first else {
                throw RenderError.noVideoTrack(url.lastPathComponent)
            }

            let start = CMTime(seconds: seg.start, preferredTimescale: 600)
            let end = CMTime(seconds: seg.end, preferredTimescale: 600)
            let sourceRange = CMTimeRange(start: start, end: end)

            let insertStartSeconds = max(0, cursorSeconds - overlaps[i])
            let insertStart = CMTime(seconds: insertStartSeconds, preferredTimescale: 600)
            let track = i % 2 == 0 ? trackA : trackB
            try track.insertTimeRange(sourceRange, of: srcVideoTrack, at: insertStart)

            let outDuration = CMTime(seconds: seg.outDuration, preferredTimescale: 600)
            // plan.py:139 setpts=(PTS-STARTPTS)/speed -- the PER-TRACK scale,
            // not AVMutableComposition's whole-composition one, which would
            // also re-scale the other track's overlapping segment sharing
            // this same absolute time range.
            let insertedRange = CMTimeRange(start: insertStart, duration: sourceRange.duration)
            track.scaleTimeRange(insertedRange, toDuration: outDuration)

            let scaledRange = CMTimeRange(start: insertStart, duration: outDuration)
            let naturalSize = try await srcVideoTrack.load(.naturalSize)
            let preferredTransform = try await srcVideoTrack.load(.preferredTransform)
            let uprightRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
            let uprightAspect = Double(abs(uprightRect.width) / abs(uprightRect.height))
            let pillarbox = abs(uprightAspect - targetAspect) > aspectTolerance

            renders.append(SegmentRender(
                trackID: track.trackID, localStart: insertStart,
                naturalSize: naturalSize, preferredTransform: preferredTransform,
                pillarbox: pillarbox, kind: seg.kind, flashAt: Flash.at(for: seg, mode: mode)
            ))
            ranges.append(scaledRange)

            cursorSeconds = insertStartSeconds + seg.outDuration
        }

        // Pass 2: a .transition instruction per leading overlap window, a
        // .single instruction for each segment's solo remainder (its own
        // range shrunk by both its leading and trailing overlaps). soloEnd is
        // tied to the NEXT segment's own range.start (rather than
        // independently recomputed as range.end - trailing) so adjacent
        // instructions share the exact same CMTime at their shared boundary
        // -- two separate CMTime(seconds:) roundings of what's conceptually
        // the same instant can differ by up to 1/600s, which AVFoundation
        // rejects as a gap/overlap between instructions (AVAssetReader
        // error -11841, caught by roughCutDurationMatchesGoldenPlan).
        var instructions: [CRCutCompositionInstruction] = []
        for i in 0..<group.segments.count {
            let leading = overlaps[i]
            let range = ranges[i]

            if leading > 0 {
                let window = CMTimeRange(
                    start: range.start, duration: CMTime(seconds: leading, preferredTimescale: 600)
                )
                instructions.append(CRCutCompositionInstruction(
                    timeRange: window,
                    kind: .transition(
                        from: renders[i - 1], to: renders[i],
                        kind: group.segments[i].transKind, window: window
                    )
                ))
            }

            let soloStart = range.start + CMTime(seconds: leading, preferredTimescale: 600)
            let soloEnd = i + 1 < ranges.count ? ranges[i + 1].start : range.end
            if soloEnd > soloStart {
                instructions.append(CRCutCompositionInstruction(
                    timeRange: CMTimeRange(start: soloStart, end: soloEnd),
                    kind: .single(renders[i])
                ))
            }
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: target.width, height: target.height)
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(target.fps))
        videoComposition.customVideoCompositorClass = CRCutVideoCompositor.self
        videoComposition.instructions = instructions

        return (composition, videoComposition)
    }

    static let aspectTolerance = 0.01 // ASPECT_TOLERANCE, render.py:18

    /// Applied cross-fade seconds before each segment (overlaps[0] == 0) --
    /// render.py:204-224's `_join` recurrence: a fade eats `dur` off the
    /// running joined-duration total `acc`, re-clamped against both `acc/3`
    /// and this segment's own duration, hard-cutting below the 0.12s floor.
    static func overlapSeconds(segments: [Segment]) -> [Double] {
        guard !segments.isEmpty else { return [] }
        var overlaps = [Double](repeating: 0, count: segments.count)
        var acc = segments[0].outDuration
        for i in 1..<segments.count {
            let seg = segments[i]
            let dur = min(seg.transIn, acc / 3.0, seg.outDuration / 3.0)
            if dur >= 0.12 {
                overlaps[i] = dur
                acc = acc - dur + seg.outDuration
            } else {
                acc += seg.outDuration
            }
        }
        return overlaps
    }

    /// The group's actual rendered duration once cross-fade overlaps are
    /// applied -- render.py's `group.out_duration` as `_join` really produces
    /// it (PlanKit's own `Group.outDuration` uses raw, unclamped `transIn`;
    /// this re-derives the clamped total the real xfade graph yields).
    public static func joinedDuration(segments: [Segment]) -> Double {
        guard !segments.isEmpty else { return 0 }
        let total = segments.reduce(0.0) { $0 + $1.outDuration }
        let overlapped = overlapSeconds(segments: segments).reduce(0.0, +)
        return total - overlapped
    }
}
