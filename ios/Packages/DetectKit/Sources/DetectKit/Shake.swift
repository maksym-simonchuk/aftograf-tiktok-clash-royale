import Accelerate

/// Port of `detect.py:98,101` camera-shake signal — cross-power-spectrum phase
/// correlation between consecutive Hanning-windowed frames, the same technique
/// `cv2.phaseCorrelate` uses.
///
/// SPIKE DECISION (task #3): tried `VNTranslationalImageRegistrationRequest`
/// first (the "official" API for this). On the synthetic fixture it correlated
/// only 0.34 with Python's `cv2.phaseCorrelate` shake signal and its 3 loudest
/// peaks landed at t=[3.0, 18.8, 27.0]s — nowhere near the true hits at
/// [7,14,22]s (likely tuned for feature-rich photos, not small flat-shaded
/// downscaled arenas). A from-scratch vDSP FFT phase correlation (this file)
/// correlated 0.61 with Python's signal and its top-3 peaks landed at
/// [7.0, 14.3, 22.0]s — within ~0.6s of ground truth. Went with vDSP FFT.
final class PhaseCorrelator {
    private let width: Int
    private let height: Int
    private let padW: Int
    private let padH: Int
    private let log2W: vDSP_Length
    private let log2H: vDSP_Length
    private let hannX: [Float]
    private let hannY: [Float]
    private let fftSetup: FFTSetup

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.padW = Self.nextPow2(width)
        self.padH = Self.nextPow2(height)
        self.log2W = vDSP_Length(log2(Double(padW)))
        self.log2H = vDSP_Length(log2(Double(padH)))

        var hx = [Float](repeating: 0, count: width)
        var hy = [Float](repeating: 0, count: height)
        vDSP_hann_window(&hx, vDSP_Length(width), Int32(vDSP_HANN_NORM))
        vDSP_hann_window(&hy, vDSP_Length(height), Int32(vDSP_HANN_NORM))
        self.hannX = hx
        self.hannY = hy

        guard let setup = vDSP_create_fftsetup(max(log2W, log2H), FFTRadix(kFFTRadix2)) else {
            fatalError("DetectKit.PhaseCorrelator: failed to create FFT setup")
        }
        self.fftSetup = setup
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    private static func nextPow2(_ v: Int) -> Int {
        var p = 1
        while p < v { p *= 2 }
        return max(p, 1)
    }

    private func windowedPadded(_ arena: [Float]) -> (re: [Float], im: [Float]) {
        var re = [Float](repeating: 0, count: padW * padH)
        for r in 0..<height {
            let rowBase = r * width
            let outBase = r * padW
            let wy = hannY[r]
            for c in 0..<width {
                re[outBase + c] = arena[rowBase + c] * (wy * hannX[c]).squareRoot()
            }
        }
        let im = [Float](repeating: 0, count: padW * padH)
        return (re, im)
    }

    private func fftInPlace(re: inout [Float], im: inout [Float], direction: FFTDirection) {
        re.withUnsafeMutableBufferPointer { rePtr in
            im.withUnsafeMutableBufferPointer { imPtr in
                var split = DSPSplitComplex(realp: rePtr.baseAddress!, imagp: imPtr.baseAddress!)
                vDSP_fft2d_zip(fftSetup, &split, 1, 0, log2W, log2H, direction)
            }
        }
    }

    /// Shift `(dx, dy)` that best aligns `next` onto `prev`. Only the magnitude
    /// `hypot(dx, dy)` is used downstream (matches `detect.py:102`), so sign
    /// convention doesn't matter.
    func correlate(_ prev: [Float], _ next: [Float]) -> (Double, Double) {
        var (are, aim) = windowedPadded(prev)
        var (bre, bim) = windowedPadded(next)
        fftInPlace(re: &are, im: &aim, direction: FFTDirection(kFFTDirection_Forward))
        fftInPlace(re: &bre, im: &bim, direction: FFTDirection(kFFTDirection_Forward))

        var cre = [Float](repeating: 0, count: padW * padH)
        var cim = [Float](repeating: 0, count: padW * padH)
        for i in 0..<cre.count {
            // cross-power spectrum: A * conj(B) / |A * conj(B)|
            let re = are[i] * bre[i] + aim[i] * bim[i]
            let im = aim[i] * bre[i] - are[i] * bim[i]
            let mag = max((re * re + im * im).squareRoot(), 1e-12)
            cre[i] = re / mag
            cim[i] = im / mag
        }
        fftInPlace(re: &cre, im: &cim, direction: FFTDirection(kFFTDirection_Inverse))

        var peakVal: Float = -.greatestFiniteMagnitude
        var peakIdx = 0
        for i in 0..<cre.count where cre[i] > peakVal {
            peakVal = cre[i]
            peakIdx = i
        }
        let rawPy = peakIdx / padW
        let rawPx = peakIdx % padW
        var py = rawPy
        var px = rawPx
        if px > padW / 2 { px -= padW }
        if py > padH / 2 { py -= padH }

        // cv2.phaseCorrelate refines the integer peak with a 5x5 weighted-centroid
        // (phasecorr.cpp's `weightedCentroid`) instead of returning the raw bin --
        // matches that here: gather the 5x5 neighborhood around the peak (wrapping
        // at the padded array's edges, since the correlation surface is circular)
        // and average offsets weighted by correlation value.
        var weightSum = 0.0
        var wx = 0.0
        var wy = 0.0
        for dy in -2...2 {
            let ry = ((rawPy + dy) % padH + padH) % padH
            for dx in -2...2 {
                let rx = ((rawPx + dx) % padW + padW) % padW
                let v = Double(cre[ry * padW + rx])
                weightSum += v
                wx += Double(dx) * v
                wy += Double(dy) * v
            }
        }
        let subDx = wx / (weightSum + 1e-12)
        let subDy = wy / (weightSum + 1e-12)
        return (Double(px) + subDx, Double(py) + subDy)
    }
}
