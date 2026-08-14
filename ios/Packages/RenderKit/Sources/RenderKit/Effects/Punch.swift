import CoreGraphics
import CoreImage

/// Impact zoom plus a short camera shake, on the moment itself -- ports
/// render.py:163-182's zoompan. zoompan there runs on an already-target-sized
/// frame (`d=1:s={W}x{H}`), so this crops a shrinking/jittering window out of
/// the target-sized frame and rescales it back to fill target -- same trick,
/// pixels instead of ffmpeg's per-frame zoompan state machine. `elapsed` is
/// segment-local seconds since this segment's own start (zoompan's `on/fps`).
enum Punch {
    static func apply(_ image: CIImage, kind: String, elapsed: Double, target: CGSize) -> CIImage {
        guard elapsed >= 0, let params = parameters(for: kind) else { return image }
        let t = elapsed
        let zoom = CGFloat(1 + params.amount * exp(-t / params.decay))
        guard zoom > 0 else { return image }
        let shakeEnvelope = exp(-t / 0.20)
        let shakeX = CGFloat(7 * sin(t * 106) * shakeEnvelope)
        let shakeY = CGFloat(6 * cos(t * 82) * shakeEnvelope)

        let w = target.width, h = target.height
        let cropW = w / zoom, cropH = h / zoom
        guard cropW > 0, cropH > 0 else { return image }

        // zoompan's x/y are top-left origin, y-down -- the crop window's
        // top-left corner, centered then jittered by the shake.
        let xTopLeft = w / 2 - cropW / 2 + shakeX
        let yTopLeft = h / 2 - cropH / 2 + shakeY
        let yBottomLeft = h - yTopLeft - cropH // flip into CIImage's bottom-left/y-up space

        let translate = CGAffineTransform(translationX: -xTopLeft, y: -yBottomLeft)
        let scale = CGAffineTransform(scaleX: zoom, y: zoom)
        return image
            .transformed(by: translate.concatenating(scale))
            .cropped(to: CGRect(origin: .zero, size: target))
    }

    private static func parameters(for kind: String) -> (amount: Double, decay: Double)? {
        switch kind {
        case "hit": return (0.10, 0.30)
        case "hook": return (0.13, 0.45)
        default: return nil
        }
    }
}
