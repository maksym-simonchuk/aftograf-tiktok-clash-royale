import AVFoundation
import Foundation

/// Shared mp3/PCM -> 44100Hz mono Int16 WAV helpers, used by both the edge-tts
/// path (decodes mp3) and LocalTTS (already has PCM from AVSpeechSynthesizer).
/// Matches `voice.py`'s SR = 44100.
enum AudioPCM {
    static let targetSampleRate: Double = 44_100

    static var targetFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate, channels: 1, interleaved: true)!
    }

    /// Decodes mp3 bytes via AVAudioFile (needs a real file -- AVFoundation has no
    /// in-memory mp3 decode entry point), resamples to `targetFormat`, returns WAV data.
    static func wavData(fromMP3 mp3: Data) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("mp3")
        try mp3.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        return try wavData(fromAudioFileAt: tmp)
    }

    /// Reads a PCM audio file (any format AVAudioFile understands: mp3, caf, wav)
    /// and resamples it to `targetFormat`, returning WAV data.
    static func wavData(fromAudioFileAt url: URL) throws -> Data {
        let inFile = try AVAudioFile(forReading: url)
        let buffer = try readAll(inFile)
        return try wavData(resampling: buffer, from: inFile.processingFormat)
    }

    /// Resamples an already-decoded PCM buffer (e.g. from AVSpeechSynthesizer) and
    /// returns WAV data at `targetFormat`.
    static func wavData(resampling buffer: AVAudioPCMBuffer, from sourceFormat: AVAudioFormat) throws -> Data {
        let out = targetFormat
        guard let converter = AVAudioConverter(from: sourceFormat, to: out) else {
            throw VoiceKitError.conversionFailed
        }
        // ponytail: single-shot convert(to:from:) (whole buffer already in memory,
        // no streaming loop needed) -- fine for short TTS clips; revisit if
        // VoiceKit ever speaks multi-minute audio.
        let ratio = out.sampleRate / max(sourceFormat.sampleRate, 1)
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 4096
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: outCapacity) else {
            throw VoiceKitError.conversionFailed
        }

        try converter.convert(to: outBuffer, from: buffer)

        return try writeWAV(outBuffer)
    }

    private static func readAll(_ file: AVAudioFile) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw VoiceKitError.conversionFailed
        }
        try file.read(into: buffer)
        return buffer
    }

    private static func writeWAV(_ buffer: AVAudioPCMBuffer) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("wav")
        let file = try AVAudioFile(forWriting: tmp, settings: buffer.format.settings)
        try file.write(from: buffer)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try Data(contentsOf: tmp)
    }
}
