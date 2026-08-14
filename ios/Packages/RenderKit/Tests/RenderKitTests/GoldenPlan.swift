import Foundation
import PlanKit

/// Decodes tests/golden/plan_clips.json / plan_montage.json (produced by
/// scripts/export_golden.py) into PlanKit's own Segment/Group -- PlanKit
/// itself stays JSON-free (plan §5: the App/RenderKit layer owns Codable).
struct GoldenPlan: Decodable {
    let width: Int
    let height: Int
    let fps: Int
    let groups: [GoldenGroup]
}

struct GoldenGroup: Decodable {
    let name: String
    let title: String
    let hashtags: [String]
    let music: String?
    let segments: [GoldenSegment]

    func toPlanKitGroup() -> Group {
        Group(
            name: name, title: title, hashtags: hashtags,
            segments: segments.map { $0.toPlanKitSegment() }, music: music
        )
    }
}

struct GoldenSegment: Decodable {
    let src: Int
    let start: Double
    let end: Double
    let speed: Double
    let kind: String
    let score: Double
    let peak: Double
    let transIn: Double
    let transKind: String
    let caption: String
    let narrate: Bool
    let adlib: String

    enum CodingKeys: String, CodingKey {
        case src, start, end, speed, kind, score, peak, caption, narrate, adlib
        case transIn = "trans_in"
        case transKind = "trans_kind"
    }

    func toPlanKitSegment() -> Segment {
        Segment(
            src: src, start: start, end: end, speed: speed, kind: kind,
            score: score, peak: peak, transIn: transIn, transKind: transKind,
            caption: caption, narrate: narrate, adlib: adlib
        )
    }
}
