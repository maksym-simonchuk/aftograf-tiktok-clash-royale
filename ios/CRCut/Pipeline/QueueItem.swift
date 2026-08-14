import Foundation

/// One imported source video moving through the pipeline. Persisted (via
/// QueueStore) across launches and app kills.
struct QueueItem: Identifiable, Sendable {
    enum Stage: Equatable, Sendable {
        case queued
        case processing(PipelineStep)
        /// A4: device thermally throttled, waiting between items to cool down.
        case paused
        case done(resultURL: URL)
        case failed(message: String)
    }

    let id: UUID
    /// nil only for `.done` items recovered by QueueStore's first-launch
    /// migration, where no source file could be correlated to the output.
    let sourceURL: URL?
    var duration: Double = 0
    var stage: Stage = .queued

    /// Placeholder until Pipeline.roughCutRender finishes and overwrites this
    /// with the real title/desc_for/hashtags text (plan.py :623-816 port,
    /// cli.py:57-60 format) so ResultView has something to copy/share meanwhile.
    var caption: String

    var title: String {
        if let sourceURL {
            return sourceURL.deletingPathExtension().lastPathComponent
        }
        if case .done(let resultURL) = stage {
            return resultURL.deletingPathExtension().lastPathComponent
        }
        return "Untitled"
    }

    var isProcessing: Bool {
        if case .processing = stage { return true }
        return false
    }

    init(id: UUID, sourceURL: URL?, duration: Double = 0, stage: Stage = .queued, caption: String? = nil) {
        self.id = id
        self.sourceURL = sourceURL
        self.duration = duration
        self.stage = stage
        if let caption {
            self.caption = caption
        } else {
            let placeholderTitle = sourceURL?.deletingPathExtension().lastPathComponent ?? "clip"
            self.caption = "\(placeholderTitle)\n\nClash Royale highlights, cut on-device with CRCut.\n\n#clashroyale #cr #mobilegaming"
        }
    }
}

extension QueueItem: Hashable {
    static func == (lhs: QueueItem, rhs: QueueItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
