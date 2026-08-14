import Foundation

/// Output frame geometry — mirrors EditPlan.width/height/fps (PlanKit).
public struct RenderTarget: Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int

    public init(width: Int, height: Int, fps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
    }
}

public enum RenderError: Error, CustomStringConvertible, Sendable {
    case emptyGroup(String)
    case sourceIndexOutOfRange(Int)
    case noVideoTrack(String)
    case readerFailed(String)
    case writerFailed(String)

    public var description: String {
        switch self {
        case .emptyGroup(let name):
            return "group \(name) has no segments"
        case .sourceIndexOutOfRange(let idx):
            return "segment references source index \(idx), out of range"
        case .noVideoTrack(let name):
            return "\(name) has no video track"
        case .readerFailed(let message):
            return "AVAssetReader failed: \(message)"
        case .writerFailed(let message):
            return "AVAssetWriter failed: \(message)"
        }
    }
}
