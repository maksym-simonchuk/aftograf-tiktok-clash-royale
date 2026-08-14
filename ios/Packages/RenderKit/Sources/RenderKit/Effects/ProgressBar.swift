import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Retention bar sliding in left-to-right across the whole render -- ports
/// render.py:69-74/render.py:71-74's overlay. `progress` is
/// `elapsed / total` in the group's absolute output timeline.
enum ProgressBar {
    static let color = CIColor(red: 0xF7 / 255.0, green: 0xD0 / 255.0, blue: 0x46 / 255.0)

    static func apply(_ image: CIImage, target: CGSize, progress: Double) -> CIImage {
        let barHeight = max(6, target.height / 200)
        let barWidth = target.width * CGFloat(min(max(progress, 0), 1))
        guard barWidth > 0 else { return image }

        let rect = CGRect(x: 0, y: target.height - barHeight, width: barWidth, height: barHeight)
        let bar = CIImage(color: color).cropped(to: rect)
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = bar
        over.backgroundImage = image
        return (over.outputImage ?? image).cropped(to: CGRect(origin: .zero, size: target))
    }
}
