/// Port of `detect.py:24-39` `DetectConfig` — every constant matches the Python
/// default exactly (golden tests run with these defaults).
public struct DetectConfig: Sendable {
    public var sampleFPS: Double = 10.0
    public var sampleWidth: Int = 240
    // arena band (fractions of frame height) -- between the two card hands
    public var arenaTop: Double = 0.24
    public var arenaBottom: Double = 0.84
    // rows the match gate watches: the hands and name plates above/below the arena
    public var hudTop: Double = 0.14
    public var hudBottom: Double = 0.85
    public var liveRatio: Double = 2.5
    // highlight picking
    public var smooth: Double = 1.5
    public var minGap: Double = 6.0
    public var maxHighlights: Int = 6
    public var minHype: Double = 0.5

    public init() {}
}
