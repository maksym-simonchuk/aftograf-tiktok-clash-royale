import Foundation

/// One imported source video moving through the pipeline.
/// M0: passthrough only (no detection/plan/render yet — those land in M1-M3).
struct QueueItem: Identifiable {
    enum Stage: Equatable {
        case queued
        case processing
        /// A4: device thermally throttled, waiting between items to cool down.
        case paused
        case done(resultURL: URL)
        case failed(message: String)
    }

    let id: UUID
    let sourceURL: URL
    var duration: Double = 0
    var stage: Stage = .queued

    /// Placeholder until Pipeline.roughCutRender finishes and overwrites this
    /// with the real title/desc_for/hashtags text (plan.py :623-816 port,
    /// cli.py:57-60 format) so ResultView has something to copy/share meanwhile.
    var caption: String

    var title: String {
        sourceURL.deletingPathExtension().lastPathComponent
    }

    init(id: UUID, sourceURL: URL, duration: Double = 0, stage: Stage = .queued) {
        self.id = id
        self.sourceURL = sourceURL
        self.duration = duration
        self.stage = stage
        let placeholderTitle = sourceURL.deletingPathExtension().lastPathComponent
        self.caption = "\(placeholderTitle)\n\nClash Royale highlights, cut on-device with CRCut.\n\n#clashroyale #cr #mobilegaming"
    }
}
