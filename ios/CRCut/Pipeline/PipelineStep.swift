import Foundation

/// Coarse stage inside one item's `Pipeline.roughCutRender` run, reported
/// through its `onProgress` callback so QueueView can show granular status
/// text ("Detecting…", "Rendering 42%") instead of one flat "Processing…".
enum PipelineStep: Equatable, Sendable {
    case detecting
    case planning
    case voicing
    /// Render encode progress, 0...1 — forwarded from RenderKit's own
    /// Encoder.export progress callback.
    case rendering(Double)

    var statusText: String {
        switch self {
        case .detecting: return "Detecting…"
        case .planning: return "Planning…"
        case .voicing: return "Voicing…"
        case .rendering(let fraction):
            return "Rendering \(Int((fraction * 100).rounded()))%"
        }
    }
}
