import Foundation

/// Transport abstraction over the edge-tts websocket protocol so tests never touch
/// the network. `URLSessionEdgeTTSTransport` is the real implementation;
/// `MockEdgeTTSTransport` (test target) replays canned frame sequences.
public protocol EdgeTTSTransport: Sendable {
    func open(url: URL, headers: [String: String]) async throws -> any EdgeTTSSession
}

public protocol EdgeTTSSession: Sendable {
    func send(_ text: String) async throws
    func next() async throws -> EdgeTTSFrame
    func close()
}

public enum EdgeTTSFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)
    case closed
}

/// SSML / request-frame construction -- port of `edge_tts/communicate.py`'s
/// `mkssml`, `ssml_headers_plus_data`, and the two request builders inside
/// `Communicate.__stream`. Text is assumed short (captions/adlibs, never the
/// 4096-byte chunking edge-tts needs for long documents).
/// ponytail: no chunking, add if VoiceKit ever speaks paragraph-length text.
enum EdgeTTSWire {
    static func fullVoiceName(_ voiceId: String) -> String {
        // `ru-RU-DmitryNeural` -> "Microsoft Server Speech Text to Speech Voice (ru-RU, DmitryNeural)"
        let parts = voiceId.split(separator: "-", maxSplits: 2)
        guard parts.count == 3 else { return voiceId }
        return "Microsoft Server Speech Text to Speech Voice (\(parts[0])-\(parts[1]), \(parts[2]))"
    }

    static func escapeXML(_ text: String) -> String {
        var cleaned = ""
        cleaned.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            let code = scalar.value
            if (0...8).contains(code) || (11...12).contains(code) || (14...31).contains(code) {
                cleaned.unicodeScalars.append(" ")
            } else {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        return cleaned
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func ssml(text: String, voice: String, rate: Int, pitch: Int) -> String {
        let voiceName = fullVoiceName(voice)
        let rateStr = String(format: "%+d%%", rate)
        let pitchStr = String(format: "%+dHz", pitch)
        return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
            + "<voice name='\(voiceName)'>"
            + "<prosody pitch='\(pitchStr)' rate='\(rateStr)' volume='+0%'>"
            + escapeXML(text)
            + "</prosody></voice></speak>"
    }

    static func dateHeaderString(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss"
        return formatter.string(from: now) + " GMT+0000 (Coordinated Universal Time)"
    }

    static func speechConfigRequest() -> String {
        "X-Timestamp:\(dateHeaderString())\r\n"
            + "Content-Type:application/json; charset=utf-8\r\n"
            + "Path:speech.config\r\n\r\n"
            + "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{"
            + "\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},"
            + "\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}\r\n"
    }

    static func ssmlRequest(requestId: String, text: String, voice: String, rate: Int, pitch: Int) -> String {
        "X-RequestId:\(requestId)\r\n"
            + "Content-Type:application/ssml+xml\r\n"
            + "X-Timestamp:\(dateHeaderString())Z\r\n"
            + "Path:ssml\r\n\r\n"
            + ssml(text: text, voice: voice, rate: rate, pitch: pitch)
    }

    /// The `Path:` header value of a text/binary-header frame. Deliberately does not
    /// replicate the reference Python client's off-by-two slice quirk (verified live:
    /// harmless there only because json.loads tolerates leading whitespace) -- this
    /// reads the header block cleanly instead.
    static func path(ofHeaderText header: String) -> String? {
        let headerOnly = header.components(separatedBy: "\r\n\r\n").first ?? header
        for line in headerOnly.components(separatedBy: "\r\n") where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[line.startIndex..<colon] == "Path" {
                return String(line[line.index(after: colon)...])
            }
        }
        return nil
    }
}
