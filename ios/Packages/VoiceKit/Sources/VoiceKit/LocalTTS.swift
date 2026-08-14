import AVFoundation
import Foundation

/// Offline fallback when edge-tts is unreachable (no network, DRM rejected, etc).
/// Port of the intent behind `voice.py::_speak_say` (macOS `say`) using the
/// iOS/macOS-native `AVSpeechSynthesizer` instead, since `say` doesn't exist on iOS.
public enum LocalTTS {
    static let ruVoiceIdentifierPrefix = "ru-RU"
    static let enVoiceIdentifierPrefix = "en-US"

    /// Renders `text` and returns 44100Hz mono Int16 WAV data.
    public static func synthesize(text: String, language: String, style: VoiceStyle) async throws -> Data {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestVoice(forLanguagePrefix: language)
        // ponytail: heuristic mapping from edge-tts rate%/pitchHz to AVSpeech's
        // 0...1 rate / 0.5...2.0 pitch -- uncalibrated by ear, tune once VoiceKit
        // audio is reviewed against real edge-tts output.
        let rateFraction: Double = Double(style.edgeRate) / 100.0
        let defaultRate: Double = Double(AVSpeechUtteranceDefaultSpeechRate)
        var rate: Double = defaultRate * (1 + rateFraction)
        rate = min(rate, 1.0)
        rate = max(rate, 0.1)
        utterance.rate = Float(rate)

        let pitchOctaves: Double = Double(style.edgePitch) / 12.0
        var pitch: Double = pow(2.0, pitchOctaves)
        pitch = min(pitch, 2.0)
        pitch = max(pitch, 0.5)
        utterance.pitchMultiplier = Float(pitch)

        let synthesizer = AVSpeechSynthesizer()
        let fileURL = try await renderToFile(utterance: utterance, synthesizer: synthesizer)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        return try AudioPCM.wavData(fromAudioFileAt: fileURL)
    }

    static func bestVoice(forLanguagePrefix prefix: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        let byQuality = candidates.sorted { lhs, rhs in
            quality(lhs.quality) > quality(rhs.quality)
        }
        return byQuality.first ?? AVSpeechSynthesisVoice(language: prefix)
    }

    private static func quality(_ q: AVSpeechSynthesisVoiceQuality) -> Int {
        switch q {
        case .premium: return 2
        case .enhanced: return 1
        default: return 0
        }
    }

    /// Writes each rendered buffer straight to a temp audio file as it arrives, so
    /// only the file `URL` (Sendable) crosses the continuation -- `AVAudioPCMBuffer`
    /// itself never does.
    private static func renderToFile(
        utterance: AVSpeechUtterance,
        synthesizer: AVSpeechSynthesizer
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("caf")
        return try await withCheckedThrowingContinuation { continuation in
            var audioFile: AVAudioFile?
            var wroteAny = false
            var didResume = false
            synthesizer.write(utterance) { avAudioBuffer in
                guard !didResume, let pcm = avAudioBuffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    didResume = true
                    if wroteAny {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: VoiceKitError.synthesisUnavailable)
                    }
                    return
                }
                do {
                    let file = try audioFile ?? AVAudioFile(forWriting: url, settings: pcm.format.settings)
                    audioFile = file
                    try file.write(from: pcm)
                    wroteAny = true
                } catch {
                    didResume = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
