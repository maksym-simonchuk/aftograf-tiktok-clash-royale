import AVKit
import SwiftUI
import UIKit

/// Player + caption + save/share. Maps to plan §6 M0 goal "заглушка
/// текстовки с копированием" and R4 (in-app text, copy button, share sheet).
struct ResultView: View {
    let item: QueueItem

    @State private var player: AVPlayer?
    @State private var isSaving = false
    @State private var saveMessage: String?
    @State private var saveSucceeded = false

    var body: some View {
        VStack(spacing: 16) {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.crGold.opacity(0.35), lineWidth: 1)
                    )
            }

            ScrollView {
                Text(item.caption)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(maxHeight: 160)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = item.caption
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                ShareLink(item: item.caption) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button {
                Task { await saveToPhotos() }
            } label: {
                if isSaving {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving)

            if let saveMessage {
                if saveSucceeded {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(saveMessage)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else {
                    Text(saveMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.crBackground)
        .navigationTitle("Result")
        .onAppear {
            if case .done(let resultURL) = item.stage {
                player = AVPlayer(url: resultURL)
            }
        }
    }

    private func saveToPhotos() async {
        guard case .done(let resultURL) = item.stage else { return }
        isSaving = true
        saveMessage = nil
        saveSucceeded = false
        defer { isSaving = false }

        do {
            try await Pipeline.saveToPhotos(resultURL)
            saveMessage = "Saved to Photos."
            saveSucceeded = true
        } catch {
            saveMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack {
        ResultView(item: QueueItem(id: UUID(), sourceURL: URL(fileURLWithPath: "/tmp/x.mov")))
    }
}
