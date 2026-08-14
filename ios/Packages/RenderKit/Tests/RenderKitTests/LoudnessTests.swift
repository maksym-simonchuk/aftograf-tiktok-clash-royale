import Foundation
import Testing
@testable import RenderKit

@Suite struct LoudnessTests {
    private let sr: Double = 48000

    private func sineWave(amplitude: Float, freq: Float, seconds: Double, sampleRate: Double) -> [Float] {
        let n = Int(seconds * sampleRate)
        let omega = 2 * Float.pi * freq / Float(sampleRate)
        return (0..<n).map { i -> Float in
            let phase: Float = omega * Float(i)
            return amplitude * sinf(phase)
        }
    }

    @Test func toneMeasuresApproximatelyTargetLUFS() {
        let targetLUFS: Float = -23
        // 500Hz sits well above the RLB highpass corner (~38Hz) and well
        // below the K-weighting shelf corner (~1.68kHz), so K-weighted gain
        // there is close to 0dB and the analytic full-scale-sine formula
        // (mean square = amplitude^2 / 2) holds within tolerance.
        let amplitude = sqrtf(2 * powf(10, (targetLUFS + 0.691) / 10))
        let samples = sineWave(amplitude: amplitude, freq: 500, seconds: 2.0, sampleRate: sr)

        let measured = Loudness.integratedLUFS(samples: samples, sampleRate: sr)

        #expect(abs(measured - targetLUFS) <= 0.5)
    }

    @Test func envelopeAttackIsFastAndReleaseIsSlow() {
        let musicLevel: Float = 0.1
        let voiceLevel: Float = 0.6
        let burstStart = 0.5
        let burstDuration = 0.2
        let total = 1.0

        let n = Int(total * sr)
        var samples = [Float](repeating: musicLevel, count: n)
        let burstStartIdx = Int(burstStart * sr)
        let burstEndIdx = Int((burstStart + burstDuration) * sr)
        for i in burstStartIdx..<burstEndIdx { samples[i] = voiceLevel }

        let envelope = Loudness.rmsEnvelope(samples: samples, sampleRate: sr, attack: 0.015, release: 0.350)

        // ~15ms (one attack time constant) after onset, envelope should have
        // moved most of the way from the music floor toward the voice level.
        let afterAttack = burstStartIdx + Int(0.015 * sr)
        #expect(envelope[afterAttack] > musicLevel + (voiceLevel - musicLevel) * 0.5)

        // ~15ms after the burst ends, release (350ms) hasn't caught up yet --
        // envelope should still be close to the voice level, not back near the floor.
        let afterRelease = burstEndIdx + Int(0.015 * sr)
        #expect(envelope[afterRelease] > voiceLevel * 0.8)
    }

    @Test func softLimiterKeepsFullScalePeaksUnderCeiling() {
        let samples = sineWave(amplitude: 1.0, freq: 1000, seconds: 0.1, sampleRate: sr)

        let limited = Loudness.softLimit(samples, ceilingDB: -1.5)

        let ceiling = powf(10, -1.5 / 20)
        let peak = limited.map { abs($0) }.max() ?? 0
        #expect(peak <= ceiling)

        // below the knee, signal should pass through untouched
        let quiet: Float = 0.05
        #expect(Loudness.softLimit([quiet], ceilingDB: -1.5)[0] == quiet)
    }

    @Test func duckingGainStaysUnityWithoutVoice() {
        let n = Int(0.5 * sr)
        let voice = [Float](repeating: 0, count: n)
        let music = [Float](repeating: 0.3, count: n)

        let gain = Loudness.duckingGain(voice: voice, music: music, sampleRate: sr)

        #expect(gain.allSatisfy { abs($0 - 1.0) < 1e-6 })
    }

    @Test func duckingGainDipsOnAttackAndRecoversOnRelease() {
        let musicLevel: Float = 0.3
        let voiceLevel: Float = 0.1
        let burstStart = 0.3
        let burstDuration = 0.2
        let total = 2.5

        let n = Int(total * sr)
        var voice = [Float](repeating: 0, count: n)
        let music = [Float](repeating: musicLevel, count: n)
        let burstStartIdx = Int(burstStart * sr)
        let burstEndIdx = Int((burstStart + burstDuration) * sr)
        for i in burstStartIdx..<burstEndIdx { voice[i] = voiceLevel }

        let gain = Loudness.duckingGain(voice: voice, music: music, sampleRate: sr)

        // before the burst: untouched
        #expect(abs(gain[burstStartIdx - 1] - 1.0) < 1e-3)

        // steady-state dip, well after attack has settled, must be a real
        // reduction (music "gets out of the way" -- 6-10dB in the plan's
        // acceptance language for a typical spoken level).
        let settled = burstStartIdx + Int(0.1 * sr)
        let dipDB = -20 * log10f(gain[settled])
        #expect(dipDB > 3)

        // within one attack window (~15ms) of onset, gain has already moved
        // meaningfully off unity -- it doesn't wait for the full burst.
        let afterAttack = burstStartIdx + Int(0.015 * sr)
        #expect(gain[afterAttack] < 1.0 - (1.0 - gain[settled]) * 0.3)

        // release is a one-pole decay of the *squared* level, so the
        // (square-rooted) envelope decays with an *effective* time constant
        // of 2*release, not release. Full recovery to exact unity gain only
        // happens once that decaying envelope drops back under `threshold`
        // (0.03), at t = 2*release*ln(peakEnvelope/threshold) after the
        // burst ends -- derived here from the same defaults duckingGain
        // uses, so the check stays correct if those defaults ever move.
        let defaultRelease = 0.350
        let defaultThreshold: Float = 0.03
        let scaledVoicePeak = voiceLevel * 2  // default levelSC
        let crossing = 2 * defaultRelease * Double(logf(scaledVoicePeak / defaultThreshold))

        // partway through the decay: recovering, but not there yet.
        let midRecovery = burstEndIdx + Int(crossing * 0.5 * sr)
        #expect(gain[midRecovery] > gain[settled])
        #expect(gain[midRecovery] < 0.95)

        // comfortably past the crossing point: fully back to unity.
        let fullyRecovered = burstEndIdx + Int(crossing * 1.3 * sr)
        #expect(gain[fullyRecovered] > 0.95)
    }

    @Test func duckingGainDepthMatchesThresholdRatioArithmetic() {
        let voiceLevel: Float = 0.1
        let n = Int(0.6 * sr)
        let voice = [Float](repeating: voiceLevel, count: n)
        let music = [Float](repeating: 0.3, count: n)

        let threshold: Float = 0.03, ratio: Float = 8, levelSC: Float = 2
        let gain = Loudness.duckingGain(
            voice: voice, music: music, sampleRate: sr,
            threshold: threshold, ratio: ratio, makeup: 1, levelSC: levelSC
        )

        // constant input -> envelope fully settles; check well past attack.
        let measuredDB = 20 * log10f(gain[n - 1])

        let envDB = 20 * log10f(voiceLevel * levelSC)
        let threshDB = 20 * log10f(threshold)
        let expectedReductionDB = (envDB - threshDB) * (1 - 1 / ratio)

        #expect(abs(measuredDB - (-expectedReductionDB)) < 0.5)
    }
}
