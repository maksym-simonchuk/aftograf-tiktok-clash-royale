import AVFoundation
import CoreImage

/// AVVideoCompositing conformance -- a thin AVFoundation-facing wrapper
/// around the pure CIImage effect functions (Geometry/Punch/Flash/Transitions),
/// so the actual visual logic stays independently testable off the
/// compositing pipeline entirely (plan §6 M4 risk 1).
final class CRCutVideoCompositor: NSObject, AVVideoCompositing {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]

    private let context = CIContext()

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? CRCutCompositionInstruction else {
                request.finish(with: RenderError.writerFailed("unexpected video composition instruction type"))
                return
            }
            guard let outputBuffer = request.renderContext.newPixelBuffer() else {
                request.finish(with: RenderError.writerFailed("render context returned no pixel buffer"))
                return
            }
            let target = request.renderContext.size
            let image = Self.compose(request: request, instruction: instruction, target: target)
            context.render(image, to: outputBuffer)
            request.finish(withComposedVideoFrame: outputBuffer)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    private static func compose(
        request: AVAsynchronousVideoCompositionRequest, instruction: CRCutCompositionInstruction, target: CGSize
    ) -> CIImage {
        switch instruction.kind {
        case .single(let render):
            guard let buffer = request.sourceFrame(byTrackID: render.trackID) else {
                return blank(target)
            }
            let elapsed = (request.compositionTime - render.localStart).seconds
            return frame(pixelBuffer: buffer, render: render, elapsed: elapsed, target: target)
        case .transition(let from, let to, let kind, let window):
            let fromImage = request.sourceFrame(byTrackID: from.trackID).map {
                frame(pixelBuffer: $0, render: from, elapsed: (request.compositionTime - from.localStart).seconds, target: target)
            } ?? blank(target)
            let toImage = request.sourceFrame(byTrackID: to.trackID).map {
                frame(pixelBuffer: $0, render: to, elapsed: (request.compositionTime - to.localStart).seconds, target: target)
            } ?? blank(target)
            let progress = window.duration.seconds > 0
                ? (request.compositionTime - window.start).seconds / window.duration.seconds
                : 1.0
            return Transitions.apply(kind: kind, from: fromImage, to: toImage, progress: progress, target: target)
        }
    }

    /// Pure geometry+punch+flash pipeline for one source frame -- exactly
    /// what the offline effect tests exercise directly, with no AVFoundation
    /// plumbing involved (plan §6 M4's "чистые CI-функции" mandate).
    static func frame(pixelBuffer: CVPixelBuffer, render: SegmentRender, elapsed: Double, target: CGSize) -> CIImage {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        image = Geometry.frame(
            image, naturalSize: render.naturalSize, preferredTransform: render.preferredTransform,
            pillarbox: render.pillarbox, target: target
        )
        image = Punch.apply(image, kind: render.kind, elapsed: elapsed, target: target)
        if let flashAt = render.flashAt {
            image = Flash.apply(image, elapsed: elapsed, at: flashAt)
        }
        return image
    }

    private static func blank(_ target: CGSize) -> CIImage {
        CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: target))
    }
}
