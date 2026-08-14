import MediaKit

/// Port of `detect.py:42-61` `Analysis`.
public struct Analysis: Sendable {
    public let meta: Meta
    public let t: [Double]
    public let motion: [Double]
    public let flash: [Double]
    public let shake: [Double]
    public let hype: [Double]
    public let highlights: [Double]
    public let actionStart: Double
    public let actionEnd: Double
}
