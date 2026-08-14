import Foundation
import CryptoKit

/// Ports of `edge_tts/constants.py` -- verified byte-for-byte against a live
/// connection to speech.platform.bing.com (2026-08-13).
enum EdgeTTSConstants {
    static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    static let wssURL =
        "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
        + "?TrustedClientToken=\(trustedClientToken)"

    static let chromiumFullVersion = "143.0.3650.75"
    static let chromiumMajorVersion = "143"
    static let secMsGecVersion = "1-\(chromiumFullVersion)"

    static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko)"
        + " Chrome/\(chromiumMajorVersion).0.0.0 Safari/537.36 Edg/\(chromiumMajorVersion).0.0.0"

    static let wssHeaders: [String: String] = [
        "Pragma": "no-cache",
        "Cache-Control": "no-cache",
        "Origin": "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
        "Sec-WebSocket-Version": "13",
        "User-Agent": userAgent,
        "Accept-Encoding": "gzip, deflate, br, zstd",
        "Accept-Language": "en-US,en;q=0.9",
    ]
}

/// Port of `edge_tts/drm.py::DRM.generate_sec_ms_gec` (no clock-skew retry --
/// on 403 we simply fall back to AVSpeech like any other edge-tts failure).
enum EdgeDRM {
    private static let winEpoch: Double = 11_644_473_600

    static func secMsGec(now: Date = Date()) -> String {
        var ticks = now.timeIntervalSince1970 + winEpoch
        ticks -= ticks.truncatingRemainder(dividingBy: 300)
        let ticks100ns = ticks * 1_000_000_000 / 100
        let toHash = String(format: "%.0f", ticks100ns) + EdgeTTSConstants.trustedClientToken
        let digest = SHA256.hash(data: Data(toHash.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    static func muidCookie() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        return "muid=\(hex);"
    }

    static func connectId() -> String {
        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
}
