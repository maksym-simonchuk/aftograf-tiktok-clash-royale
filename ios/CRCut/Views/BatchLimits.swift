import Foundation

/// Batch size limits (plan §M8): at most 5 clips, at most 15 minutes total.
/// `validate` is pure (Doubles in, no I/O) so it's checkable without
/// PhotosPicker/AVFoundation in the loop.
enum BatchLimits {
    static let maxSelectionCount = 5
    static let maxTotalDuration: Double = 15 * 60 // seconds

    struct Violation {
        let selectedCount: Int
        let totalDuration: Double
    }

    /// nil when `durations` is within the total-duration limit; otherwise
    /// the numbers an alert needs to explain the rejection.
    static func validate(durations: [Double]) -> Violation? {
        let total = durations.reduce(0, +)
        guard total > maxTotalDuration else { return nil }
        return Violation(selectedCount: durations.count, totalDuration: total)
    }
}
