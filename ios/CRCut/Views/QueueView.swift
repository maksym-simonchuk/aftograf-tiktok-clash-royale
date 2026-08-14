import SwiftUI
import UIKit

/// Batch progress screen. `runPipeline` runs the full detect->plan->rough-cut
/// flow (plan §6 M3) per item — one source video in, one rendered clip out.
struct QueueView: View {
    @State var items: [QueueItem]
    @State private var selectedResult: QueueItem?

    var body: some View {
        VStack(spacing: 0) {
            if !items.isEmpty {
                Text(batchSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .padding(.vertical, 6)
            }
            List {
                ForEach(items) { item in
                    Button {
                        if case .done = item.stage {
                            selectedResult = item
                        }
                    } label: {
                        row(for: item)
                    }
                    .disabled(!isDone(item))
                    .listRowBackground(Color.white.opacity(0.06))
                }
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.crBackground)
        .navigationTitle("Queue")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Process all") {
                    Task { await runPipeline() }
                }
                .disabled(items.isEmpty || items.contains { $0.stage == .processing || $0.stage == .paused })
            }
        }
        .navigationDestination(item: $selectedResult) { item in
            ResultView(item: item)
        }
        .task {
            // Auto-start once the queue lands from ImportView.
            await runPipeline()
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
        case .processing:
            HStack(spacing: 6) {
                ProgressView()
                Text("Processing…").font(.caption).foregroundStyle(.secondary)
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
        let total = Int(items.reduce(0.0) { $0 + $1.duration })
        let count = items.count
        return "\(count) video\(count == 1 ? "" : "s") • \(total / 60)m \(total % 60)s total"
    }

    /// Keeps the screen awake for the duration of the batch — iOS won't
    /// grant background render time on demand (see plan ADR #2), so the
    /// whole run must happen in the foreground with the idle timer disabled.
    private func runPipeline() async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        for index in items.indices where items[index].stage == .queued {
            if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
                items[index].stage = .paused
                await Pipeline.waitOutThermalThrottle()
            }
            items[index].stage = .processing
            do {
                let result = try await Pipeline.roughCutRender(source: items[index].sourceURL, idx: index)
                items[index].caption = result.caption
                items[index].stage = .done(resultURL: result.url)
            } catch {
                items[index].stage = .failed(message: error.localizedDescription)
            }
        }
    }
}

#Preview {
    NavigationStack {
        QueueView(items: [])
    }
}
