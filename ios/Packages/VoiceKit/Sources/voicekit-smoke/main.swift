import Foundation
import VoiceKit

// Manual network smoke test -- NOT run by `swift test`. Run by hand:
//   swift run voicekit-smoke
// Exercises the real edge-tts websocket against speech.platform.bing.com and
// writes the fallback-free WAV result to /tmp/voicekit-smoke.wav.

let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("voicekit-smoke-cache", isDirectory: true)
let speaker = Speaker(
    transport: URLSessionEdgeTTSTransport(),
    cache: VoiceCache(directory: cacheDir),
    onFallback: { error in print("fell back to LocalTTS: \(error)") }
)

let wav = await speaker.speak(
    text: "Привет, это проверка синтеза речи.",
    voice: "ru-RU-DmitryNeural",
    language: "ru-RU",
    style: VoiceStyles.story
)

let out = URL(fileURLWithPath: "/tmp/voicekit-smoke.wav")
try wav.write(to: out)
print("wrote \(wav.count) bytes to \(out.path)")
