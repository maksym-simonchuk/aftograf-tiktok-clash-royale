import CryptoKit
import Foundation

/// Port of `voice.py::_edge_synth`'s cache: `sha1(f"edge|{text}|{voice}|{rate}|{pitch}|{chain}")[:16]`
/// -> `vo_{key}.wav` on disk. Adds LRU eviction (voice.py has none -- iOS storage is
/// tighter than a dev machine's disk, so cap it).
public actor VoiceCache {
    public static let maxBytes: Int64 = 200 * 1024 * 1024

    private let directory: URL
    private let fm = FileManager.default
    private let maxBytes: Int64

    public init(directory: URL? = nil, maxBytes: Int64 = VoiceCache.maxBytes) {
        if let directory {
            self.directory = directory
        } else {
            let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.directory = caches.appendingPathComponent("VoiceKit", isDirectory: true)
        }
        self.maxBytes = maxBytes
        try? fm.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public static func key(text: String, voice: String, rate: Int, pitch: Int) -> String {
        let raw = "edge|\(text)|\(voice)|\(rate)|\(pitch)"
        let digest = Insecure.SHA1.hash(data: Data(raw.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    private func path(for key: String) -> URL {
        directory.appendingPathComponent("vo_\(key).wav", isDirectory: false)
    }

    /// Returns cached WAV data and refreshes its mtime (LRU touch), or nil on miss.
    public func read(_ key: String) -> Data? {
        let url = path(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    public func write(_ key: String, data: Data) {
        try? data.write(to: path(for: key))
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        var total: Int64 = 0
        var items: [(url: URL, size: Int64, mtime: Date)] = []
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let size = Int64(values.fileSize ?? 0)
            let mtime = values.contentModificationDate ?? .distantPast
            total += size
            items.append((url, size, mtime))
        }
        guard total > maxBytes else { return }

        for item in items.sorted(by: { $0.mtime < $1.mtime }) {
            if total <= maxBytes { break }
            try? fm.removeItem(at: item.url)
            total -= item.size
        }
    }
}
