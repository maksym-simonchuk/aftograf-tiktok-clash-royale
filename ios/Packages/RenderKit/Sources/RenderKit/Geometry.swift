import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Per-frame frame geometry for the custom compositor -- the CIImage-space
/// port of the old aspectFillTransform (M3) plus the pillarboxed branch of
/// render.py:119-160 (blurred/darkened backdrop, sharp-fit foreground on
/// top). CIImage and AVFoundation's layer-instruction transform share the
/// same bottom-left-origin, y-up coordinate space, so the scale/center math
/// here is the same M3 already verified, just applied to pixels instead of
/// a transform matrix.
enum Geometry {
    static func frame(
        _ source: CIImage, naturalSize: CGSize, preferredTransform: CGAffineTransform,
        pillarbox: Bool, target: CGSize
    ) -> CIImage {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let uprightSize = CGSize(width: abs(rect.width), height: abs(rect.height))
        guard uprightSize.width > 0, uprightSize.height > 0 else { return source }
        let normalize = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
        let upright = source
            .transformed(by: preferredTransform.concatenating(normalize))
            .cropped(to: CGRect(origin: .zero, size: uprightSize))

        return pillarbox
            ? pillarboxed(upright, uprightSize: uprightSize, target: target)
            : filled(upright, uprightSize: uprightSize, target: target)
    }

    /// Scales the upright frame up to fill target and centers it, cropping
    /// the overflow -- the non-pillarboxed branch of render.py:137-157.
    private static func filled(_ upright: CIImage, uprightSize: CGSize, target: CGSize) -> CIImage {
        scaledAndCentered(upright, uprightSize: uprightSize, target: target, pick: max)
            .cropped(to: CGRect(origin: .zero, size: target))
    }

    /// Scales the upright frame down to fit entirely within target, centered
    /// -- letterboxed, no crop (render.py:149's `force_original_aspect_ratio=decrease`).
    private static func fitted(_ upright: CIImage, uprightSize: CGSize, target: CGSize) -> CIImage {
        scaledAndCentered(upright, uprightSize: uprightSize, target: target, pick: min)
    }

    private static func scaledAndCentered(
        _ upright: CIImage, uprightSize: CGSize, target: CGSize, pick: (CGFloat, CGFloat) -> CGFloat
    ) -> CIImage {
        let scale = pick(target.width / uprightSize.width, target.height / uprightSize.height)
        let scaledSize = CGSize(width: uprightSize.width * scale, height: uprightSize.height * scale)
        let tx = (target.width - scaledSize.width) / 2
        let ty = (target.height - scaledSize.height) / 2
        return upright
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))
    }

    /// render.py:146-155: a blurred, darkened fill as backdrop behind a sharp
    /// letterboxed foreground -- for sources whose aspect doesn't match target.
    private static func pillarboxed(_ upright: CIImage, uprightSize: CGSize, target: CGSize) -> CIImage {
        let targetRect = CGRect(origin: .zero, size: target)

        let backdrop = filled(upright, uprightSize: uprightSize, target: target)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24])
            .cropped(to: targetRect)

        let darken = CIFilter.colorControls()
        darken.inputImage = backdrop
        darken.brightness = -0.12
        let darkened = (darken.outputImage ?? backdrop).cropped(to: targetRect)

        let foreground = fitted(upright, uprightSize: uprightSize, target: target)
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = foreground
        over.backgroundImage = darkened
        return (over.outputImage ?? darkened).cropped(to: targetRect)
    }
}
