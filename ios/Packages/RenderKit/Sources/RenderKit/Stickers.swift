import CoreGraphics
import PlanKit

/// One rendered caption image + when it appears, in the group's absolute
/// output timeline -- render.py's Sticker, captions only. Memes need bundled
/// PNGs that don't exist in the app bundle yet (README's Layout: memes/ lands
/// in M5/M8), so that branch of render.py:239-247 is out of scope here.
struct CaptionCue {
    let image: CGImage
    let start: Double // clamped >= 0, render.py:231/236
}

enum Stickers {
    static func captionCues(for group: Group, width: Int) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        for (seg, rawStart) in group.timeline() {
            guard !seg.caption.isEmpty, let image = CaptionRenderer.render(text: seg.caption, width: width) else {
                continue
            }
            cues.append(CaptionCue(image: image, start: max(rawStart, 0.0)))
        }
        return cues
    }
}
