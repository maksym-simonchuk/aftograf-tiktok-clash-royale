import MediaKit
import PhotosUI
import SwiftUI

/// Entry screen: PHPickerViewController (via PhotosUI's PhotosPicker)
/// limited to videos. Selected items are copied into Documents/inbox/ so
/// the pipeline always works off a stable local URL — PHPicker's provided
/// URLs are only valid transiently.
struct ImportView: View {
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var importedQueue: [QueueItem]?
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(Color.crGold)

            Text("Import a Clash Royale screen recording to cut highlights on-device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            PhotosPicker(
                selection: $pickerItems,
                maxSelectionCount: BatchLimits.maxSelectionCount,
                matching: .videos
            ) {
                Label("Choose videos", systemImage: "square.and.arrow.down")
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            if isImporting {
                ProgressView("Importing…")
            }

            if let importError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(importError)
                        .font(.footnote)
                }
                .foregroundStyle(.red)
                .padding()
                .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.crBackground)
        .navigationTitle("CRCut")
        .navigationDestination(item: $importedQueue) { items in
            QueueView(items: items)
        }
        .onChange(of: pickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task { await importSelection(newItems) }
        }
    }

    private func importSelection(_ items: [PhotosPickerItem]) async {
        isImporting = true
        importError = nil
        defer { isImporting = false }

        do {
            let inbox = try Pipeline.inboxDirectory()
            var imported: [QueueItem] = []
            var writtenURLs: [URL] = []

            for item in items {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let destination = inbox
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mov")
                try data.write(to: destination, options: .atomic)
                writtenURLs.append(destination)
                let meta = try await Probe.probe(url: destination)
                imported.append(QueueItem(id: UUID(), sourceURL: destination, duration: meta.duration))
            }

            pickerItems = []

            if let violation = BatchLimits.validate(durations: imported.map(\.duration)) {
                for url in writtenURLs {
                    try? FileManager.default.removeItem(at: url)
                }
                importError = Self.batchLimitMessage(for: violation)
                return
            }

            importedQueue = imported
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
}

extension QueueItem: Hashable {
    static func == (lhs: QueueItem, rhs: QueueItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

#Preview {
    NavigationStack {
        ImportView()
    }
}
