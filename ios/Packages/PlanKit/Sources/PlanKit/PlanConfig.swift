// Port of src/crcut/plan.py:22-52 (PlanConfig, 26 constants). Values copied verbatim.

public struct PlanConfig: Sendable {
    public var mode: String
    public var lang: String
    public var targetDuration: Double
    public var width: Int
    public var height: Int
    public var fps: Int
    // window around a detected event
    public var pre: Double
    public var post: Double
    public var clipPre: Double
    public var clipPost: Double
    public var clipMax: Double // a clip never runs longer -- TikTok's short-attention cut
    public var clipEvents: Int // a clip bundles up to this many pushes: 2-3 read as a story
    // speed ramps
    public var leadSpeed: Double
    public var hitSpeed: Double
    public var hitPre: Double
    public var hitPost: Double
    public var maxLead: Double // merged windows must not become one long unedited shot
    public var hookLen: Double
    public var hookSpeed: Double
    public var minSegment: Double
    public var beatSnap: Double
    // cross-fade between shots (never inside one, where a fade would read as a stutter)
    public var transition: Double
    public var captionLen: Double
    public var variants: Int
    public var voice: String? // system voice that reads the captions out loud
    public var voiceStyle: String // recipe in voice.STYLES: how that voice is shaped

    public init(
        mode: String = "montage",
        lang: String = "ru",
        targetDuration: Double = 42.0,
        width: Int = 1080,
        height: Int = 1920,
        fps: Int = 30,
        pre: Double = 4.5,
        post: Double = 2.0,
        clipPre: Double = 8.0,
        clipPost: Double = 4.0,
        clipMax: Double = 20.0,
        clipEvents: Int = 3,
        leadSpeed: Double = 1.35,
        hitSpeed: Double = 0.55,
        hitPre: Double = 1.2,
        hitPost: Double = 0.5,
        maxLead: Double = 3.5,
        hookLen: Double = 0.8,
        hookSpeed: Double = 0.7,
        minSegment: Double = 0.35,
        beatSnap: Double = 0.30,
        transition: Double = 0.30,
        captionLen: Double = 1.7,
        variants: Int = 3,
        voice: String? = nil,
        voiceStyle: String = "grandpa"
    ) {
        self.mode = mode
        self.lang = lang
        self.targetDuration = targetDuration
        self.width = width
        self.height = height
        self.fps = fps
        self.pre = pre
        self.post = post
        self.clipPre = clipPre
        self.clipPost = clipPost
        self.clipMax = clipMax
        self.clipEvents = clipEvents
        self.leadSpeed = leadSpeed
        self.hitSpeed = hitSpeed
        self.hitPre = hitPre
        self.hitPost = hitPost
        self.maxLead = maxLead
        self.hookLen = hookLen
        self.hookSpeed = hookSpeed
        self.minSegment = minSegment
        self.beatSnap = beatSnap
        self.transition = transition
        self.captionLen = captionLen
        self.variants = variants
        self.voice = voice
        self.voiceStyle = voiceStyle
    }
}
