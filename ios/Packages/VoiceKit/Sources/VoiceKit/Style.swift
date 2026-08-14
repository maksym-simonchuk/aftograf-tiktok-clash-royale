import Foundation
import CryptoKit

/// Port of `voice.py` `Style`/`STYLES` -- edge-tts side only (rate %, pitch Hz, jitter).
/// `say`-only fields (`rate` wpm, `shift`, `chain`) have no iOS equivalent and are
/// dropped; `LocalTTS` derives its own rate/pitch from these same edge fields.
public struct VoiceStyle: Sendable, Equatable {
    public let edgeRate: Int   // percent rate offset for edge-tts, e.g. -8
    public let edgePitch: Int  // Hz pitch offset for edge-tts, e.g. -6
    public let edgeJitter: Bool

    public init(edgeRate: Int, edgePitch: Int, edgeJitter: Bool) {
        self.edgeRate = edgeRate
        self.edgePitch = edgePitch
        self.edgeJitter = edgeJitter
    }
}

public enum VoiceStyles {
    public static let story = VoiceStyle(edgeRate: -8, edgePitch: -6, edgeJitter: true)
    public static let grandpa = VoiceStyle(edgeRate: -12, edgePitch: -10, edgeJitter: false)
    public static let grandpaDeep = VoiceStyle(edgeRate: -12, edgePitch: -10, edgeJitter: false)
    public static let hype = VoiceStyle(edgeRate: 14, edgePitch: 4, edgeJitter: false)
    public static let rasp = VoiceStyle(edgeRate: 14, edgePitch: 4, edgeJitter: false)
    public static let clean = VoiceStyle(edgeRate: 0, edgePitch: 0, edgeJitter: false)

    public static let defaultName = "story"

    public static let all: [String: VoiceStyle] = [
        "story": story, "grandpa": grandpa, "grandpa_deep": grandpaDeep,
        "hype": hype, "rasp": rasp, "clean": clean,
    ]

    public static func named(_ name: String) -> VoiceStyle {
        all[name] ?? story
    }
}

/// Port of `voice.py::_edge_recipe` -- per-phrase jitter derived from `sha1(text)`, so
/// the nudge is stable across runs (same cache key) but differs between lines.
public enum EdgeRecipe {
    public static func rateAndPitch(style: VoiceStyle, text: String) -> (rate: Int, pitch: Int) {
        guard style.edgeJitter else { return (style.edgeRate, style.edgePitch) }
        let seed = sha1Seed(text)
        let rate = style.edgeRate + Int(seed % 9) - 4   // +-4%
        let pitch = style.edgePitch + Int((seed >> 8) % 7) - 3  // +-3Hz
        return (rate, pitch)
    }

    /// First 4 bytes of sha1(text) as a big-endian uint32 -- matches Python's
    /// `int(hashlib.sha1(text.encode()).hexdigest()[:8], 16)`.
    static func sha1Seed(_ text: String) -> UInt32 {
        let digest = Insecure.SHA1.hash(data: Data(text.utf8))
        return digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
