import Foundation

/// Port of `media.py`'s `Meta` — probed container metadata for one video.
public struct Meta: Sendable, Equatable {
    public let path: String
    public let width: Int
    public let height: Int
    public let fps: Double
    public let duration: Double

    public init(path: String, width: Int, height: Int, fps: Double, duration: Double) {
        self.path = path
        self.width = width
        self.height = height
        self.fps = fps
        self.duration = duration
    }

    public var aspect: Double { Double(width) / Double(height) }
}

public enum MediaError: Error, Equatable {
    case noVideoTrack(String)
    case indeterminateDuration(String)
    case readerFailed(String)
}

/// `media.py:37-38` `_even` — round to the nearest even integer, floor at 2.
/// Python's `round()` is banker's rounding (half-to-even), not Swift's default
/// half-away-from-zero -- they disagree exactly on ties like n=241 (120.5):
/// away-from-zero -> 121 -> 242, to-even -> 120 -> 240. Must use `.toNearestOrEven`
/// to match `_even`'s behavior exactly.
func evenSize(_ n: Double) -> Int {
    max(2, Int((n / 2).rounded(.toNearestOrEven)) * 2)
}
