import AVFoundation
import CoreGraphics

/// Everything the compositor needs to re-derive one segment's frame: which
/// composition track it lives on, when it starts (segment-local elapsed time
/// for punch/flash = compositionTime - localStart), and its geometry/effect
/// parameters as Composer.build resolved them.
struct SegmentRender {
    let trackID: CMPersistentTrackID
    let localStart: CMTime
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let pillarbox: Bool
    let kind: String
    let flashAt: Double?
}

enum CRCutInstructionKind {
    case single(SegmentRender)
    case transition(from: SegmentRender, to: SegmentRender, kind: String, window: CMTimeRange)
}

/// One AVVideoCompositionInstruction per solo segment or per transition
/// overlap window (Composer's two-pass build, plan §6 M4) -- the custom
/// counterpart to AVMutableVideoCompositionInstruction/LayerInstruction.
final class CRCutCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let kind: CRCutInstructionKind

    init(timeRange: CMTimeRange, kind: CRCutInstructionKind) {
        self.timeRange = timeRange
        self.kind = kind
        switch kind {
        case .single(let render):
            requiredSourceTrackIDs = [NSNumber(value: render.trackID)]
        case .transition(let from, let to, _, _):
            requiredSourceTrackIDs = [NSNumber(value: from.trackID), NSNumber(value: to.trackID)]
        }
        super.init()
    }
}
