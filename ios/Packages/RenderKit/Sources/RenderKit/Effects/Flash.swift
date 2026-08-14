import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import PlanKit

/// A two-frame white pop and a colour-split shiver on the impact frame --
/// ports render.py:185-201. Clips mode only, `hit` segments with a known
/// peak; `at` is computed once per segment (mirrors Python's single
/// evaluation) and reused every frame via `apply`.
enum Flash {
    /// Segment-local seconds the flash starts at, or nil if disabled --
    /// render.py:193-197's gating + range guard.
    static func at(for seg: Segment, mode: String) -> Double? {
        guard mode == "clips", seg.kind == "hit", seg.peak != 0 else { return nil }
        let at = (seg.peak - seg.start) / seg.speed
        guard at >= 0, at <= seg.outDuration - 0.15 else { return nil }
        return at
    }

    static func apply(_ image: CIImage, elapsed: Double, at: Double) -> CIImage {
        if elapsed >= at, elapsed < at + 0.07 {
            let brighten = CIFilter.colorControls()
            brighten.inputImage = image
            brighten.brightness = 0.28
            return (brighten.outputImage ?? image).cropped(to: image.extent)
        }
        if elapsed >= at + 0.07, elapsed < at + 0.15 {
            return rgbShift(image, rh: 6, bh: -6)
        }
        return image
    }

    /// Approximates ffmpeg's rgbashift=rh=6:bh=-6 -- red channel shifted
    /// right 6px, blue shifted left 6px, green untouched.
    private static func rgbShift(_ image: CIImage, rh: CGFloat, bh: CGFloat) -> CIImage {
        let extent = image.extent
        func channelOnly(_ img: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = img
            matrix.rVector = CIVector(x: r, y: 0, z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
            matrix.bVector = CIVector(x: 0, y: 0, z: b, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return matrix.outputImage ?? img
        }
        let red = channelOnly(image.transformed(by: CGAffineTransform(translationX: rh, y: 0)), r: 1, g: 0, b: 0)
        let green = channelOnly(image, r: 0, g: 1, b: 0)
        let blue = channelOnly(image.transformed(by: CGAffineTransform(translationX: bh, y: 0)), r: 0, g: 0, b: 1)

        let addRG = CIFilter.additionCompositing()
        addRG.inputImage = red
        addRG.backgroundImage = green
        let addRGB = CIFilter.additionCompositing()
        addRGB.inputImage = blue
        addRGB.backgroundImage = addRG.outputImage
        return (addRGB.outputImage ?? image).cropped(to: extent)
    }
}
