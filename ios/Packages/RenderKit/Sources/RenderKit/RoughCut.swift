import AVFoundation
import PlanKit

/// Public entry point for M3: hard-cut composition + speed ramps, encoded to
/// an H.264/AAC .mov. This is what the app's Pipeline.swift calls once
/// DetectKit+PlanKit are wired in (plan §6 M3 milestone).
public enum RoughCut {
    public static func render(
        group: Group, sources: [URL], target: RenderTarget, mode: String, to outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let (composition, videoComposition) = try await Composer.build(
            group: group, sources: sources, target: target, mode: mode
        )
        try await Encoder.export(
            composition: composition, videoComposition: videoComposition,
            target: target, group: group, to: outputURL, progress: progress
        )
    }
}
