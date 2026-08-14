import CoreImage
import Testing
@testable import RenderKit

/// Offline frame checks for the M4 visual layer (plan §6 M4, risk 1) -- no
/// AVFoundation pipeline involved, just the pure CIImage effect functions
/// exercised directly and rasterized to a CGImage for pixel assertions.
@Suite struct CompositorEffectsTests {
    static let context = CIContext()
    static let target = CGSize(width: 64, height: 64)

    @Test func flashFrameIsBrighterThanNeighbors() {
        let base = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: CGRect(origin: .zero, size: Self.target))

        let before = Flash.apply(base, elapsed: 0.0, at: 0.10)
        let peak = Flash.apply(base, elapsed: 0.10, at: 0.10)
        let after = Flash.apply(base, elapsed: 0.30, at: 0.10)

        #expect(Self.averageLuma(before) == Self.averageLuma(base))
        #expect(Self.averageLuma(after) == Self.averageLuma(base))
        let peakLuma = Self.averageLuma(peak)
        let baseLuma = Self.averageLuma(base)
        #expect(peakLuma >= baseLuma * 1.15, "flash peak frame should be >=15% brighter than neighbors")
    }

    @Test func xfadeMidFrameBlendsBothSources() {
        let rect = CGRect(origin: .zero, size: Self.target)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: rect)
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: rect)

        for kind in ["dissolve", "smoothleft", "smoothright", "smoothup", "circleopen", "fadegrays"] {
            let mid = Transitions.apply(kind: kind, from: red, to: blue, progress: 0.5, target: Self.target)
            let pixel = Self.samplePixel(mid, at: CGPoint(x: 32, y: 32))
            #expect(pixel.0 > 0.05 && pixel.2 > 0.05, "\(kind) mid-frame should carry both source colors, got \(pixel)")
        }
    }

    @Test func captionRendersNonEmptyWithinThreeLines() {
        let result = CaptionRenderer.renderDetailed(text: "This is a fairly long caption that should still autofit", width: 1080)
        let detail = try! #require(result)
        #expect(detail.lineCount <= 3)
        #expect(detail.image.width > 0)
        #expect(detail.image.height > 0)
    }

    private static func averageLuma(_ image: CIImage) -> Double {
        let (r, g, b) = samplePixel(image, at: CGPoint(x: 32, y: 32))
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    private static func samplePixel(_ image: CIImage, at point: CGPoint) -> (Double, Double, Double) {
        let rect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            image, toBitmap: &pixel, rowBytes: 4, bounds: rect,
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (Double(pixel[0]) / 255.0, Double(pixel[1]) / 255.0, Double(pixel[2]) / 255.0)
    }
}
