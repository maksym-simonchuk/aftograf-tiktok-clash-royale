import CoreGraphics
import CoreText
import Foundation

/// Caption images drawn with Core Text -- the Swift port of overlay.py's
/// Pillow renderer. Text arrives as pixels here too: a CGImage overlaid by
/// the compositor rather than any text-track/subtitle mechanism, matching
/// the ffmpeg pipeline's own workaround (overlay.py:1-7).
///
/// Attributes are set via CFAttributedString + the kCT*AttributeName
/// constants (not NSAttributedString.Key.font/.foregroundColor/...) --
/// those convenience keys live in AppKit/UIKit's NSAttributedString
/// additions, unavailable in a pure CoreText target shared between iOS and
/// macOS without linking either.
enum CaptionRenderer {
    private static let fill = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    private static let strokeColor = CGColor(red: 14.0 / 255, green: 14.0 / 255, blue: 22.0 / 255, alpha: 1)

    private static func makeFont(size: CGFloat) -> CTFont {
        CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil) // never fails, silently substitutes
    }

    /// Tight RGBA caption image for `text`, sized relative to `width` --
    /// overlay.py:39-68. Autofits to <=3 lines (or gives up at font size 28,
    /// same fallback Python takes).
    static func render(text: String, width: Int) -> CGImage? {
        renderDetailed(text: text, width: width)?.image
    }

    static func renderDetailed(text: String, width: Int) -> (image: CGImage, lineCount: Int)? {
        guard !text.isEmpty else { return nil }
        let maxW = CGFloat(width) * 0.86
        var size = CGFloat(width) * 0.115
        var lines: [String] = []
        var font = makeFont(size: size)

        while true {
            font = makeFont(size: size)
            lines = wrap(text, font: font, maxWidth: maxW)
            let widest = lines.map { lineWidth($0, font: font) }.max() ?? 0
            if size <= 28 || (lines.count <= 3 && widest <= maxW) { break }
            size *= 0.88
        }

        let strokeWidth = max(2, Int(size) / 9)
        let pad = strokeWidth * 2 + 8
        let lineHeight = Int((size * 1.16).rounded(.down))
        let canvasWidth = max(1, Int(maxW.rounded(.up)) + 2 * pad)
        let canvasHeight = max(1, lineHeight * lines.count + 2 * pad)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8,
                bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        for (i, line) in lines.enumerated() {
            let ctLine = CTLineCreateWithAttributedString(
                lineAttributedString(line, font: font, strokeWidth: -Double(strokeWidth * 2))
            )
            let bounds = CTLineGetBoundsWithOptions(ctLine, [])
            let x = (CGFloat(canvasWidth) - bounds.width) / 2 - bounds.minX
            let top = CGFloat(pad) + CGFloat(lineHeight * i)
            let baselineY = CGFloat(canvasHeight) - top - CTFontGetAscent(font)
            context.textPosition = CGPoint(x: x, y: baselineY)
            CTLineDraw(ctLine, context)
        }

        guard let cgImage = context.makeImage() else { return nil }
        return (tightCrop(cgImage), lines.count)
    }

    private static func wrap(_ text: String, font: CTFont, maxWidth: CGFloat) -> [String] {
        var lines: [String] = []
        for word in text.split(separator: " ") {
            if let last = lines.last {
                let candidate = "\(last) \(word)"
                if lineWidth(candidate, font: font) <= maxWidth {
                    lines[lines.count - 1] = candidate
                    continue
                }
            }
            lines.append(String(word))
        }
        return lines.isEmpty ? [text] : lines
    }

    private static func lineWidth(_ text: String, font: CTFont) -> CGFloat {
        let attributed = lineAttributedString(text, font: font, strokeWidth: nil)
        return CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(attributed), []).width
    }

    /// Builds a CFAttributedString via the kCT*AttributeName constants --
    /// pure CoreText, no NSAttributedString.Key.font/.foregroundColor/...
    /// (those live in AppKit/UIKit only). `strokeWidth` nil omits fill/stroke
    /// color entirely (used only for width measurement).
    private static func lineAttributedString(_ text: String, font: CTFont, strokeWidth: Double?) -> CFAttributedString {
        let attributed = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
        CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), text as CFString)
        let range = CFRange(location: 0, length: CFAttributedStringGetLength(attributed))
        CFAttributedStringSetAttribute(attributed, range, kCTFontAttributeName, font)
        if let strokeWidth {
            CFAttributedStringSetAttribute(attributed, range, kCTForegroundColorAttributeName, fill)
            CFAttributedStringSetAttribute(attributed, range, kCTStrokeColorAttributeName, strokeColor)
            CFAttributedStringSetAttribute(attributed, range, kCTStrokeWidthAttributeName, NSNumber(value: strokeWidth))
        }
        return attributed
    }

    /// CoreGraphics equivalent of PIL's `img.getbbox()` -- tight-crops to the
    /// smallest rect containing any non-transparent pixel (overlay.py:67).
    private static func tightCrop(_ image: CGImage) -> CGImage {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
            let data = image.dataProvider?.data,
            let ptr = CFDataGetBytePtr(data)
        else { return image }
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let alphaOffset = bytesPerPixel - 1 // premultipliedLast: alpha is the last byte

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                if ptr[row + x * bytesPerPixel + alphaOffset] > 0 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return image.cropping(to: rect) ?? image
    }
}
