import Foundation
import MediaKit

/// Port of `detect.py:64-83` `analyze` — the detection entry point.
public enum Detect {
    public static func analyze(meta: Meta, cfg: DetectConfig = DetectConfig()) async throws -> Analysis {
        let url = URL(fileURLWithPath: meta.path)
        let frames = try await FrameSampler.sampleGray(url: url, fps: cfg.sampleFPS, width: cfg.sampleWidth)
        let t = (0..<frames.count).map { Double($0) / cfg.sampleFPS }

        let (motion, flash, shake) = Signals.computeSignals(frames: frames, cfg: cfg)
        let (start, end) = LiveGate.liveWindow(frames: frames, t: t, cfg: cfg)
        let live = t.map { $0 >= start && $0 <= end }

        let combined = Highlights.combine(motion: motion, flash: flash, shake: shake)
        let hype = zip(live, combined).map { isLive, value in isLive ? value : 0.0 }
        let highlights = Highlights.findHighlights(t: t, hype: hype, live: live, cfg: cfg)

        return Analysis(
            meta: meta,
            t: t,
            motion: motion,
            flash: flash,
            shake: shake,
            hype: hype,
            highlights: highlights,
            actionStart: start,
            actionEnd: end
        )
    }
}
