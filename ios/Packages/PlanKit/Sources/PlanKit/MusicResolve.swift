import CryptoKit
import Foundation

// Port of src/crcut/cli.py:190-228 (_resolve_music), minus the filesystem/librosa
// parts -- beat grids come pre-computed from beatgrids.json (scripts/export_beatgrids.py),
// the caller parses that JSON and passes it in. No IO here.
//
// Python's rotation offset is NOT stablePoolIndex's full-digest fold (Copy.swift):
// `int(hexdigest()[:8], 16) % n` only uses the first 8 hex chars (first 4 digest
// bytes) -- that's a plain 32-bit big-endian int, no bignum needed.
public func resolveMusic(
    fav: [String], grids: [String: [Double]], wanted: Int, seed: String = ""
) -> [(name: String, beats: [Double])] {
    let wanted = max(wanted, 1)
    let favs = fav.sorted()
    let favSet = Set(fav)
    // Python's fav folder is physically separate from the tracks folder, so a fav
    // never shows up in the rotation pool too -- exclude it here to match, even
    // though our flat grids dict has no such folder split.
    let pool = grids.keys.filter { !$0.hasPrefix("bed_") && !favSet.contains($0) }.sorted()

    if !favs.isEmpty || !pool.isEmpty {
        var picked = Array(favs.prefix(wanted))
        let remaining = wanted - picked.count
        if remaining > 0, !pool.isEmpty {
            let off = Int(rotationOffset(seed: seed) % UInt32(pool.count))
            picked += (0..<min(remaining, pool.count)).map { pool[(off + $0) % pool.count] }
        }
        return picked.map { (name: $0, beats: grids[$0] ?? []) }
    }

    // nothing dropped in: fall back to the synthesised beds (cli.py:222-228).
    let beds = grids.keys.filter { $0.hasPrefix("bed_") }.sorted()
    return beds.prefix(min(wanted, beds.count)).map { (name: $0, beats: grids[$0] ?? []) }
}

/// First 4 bytes of sha1(seed), big-endian -- `int(hexdigest()[:8], 16)`.
private func rotationOffset(seed: String) -> UInt32 {
    let digest = Insecure.SHA1.hash(data: Data(seed.utf8))
    var value: UInt32 = 0
    for byte in digest.prefix(4) {
        value = (value << 8) | UInt32(byte)
    }
    return value
}
