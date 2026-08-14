import PhotosUI
import SwiftUI
import UIKit

/// Root screen: persistent queue, backed by QueueStore. Import via the "+"
/// toolbar button; render via Start/Stop, one Task handle at a time so the
/// user can cancel a running batch without losing already-finished items.
struct QueueView: View {
    let store: QueueStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var selectedResult: QueueItem?
    @State private var runTask: Task<Void, Never>?
    /// Set by the Stop button; cleared by Start. Every auto-start path
    /// (launch, post-import, return to foreground) respects it.
    @State private var userStopped = false

    private var isRunning: Bool { runTask != nil }
    private var hasQueued: Bool {
        store.items.contains { if case .queued = $0.stage { return true } else { return false } }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !store.items.isEmpty {
                Text(batchSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .padding(.vertical, 6)
            }

            if isImporting {
                ProgressView("Importing…")
                    .padding(.vertical, 6)
            }

            if let importError = store.importError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(importError)
                        .font(.footnote)
                }
                .foregroundStyle(.red)
                .padding()
                .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.bottom, 6)
            }

            List {
                ForEach(store.items) { item in
                    Button {
                        if case .done = item.stage {
                            selectedResult = item
                        }
                    } label: {
                        row(for: item)
                    }
                    .disabled(!isDone(item))
                    .listRowBackground(Color.white.opacity(0.06))
                    .swipeActions {
                        if !item.isProcessing {
                            Button(role: .destructive) {
                                store.remove(item)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)

            Text("Rendering runs while the app is open")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.crBackground)
        .navigationTitle("Queue")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: BatchLimits.maxSelectionCount,
                    matching: .videos
                ) {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if isRunning {
                    Button {
                        stop()
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                } else {
                    Button {
                        start()
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .disabled(!hasQueued)
                }
            }
        }
        .navigationDestination(item: $selectedResult) { item in
            ResultView(item: item)
        }
        .onChange(of: pickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                isImporting = true
                await store.importSelection(newItems)
                isImporting = false
                pickerItems = []
                if !userStopped { start() }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active, !userStopped, !isRunning, hasQueued {
                start()
            }
        }
        .onChange(of: hasQueued) { _, has in
            if has, !userStopped, !isRunning {
                start()
            }
        }
        .task {
            // Autostart once on launch, same as before, but now over a
            // persistent queue instead of a fresh batch from ImportView.
            if !userStopped, hasQueued {
                start()
            }
        }
    }

    @ViewBuilder
    private func row(for item: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.title)
                Spacer()
                statusView(for: item.stage)
            }
            if case .failed(let message) = item.stage {
                // .help() is a macOS tooltip -- it renders nothing on iOS,
                // so the failure reason needs its own visible line here.
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func statusView(for stage: QueueItem.Stage) -> some View {
        switch stage {
        case .queued:
            statusCapsule("Queued")
        case .processing(let step):
            HStack(spacing: 6) {
                ProgressView()
                Text(step.statusText).font(.caption).foregroundStyle(.secondary)
            }
        case .paused:
            HStack(spacing: 6) {
                Image(systemName: "thermometer.sun").foregroundStyle(.orange)
                Text("Cooling down…").font(.caption).foregroundStyle(.orange)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func statusCapsule(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private func isDone(_ item: QueueItem) -> Bool {
        if case .done = item.stage { return true }
        return false
    }

    private var batchSummary: String {
        let total = Int(store.items.reduce(0.0) { $0 + $1.duration })
        let count = store.items.count
        return "\(count) video\(count == 1 ? "" : "s") • \(total / 60)m \(total % 60)s total"
    }

    private func start() {
        guard runTask == nil else { return }
        userStopped = false
        runTask = Task { await runQueue() }
    }

    private func stop() {
        userStopped = true
        runTask?.cancel()
    }

    /// Keeps the screen awake for the duration of the batch — iOS won't
    /// grant background render time on demand (see plan ADR #2), so the
    /// whole run must happen in the foreground with the idle timer disabled.
    private func runQueue() async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            runTask = nil
        }

        while let next = store.items.first(where: { if case .queued = $0.stage { return true } else { return false } }) {
            if Task.isCancelled { break }
            await process(next)
            if UIApplication.shared.applicationState != .active { break }
            if Task.isCancelled { break }
        }
    }

    private func process(_ item: QueueItem) async {
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            store.updateStage(id: item.id, .paused)
            await Pipeline.waitOutThermalThrottle()
            if Task.isCancelled {
                store.updateStage(id: item.id, .queued)
                return
            }
        }

        guard let sourceURL = item.sourceURL else {
            store.updateStage(id: item.id, .failed(message: "Missing source file."))
            return
        }

        // Extends our run past a backgrounding for as long as iOS grants —
        // roughCutRender itself still requires the foreground idle-timer
        // lock above to make real progress (ADR #2), this just avoids an
        // instant hard-suspend mid-item.
        let bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "cr-render-\(item.id.uuidString)")
        defer { UIApplication.shared.endBackgroundTask(bgTaskID) }

        let idx = store.items.firstIndex(where: { $0.id == item.id }) ?? 0
        store.updateStage(id: item.id, .processing(.detecting))
        do {
            let result = try await Pipeline.roughCutRender(source: sourceURL, idx: idx) { step in
                Task { @MainActor in
                    store.updateStage(id: item.id, .processing(step))
                }
            }
            store.setResult(id: item.id, url: result.url, caption: result.caption)
        } catch is CancellationError {
            store.updateStage(id: item.id, .queued)
        } catch {
            if UIApplication.shared.applicationState != .active {
                store.updateStage(id: item.id, .queued)
            } else {
                store.updateStage(id: item.id, .failed(message: error.localizedDescription))
            }
        }
    }
}

#Preview {
    NavigationStack {
        QueueView(store: QueueStore())
    }
}
