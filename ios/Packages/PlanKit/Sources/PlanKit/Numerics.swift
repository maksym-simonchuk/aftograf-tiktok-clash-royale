import Foundation

// Small numeric helpers plan.py gets for free from Python/numpy.

/// Python `round(x, 3)`. NOTE: this is round-half-away-from-zero, not Python's
/// round-half-to-even -- the two differ only on an exact decimal tie, which real
/// timestamp arithmetic essentially never produces. ponytail: known ceiling, not
/// worth a banker's-rounding implementation unless a golden test ever proves a tie.
func round3(_ x: Double) -> Double {
    (x * 1000).rounded() / 1000
}

/// numpy.median for a non-empty array (sorted-copy, average the middle two on even count).
func median(_ xs: [Double]) -> Double {
    precondition(!xs.isEmpty)
    let sorted = xs.sorted()
    let n = sorted.count
    if n % 2 == 1 { return sorted[n / 2] }
    return (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
}

/// numpy.diff: consecutive differences.
func diffs(_ xs: [Double]) -> [Double] {
    guard xs.count > 1 else { return [] }
    return (1..<xs.count).map { xs[$0] - xs[$0 - 1] }
}

/// Python `max(items, key:)`: keeps the FIRST element on a tie. Swift's own
/// `Sequence.max(by:)` keeps the LAST tied element, so it cannot be reused here --
/// this mirrors plan.py:362 `best = max(chunk, key=lambda w: w.score)`.
func firstMax<T>(_ items: [T], by key: (T) -> Double) -> T {
    precondition(!items.isEmpty)
    var bestItem = items[0]
    var bestKey = key(items[0])
    for item in items.dropFirst() {
        let k = key(item)
        if k > bestKey {
            bestKey = k
            bestItem = item
        }
    }
    return bestItem
}
