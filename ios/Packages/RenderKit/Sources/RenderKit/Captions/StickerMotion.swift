import Foundation

/// Caption appear/fade timing -- ports render.py:19's CAPTION_LEN, the
/// settle-onto-its-line y-expr from render.py:236, and the in/out fades from
/// render.py:255-256/227-248.
enum StickerMotion {
    static let captionLength = 1.7 // CAPTION_LEN
    private static let fadeIn = 0.15
    private static let fadeOut = 0.25

    /// Vertical center, in top-left/y-down pixel coordinates (matches the
    /// ffmpeg overlay y-expr this ports) -- caller flips into CIImage's
    /// bottom-left/y-up space. `elapsed` is seconds since the caption's start.
    static func y(elapsed: Double, height: Double) -> Double {
        height * 0.60 + 40 * exp(-9 * elapsed)
    }

    /// 0...1 alpha multiplier: fades in over `fadeIn`, holds, fades out over
    /// the last `fadeOut` seconds of `duration`.
    static func opacity(elapsed: Double, duration: Double = captionLength) -> Double {
        guard elapsed >= 0, elapsed <= duration else { return 0 }
        if elapsed < fadeIn { return elapsed / fadeIn }
        let outStart = duration - fadeOut
        if elapsed > outStart { return max(0, (duration - elapsed) / fadeOut) }
        return 1
    }
}
