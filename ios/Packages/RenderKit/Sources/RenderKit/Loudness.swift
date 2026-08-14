import Foundation

/// Pure DSP building blocks for the M7 mix-polish pass: a ducking envelope
/// follower, a simplified ITU-R BS.1770 loudness meter, and a soft limiter.
/// Operates on plain mono Float PCM -- wiring these into the actual
/// AVAudioMix ducking + export gain is a separate step (plan §6 M7).
public enum Loudness {

    // MARK: - Ducking envelope

    /// RMS envelope follower with independent attack/release time constants
    /// (default 15ms/350ms mirrors ffmpeg's sidechaincompress attack=15:
    /// release=350 from render.py) -- fast to grab a voice onset, slow to
    /// let go so the music doesn't pump between words.
    public static func rmsEnvelope(
        samples: [Float],
        sampleRate: Double,
        attack: Double = 0.015,
        release: Double = 0.350
    ) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let attackCoeff = Float(exp(-1.0 / (sampleRate * attack)))
        let releaseCoeff = Float(exp(-1.0 / (sampleRate * release)))
        var envelope = [Float](repeating: 0, count: samples.count)
        var level: Float = 0
        for i in 0..<samples.count {
            let squared = samples[i] * samples[i]
            let coeff = squared > level ? attackCoeff : releaseCoeff
            level = coeff * level + (1 - coeff) * squared
            envelope[i] = level.squareRoot()
        }
        return envelope
    }

    // MARK: - Ducking gain

    /// Per-sample gain to apply to `music` so it ducks under `voice`, replacing
    /// render.py's ffmpeg graph:
    ///   sidechaincompress=threshold=0.03:ratio=8:attack=15:release=350:makeup=1:level_sc=2
    /// (render.py:345, params read verbatim, not from memory). NOT bit-exact
    /// with ffmpeg's internal sidechaincompress -- this is the simplified
    /// feedforward topology: smooth the (level_sc-scaled) voice via
    /// `rmsEnvelope` as the detector, then apply a static downward-compressor
    /// gain curve to each already-smoothed envelope sample. `voice` and
    /// `music` are assumed pre-aligned same-length buffers; output is sized
    /// to `music.count` and holds `makeup` gain past whichever is shorter.
    public static func duckingGain(
        voice: [Float],
        music: [Float],
        sampleRate: Double,
        threshold: Float = 0.03,
        ratio: Float = 8,
        attack: Double = 0.015,
        release: Double = 0.350,
        makeup: Float = 1,
        levelSC: Float = 2
    ) -> [Float] {
        let scaledVoice = voice.map { $0 * levelSC }
        let envelope = rmsEnvelope(samples: scaledVoice, sampleRate: sampleRate, attack: attack, release: release)
        let thresholdDB = 20 * log10f(max(threshold, 1e-9))

        var gain = [Float](repeating: makeup, count: music.count)
        for i in 0..<min(envelope.count, music.count) {
            let env = envelope[i]
            guard env > threshold else { continue }
            let envDB = 20 * log10f(env)
            let reductionDB = (envDB - thresholdDB) * (1 - 1 / ratio)
            gain[i] = powf(10, -reductionDB / 20) * makeup
        }
        return gain
    }

    // MARK: - Simplified ITU-R BS.1770 integrated loudness (LUFS)

    // ponytail: literal ITU-R BS.1770-4 Annex 1 K-weighting coefficients,
    // valid at 48kHz only (not re-derived per sample rate). Fine since the
    // render pipeline resamples everything to 48k before mixing -- re-derive
    // via the shelf/high-pass design formulas if that stops being true.
    private static let stage1: [Double] = [
        1.53512485958697, -2.69169618940638, 1.19839281085285,
        -1.69065929318241, 0.73248077421585,
    ]
    private static let stage2: [Double] = [
        1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621,
    ]

    private struct Biquad {
        let b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        init(_ c: [Double]) { (b0, b1, b2, a1, a2) = (c[0], c[1], c[2], c[3], c[4]) }
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            return y
        }
    }

    // ponytail: hand-rolled direct-form-I biquad instead of vDSP_deq22 --
    // vDSP's coefficient ordering is a common footgun and this is an O(n)
    // single pass either way; swap in vDSP if profiling ever shows it hot.
    private static func kWeighted(_ samples: [Float]) -> [Float] {
        var s1 = Biquad(stage1)
        var s2 = Biquad(stage2)
        var out = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            out[i] = Float(s2.process(s1.process(Double(samples[i]))))
        }
        return out
    }

    private static func meanSquare(_ x: ArraySlice<Float>) -> Float {
        var sum: Float = 0
        for v in x { sum += v * v }
        return sum / Float(x.count)
    }

    /// Integrated loudness in LUFS. "Simplified": absolute gate (-70 LUFS)
    /// only, no relative (-10 LU) gate stage -- enough to hit a static export
    /// gain target, not meant to reproduce ffmpeg's loudnorm bit-for-bit.
    public static func integratedLUFS(samples: [Float], sampleRate: Double) -> Float {
        guard !samples.isEmpty else { return -Float.infinity }
        let weighted = kWeighted(samples)
        let blockSize = Int(0.4 * sampleRate)   // 400ms
        let hop = Int(0.1 * sampleRate)         // 100ms (75% overlap)

        guard blockSize > 0, weighted.count >= blockSize else {
            let z = meanSquare(weighted[...])
            return -0.691 + 10 * log10f(max(z, 1e-12))
        }

        var gatedPower: [Float] = []
        var start = 0
        while start + blockSize <= weighted.count {
            let z = meanSquare(weighted[start..<start + blockSize])
            let blockLUFS = -0.691 + 10 * log10f(max(z, 1e-12))
            if blockLUFS > -70 { gatedPower.append(z) }
            start += hop
        }
        guard !gatedPower.isEmpty else { return -70 }
        let meanZ = gatedPower.reduce(0, +) / Float(gatedPower.count)
        return -0.691 + 10 * log10f(max(meanZ, 1e-12))
    }

    // MARK: - Soft limiter

    /// Soft-knee limiter: identity below the knee, asymptotically approaches
    /// `ceilingDB` above it (tanh saturation) -- never hard-clips, always
    /// stays strictly under the ceiling.
    public static func softLimit(_ samples: [Float], ceilingDB: Float = -1.5) -> [Float] {
        let ceiling = powf(10, ceilingDB / 20)
        let knee = ceiling * 0.7
        let range = ceiling - knee
        return samples.map { x in
            let mag = abs(x)
            guard mag > knee else { return x }
            let limitedMag = knee + range * tanhf((mag - knee) / range)
            return x < 0 ? -limitedMag : limitedMag
        }
    }
}
