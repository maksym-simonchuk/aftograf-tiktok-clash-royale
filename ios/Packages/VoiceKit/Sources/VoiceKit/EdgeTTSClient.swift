import Foundation

/// Port of `voice.py::_edge_synth` -- opens one websocket turn, sends
/// speech.config + ssml, collects binary audio frames until `turn.end`.
public actor EdgeTTSClient {
    private let transport: any EdgeTTSTransport

    public init(transport: any EdgeTTSTransport) {
        self.transport = transport
    }

    /// Returns raw mp3 bytes (24kHz/48kbps mono, per the outputFormat we request).
    public func synthesize(text: String, voice: String, rate: Int, pitch: Int) async throws -> Data {
        guard var components = URLComponents(string: EdgeTTSConstants.wssURL) else {
            throw VoiceKitError.badURL
        }
        var items = components.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "Sec-MS-GEC", value: EdgeDRM.secMsGec()),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: EdgeTTSConstants.secMsGecVersion),
            URLQueryItem(name: "ConnectionId", value: EdgeDRM.connectId()),
        ])
        components.queryItems = items
        guard let url = components.url else { throw VoiceKitError.badURL }

        var headers = EdgeTTSConstants.wssHeaders
        headers["Cookie"] = EdgeDRM.muidCookie()

        let session = try await transport.open(url: url, headers: headers)
        defer { session.close() }

        try await session.send(EdgeTTSWire.speechConfigRequest())
        let requestId = EdgeDRM.connectId()
        try await session.send(
            EdgeTTSWire.ssmlRequest(requestId: requestId, text: text, voice: voice, rate: rate, pitch: pitch)
        )

        var audio = Data()
        while true {
            switch try await session.next() {
            case .text(let header):
                if EdgeTTSWire.path(ofHeaderText: header) == "turn.end" {
                    if audio.isEmpty { throw VoiceKitError.noAudioReceived }
                    return audio
                }
            case .binary(let frame):
                audio.append(try Self.audioPayload(of: frame))
            case .closed:
                if audio.isEmpty { throw VoiceKitError.connectionClosed }
                return audio
            }
        }
    }

    /// Binary frame layout, verified live against speech.platform.bing.com:
    /// [2-byte BE header length][header bytes, ending "Path:audio\r\n"][mp3 payload].
    static func audioPayload(of frame: Data) throws -> Data {
        guard frame.count >= 2 else { throw VoiceKitError.malformedFrame }
        let bytes = [UInt8](frame)
        let headerLength = Int(bytes[0]) << 8 | Int(bytes[1])
        guard frame.count >= 2 + headerLength else { throw VoiceKitError.malformedFrame }
        return frame.subdata(in: (2 + headerLength)..<frame.count)
    }
}
