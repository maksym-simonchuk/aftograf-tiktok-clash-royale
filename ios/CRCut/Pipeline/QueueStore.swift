import Foundation
import MediaKit
import PhotosUI
import SwiftUI

/// Single source of truth for the persistent queue. Backs Documents/queue.json
/// (file NAMES only — never absolute paths, since the app container's UUID
/// changes on reinstall) and owns the PhotosPicker import flow that used to
/// live in the now-removed ImportView.
@MainActor
@Observable
final class QueueStore {
    private(set) var items: [QueueItem] = []
    var importError: String?

    private let fileManager = FileManager.default

    init() {
        if let manifest = Self.readManifest() {
            items = reconcile(manifest.items)
        } else {
            Task { await self.runFirstLaunchMigration() }
        }
    }

    // MARK: - Mutation

    /// Deletes an item and its on-disk files. No-op while it's mid-render.
    func remove(_ item: QueueItem) {
        guard !item.isProcessing else { return }
        items.removeAll { $0.id == item.id }
        if let sourceURL = item.sourceURL {
            try? fileManager.removeItem(at: sourceURL)
        }
        if case .done(let resultURL) = item.stage {
            try? fileManager.removeItem(at: resultURL)
        }
        save()
    }

    func updateStage(id: UUID, _ stage: QueueItem.Stage) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let oldStage = items[idx].stage
        items[idx].stage = stage
        // .processing -> .processing (progress ticks, ~3/sec) persists as
        // .queued either way (see `persist` below) -- skip the redundant write.
        if case .processing = oldStage, case .processing = stage { return }
        save()
    }

    func setResult(id: UUID, url: URL, caption: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].caption = caption
        items[idx].stage = .done(resultURL: url)
        save()
    }

    // MARK: - Import (moved from the removed ImportView)

    /// Copies each picked video into Documents/inbox/ (PHPicker's own URLs
    /// are only valid transiently) and appends it to the existing queue.
    /// Validates only the NEW batch against BatchLimits, per plan §M8 — the
    /// already-queued items don't count against it.
    func importSelection(_ pickerItems: [PhotosPickerItem]) async {
        importError = nil
        do {
            let inbox = try Pipeline.inboxDirectory()
            var imported: [QueueItem] = []
            var writtenURLs: [URL] = []

            for pickerItem in pickerItems {
                guard let data = try await pickerItem.loadTransferable(type: Data.self) else { continue }
                let destination = inbox
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mov")
                try data.write(to: destination, options: .atomic)
                writtenURLs.append(destination)
                let meta = try await Probe.probe(url: destination)
                imported.append(QueueItem(id: UUID(), sourceURL: destination, duration: meta.duration))
            }

            if let violation = BatchLimits.validate(durations: imported.map(\.duration)) {
                for url in writtenURLs {
                    try? fileManager.removeItem(at: url)
                }
                importError = Self.batchLimitMessage(for: violation)
                return
            }

            items.append(contentsOf: imported)
            save()
        } catch {
            importError = error.localizedDescription
        }
    }

    private static func batchLimitMessage(for violation: BatchLimits.Violation) -> String {
        let totalMinutes = violation.totalDuration / 60
        let limitMinutes = BatchLimits.maxTotalDuration / 60
        return String(
            format: "Selected %d videos totaling %.1f min — batch limit is %.0f min. Remove some clips and try again.",
            violation.selectedCount, totalMinutes, limitMinutes
        )
    }

    // MARK: - First-launch migration

    /// Documents/inbox and Documents/out predate QueueStore (M0-M3 dropped
    /// files straight there with no manifest) — the very first launch after
    /// this change picks up whatever is already sitting in them instead of
    /// silently losing it.
    private func runFirstLaunchMigration() async {
        var migrated: [QueueItem] = []

        if let outDir = try? Pipeline.outputDirectory(),
            let outFiles = try? fileManager.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil) {
            for url in outFiles where url.pathExtension.lowercased() == "mov" {
                let placeholderTitle = url.deletingPathExtension().lastPathComponent
                let caption = "\(placeholderTitle)\n\nClash Royale highlights, cut on-device with CRCut.\n\n#clashroyale #cr #mobilegaming"
                migrated.append(QueueItem(id: UUID(), sourceURL: nil, stage: .done(resultURL: url), caption: caption))
            }
        }

        if let inboxDir = try? Pipeline.inboxDirectory(),
            let inboxFiles = try? fileManager.contentsOfDirectory(at: inboxDir, includingPropertiesForKeys: nil) {
            for url in inboxFiles where url.pathExtension.lowercased() == "mov" {
                let duration = (try? await Probe.probe(url: url).duration) ?? 0
                migrated.append(QueueItem(id: UUID(), sourceURL: url, duration: duration))
            }
        }

        items = migrated
        save()
    }

    // MARK: - Persistence

    private struct Manifest: Codable {
        var items: [PersistedItem]
    }

    private struct PersistedItem: Codable {
        enum Status: String, Codable {
            case queued, done, failed
        }

        let id: UUID
        /// Name only, relative to Documents/inbox — "" when unknown (see
        /// QueueItem.sourceURL). Never an absolute path.
        let sourceFileName: String
        let duration: Double
        let caption: String
        let status: Status
        /// Name only, relative to Documents/out.
        let resultFileName: String?
        let failureMessage: String?
    }

    private static func manifestURL() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return documents.appendingPathComponent("queue.json")
    }

    private static func readManifest() -> Manifest? {
        guard let url = try? manifestURL(),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private func save() {
        guard let url = try? Self.manifestURL() else { return }
        let persisted = items.map(Self.persist)
        guard let data = try? JSONEncoder().encode(Manifest(items: persisted)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// processing/paused persist as queued — they resume from the top of
    /// their pipeline on relaunch rather than mid-stage.
    private static func persist(_ item: QueueItem) -> PersistedItem {
        let sourceFileName = item.sourceURL?.lastPathComponent ?? ""
        switch item.stage {
        case .queued, .processing, .paused:
            return PersistedItem(
                id: item.id, sourceFileName: sourceFileName, duration: item.duration,
                caption: item.caption, status: .queued, resultFileName: nil, failureMessage: nil
            )
        case .done(let resultURL):
            return PersistedItem(
                id: item.id, sourceFileName: sourceFileName, duration: item.duration,
                caption: item.caption, status: .done, resultFileName: resultURL.lastPathComponent, failureMessage: nil
            )
        case .failed(let message):
            return PersistedItem(
                id: item.id, sourceFileName: sourceFileName, duration: item.duration,
                caption: item.caption, status: .failed, resultFileName: nil, failureMessage: message
            )
        }
    }

    /// Resolves persisted file names against the CURRENT Documents directory
    /// (never trusts a stored absolute path) and drops anything whose file
    /// no longer exists.
    private func reconcile(_ persisted: [PersistedItem]) -> [QueueItem] {
        guard let inboxDir = try? Pipeline.inboxDirectory(),
            let outDir = try? Pipeline.outputDirectory()
        else { return [] }

        return persisted.compactMap { entry -> QueueItem? in
            var sourceURL: URL?
            if !entry.sourceFileName.isEmpty {
                let candidate = inboxDir.appendingPathComponent(entry.sourceFileName)
                guard fileManager.fileExists(atPath: candidate.path) else { return nil }
                sourceURL = candidate
            }

            switch entry.status {
            case .queued:
                guard sourceURL != nil else { return nil }
                return QueueItem(
                    id: entry.id, sourceURL: sourceURL, duration: entry.duration,
                    stage: .queued, caption: entry.caption
                )
            case .failed:
                return QueueItem(
                    id: entry.id, sourceURL: sourceURL, duration: entry.duration,
                    stage: .failed(message: entry.failureMessage ?? "Unknown error"), caption: entry.caption
                )
            case .done:
                guard let resultFileName = entry.resultFileName else { return nil }
                let resultURL = outDir.appendingPathComponent(resultFileName)
                guard fileManager.fileExists(atPath: resultURL.path) else { return nil }
                return QueueItem(
                    id: entry.id, sourceURL: sourceURL, duration: entry.duration,
                    stage: .done(resultURL: resultURL), caption: entry.caption
                )
            }
        }
    }
}

/// @Observable's registrar (ObservationRegistrar) is itself Sendable, and
/// every mutable access below only ever happens on MainActor (the class is
/// globally isolated to it) — safe to hand a reference across into
/// Pipeline's plain @Sendable onProgress closures, which always hop back via
/// `Task { @MainActor in ... }` before touching it.
extension QueueStore: @unchecked Sendable {}
