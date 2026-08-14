import Foundation

/// Public entry point -- port of `voice.py::speak()`. Cache -> edge-tts -> on any
/// error, local fallback -> always cache the result under the requested key.
public struct Speaker: Sendable {
    /// Matches `LocalTTS.synthesize`'s signature. Injectable so tests never touch
    /// the real `AVSpeechSynthesizer` (offline, but slow/service-dependent).
    public typealias LocalSynthesize = @Sendable (_ text: String, _ language: String, _ style: VoiceStyle) async throws -> Data

    private let client: EdgeTTSClient
    private let cache: VoiceCache
    private let onFallback: (@Sendable (Error) -> Void)?
    private let localSynthesize: LocalSynthesize

    public init(
        transport: any EdgeTTSTransport,
        cache: VoiceCache,
        onFallback: (@Sendable (Error) -> Void)? = nil,
        localSynthesize: @escaping LocalSynthesize = LocalTTS.synthesize
    ) {
        self.client = EdgeTTSClient(transport: transport)
        self.cache = cache
        self.onFallback = onFallback
        self.localSynthesize = localSynthesize
    }

    /// Returns 44100Hz mono Int16 WAV data for `text`, spoken in `style` using the
    /// edge-tts voice `voice` (e.g. "ru-RU-DmitryNeural"); falls back to
    /// AVSpeechSynthesizer's closest voice for `language` (e.g. "ru-RU") on failure.
    public func speak(text: String, voice: String, language: String, style: VoiceStyle) async -> Data {
        let (rate, pitch) = EdgeRecipe.rateAndPitch(style: style, text: text)
        let key = VoiceCache.key(text: text, voice: voice, rate: rate, pitch: pitch)

        if let cached = await cache.read(key) {
            return cached
        }

        let wav: Data
        do {
            let mp3 = try await client.synthesize(text: text, voice: voice, rate: rate, pitch: pitch)
            wav = try AudioPCM.wavData(fromMP3: mp3)
        } catch {
            onFallback?(error)
            wav = (try? await localSynthesize(text, language, style)) ?? Data()
        }

        if !wav.isEmpty {
            await cache.write(key, data: wav)
        }
        return wav
    }
}
