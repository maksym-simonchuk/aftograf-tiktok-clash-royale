import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// The 6 xfade transition kinds plan.py:646 can pick, applied to the frame
/// at one instant inside the overlap window (`progress` 0 = fully `from`,
/// 1 = fully `to`) -- ports render.py:204-224's `xfade=transition=...` for
/// each named kind. Not pixel-identical to ffmpeg's xfade GLSL, but each is a
/// genuine two-source blend appropriate to its name.
enum Transitions {
    static func apply(kind: String, from: CIImage, to: CIImage, progress: Double, target: CGSize) -> CIImage {
        let p = CGFloat(min(max(progress, 0), 1))
        switch kind {
        case "smoothleft":
            return wipe(from: from, to: to, progress: p, target: target, axis: .horizontal, reversed: false)
        case "smoothright":
            return wipe(from: from, to: to, progress: p, target: target, axis: .horizontal, reversed: true)
        case "smoothup":
            return wipe(from: from, to: to, progress: p, target: target, axis: .vertical, reversed: false)
        case "circleopen":
            return circleOpen(from: from, to: to, progress: p, target: target)
        case "fadegrays":
            return fadeThroughGray(from: from, to: to, progress: p, target: target)
        default: // "dissolve" and any unrecognised kind
            return dissolve(from: from, to: to, progress: p, target: target)
        }
    }

    private enum Axis { case horizontal, vertical }

    private static func dissolve(from: CIImage, to: CIImage, progress: CGFloat, target: CGSize) -> CIImage {
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = from
        filter.targetImage = to
        filter.time = Float(progress)
        return (filter.outputImage ?? to).cropped(to: CGRect(origin: .zero, size: target))
    }

    private static func wipe(
        from: CIImage, to: CIImage, progress: CGFloat, target: CGSize, axis: Axis, reversed: Bool
    ) -> CIImage {
        let rect = CGRect(origin: .zero, size: target)
        let feather: CGFloat = 60
        let gradient = CIFilter.linearGradient()
        switch axis {
        case .horizontal:
            let edge = reversed ? target.width * (1 - progress) : target.width * progress
            gradient.point0 = CGPoint(x: reversed ? edge + feather : edge - feather, y: 0)
            gradient.point1 = CGPoint(x: reversed ? edge - feather : edge + feather, y: 0)
        case .vertical:
            // sweeps in from the bottom as progress grows ("smoothup")
            let edge = target.height * (1 - progress)
            gradient.point0 = CGPoint(x: 0, y: edge + feather)
            gradient.point1 = CGPoint(x: 0, y: edge - feather)
        }
        gradient.color0 = CIColor.white
        gradient.color1 = CIColor.black
        let mask = (gradient.outputImage ?? CIImage(color: .black)).cropped(to: rect)
        return blend(from: from, to: to, mask: mask, rect: rect)
    }

    private static func circleOpen(from: CIImage, to: CIImage, progress: CGFloat, target: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: target)
        let center = CGPoint(x: target.width / 2, y: target.height / 2)
        let maxRadius = hypot(target.width, target.height) / 2
        let radius = maxRadius * progress
        let feather: CGFloat = 60
        let gradient = CIFilter.radialGradient()
        gradient.center = center
        gradient.radius0 = Float(max(radius - feather, 0))
        gradient.radius1 = Float(radius + feather)
        gradient.color0 = CIColor.white
        gradient.color1 = CIColor.black
        let mask = (gradient.outputImage ?? CIImage(color: .black)).cropped(to: rect)
        return blend(from: from, to: to, mask: mask, rect: rect)
    }

    /// Fades `from` down to mid-gray, then mid-gray up to `to` -- ffmpeg's
    /// "fadegrays" transition.
    private static func fadeThroughGray(from: CIImage, to: CIImage, progress: CGFloat, target: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: target)
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: rect)
        if progress < 0.5 {
            return dissolve(from: from, to: gray, progress: progress * 2, target: target)
        }
        return dissolve(from: gray, to: to, progress: (progress - 0.5) * 2, target: target)
    }

    /// White mask pixels show `to`, black show `from` -- CIBlendWithMask is
    /// luminance-driven.
    private static func blend(from: CIImage, to: CIImage, mask: CIImage, rect: CGRect) -> CIImage {
        let filter = CIFilter.blendWithMask()
        filter.inputImage = to
        filter.backgroundImage = from
        filter.maskImage = mask
        return (filter.outputImage ?? to).cropped(to: rect)
    }
}
