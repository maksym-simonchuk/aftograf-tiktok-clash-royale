import Foundation

// Port of src/crcut/plan.py:55-194 (Segment, Group, EditPlan, Window) and the
// minimal slice of detect.Analysis that plan.py actually reads (meta.path,
// meta.duration, t, hype, highlights, action_start, action_end -- not
// motion/flash/shake, which plan.py never touches). PlanKit does not depend on
// DetectKit; callers adapt their own analysis into this shape.
public struct AnalysisInput: Sendable {
    public var path: String
    public var duration: Double
    public var t: [Double]
    public var hype: [Double]
    public var highlights: [Double]
    public var actionStart: Double
    public var actionEnd: Double

    public init(
        path: String, duration: Double, t: [Double], hype: [Double],
        highlights: [Double], actionStart: Double, actionEnd: Double
    ) {
        self.path = path
        self.duration = duration
        self.t = t
        self.hype = hype
        self.highlights = highlights
        self.actionStart = actionStart
        self.actionEnd = actionEnd
    }
}

// plan.py:187-194
public struct Window: Sendable {
    public var src: Int
    public var start: Double
    public var end: Double
    public var peak: Double
    public var score: Double

    public init(src: Int, start: Double, end: Double, peak: Double, score: Double) {
        self.src = src
        self.start = start
        self.end = end
        self.peak = peak
        self.score = score
    }
}

// plan.py:55-72
public struct Segment: Sendable {
    public var src: Int
    public var start: Double
    public var end: Double
    public var speed: Double
    public var kind: String
    public var score: Double
    public var peak: Double // source-time impact moment inside a hit; 0 = unknown
    public var transIn: Double // cross-fade overlap with the previous shot, 0 = hard cut
    public var transKind: String
    public var caption: String
    public var narrate: Bool // is that caption also read out loud, or only drawn
    public var adlib: String // spoken only -- the narrator's reaction, never drawn on screen

    public init(
        src: Int, start: Double, end: Double, speed: Double, kind: String,
        score: Double = 0.0, peak: Double = 0.0, transIn: Double = 0.0,
        transKind: String = "", caption: String = "", narrate: Bool = false,
        adlib: String = ""
    ) {
        self.src = src
        self.start = start
        self.end = end
        self.speed = speed
        self.kind = kind
        self.score = score
        self.peak = peak
        self.transIn = transIn
        self.transKind = transKind
        self.caption = caption
        self.narrate = narrate
        self.adlib = adlib
    }

    public var outDuration: Double { (end - start) / speed }
}

// plan.py:75-96
public struct Group: Sendable {
    public var name: String
    public var title: String
    public var hashtags: [String]
    public var segments: [Segment]
    public var music: String? // overrides the plan-wide track, so variants can differ

    public init(
        name: String, title: String, hashtags: [String], segments: [Segment],
        music: String? = nil
    ) {
        self.name = name
        self.title = title
        self.hashtags = hashtags
        self.segments = segments
        self.music = music
    }

    /// Cross-fades overlap, so every transition shortens the result.
    public var outDuration: Double {
        segments.reduce(0.0) { $0 + ($1.outDuration - $1.transIn) }
    }

    /// Each segment with the output timestamp it starts at.
    public func timeline() -> [(segment: Segment, start: Double)] {
        var out: [(Segment, Double)] = []
        var t = 0.0
        for seg in segments {
            t -= seg.transIn
            out.append((seg, t))
            t += seg.outDuration
        }
        return out
    }
}

// plan.py:99-153 (to_dict/dump/load are Python JSON-sidecar concerns; the App/RenderKit
// layer owns Codable JSON export on the device, so it is not ported here)
public struct EditPlan: Sendable {
    public var version: Int
    public var mode: String
    public var lang: String
    public var width: Int
    public var height: Int
    public var fps: Int
    public var music: String?
    public var voice: String?
    public var voiceStyle: String
    public var sources: [String]
    public var groups: [Group]
    public var events: [String: [Double]]

    public init(
        version: Int, mode: String, lang: String, width: Int, height: Int, fps: Int,
        music: String?, voice: String?, voiceStyle: String, sources: [String],
        groups: [Group], events: [String: [Double]] = [:]
    ) {
        self.version = version
        self.mode = mode
        self.lang = lang
        self.width = width
        self.height = height
        self.fps = fps
        self.music = music
        self.voice = voice
        self.voiceStyle = voiceStyle
        self.sources = sources
        self.groups = groups
        self.events = events
    }
}

public let planVersion = 1 // plan.py:19 PLAN_VERSION

public enum PlanError: Error, CustomStringConvertible {
    case noHighlightWindows

    public var description: String {
        switch self {
        case .noHighlightWindows:
            return "no highlight windows found"
        }
    }
}
