import Foundation

public enum VoiceKitError: Error, Sendable, Equatable {
    case badURL
    case malformedFrame
    case connectionClosed
    case noAudioReceived
    case conversionFailed
    case synthesisUnavailable
}
