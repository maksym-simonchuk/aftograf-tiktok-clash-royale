import AVFoundation
import Foundation

/// Whole-frame grayscale sample, analogous to a numpy array of shape `(T, H, W)`
/// (`media.py:108-112` `sample_gray`). Row-major, frame-major: byte `t*height*width
/// + row*width + col`.
public struct GrayFrames: Sendable {
    public let count: Int
    public let height: Int
    public let width: Int
    public let data: [UInt8]

    public init(count: Int, height: Int, width: Int, data: [UInt8]) {
        precondition(data.count == count * height * width, "GrayFrames: data size mismatch")
        self.count = count
        self.height = height
        self.width = width
        self.data = data
    }

    /// Frame `t`, row-major `height*width` bytes.
    public func frame(_ t: Int) -> ArraySlice<UInt8> {
        let start = t * height * width
        return data[start..<(start + height * width)]
    }
}

/// Port of `media.py:93-112` (`_decode_gray` / `sample_gray`) — decodes a video
/// to a downscaled grayscale frame sample via `AVAssetReader` instead of piping
/// raw video out of ffmpeg.
public enum FrameSampler {
    /// - Parameters:
    ///   - fps: target sample rate. Frames are picked to the nearest source
    ///     frame on this time grid, mirroring ffmpeg's `fps` filter default
    ///     rounding (`round=near`).
    ///   - width: target sample width; height is derived from the source aspect
    ///     ratio and rounded to the nearest even number, like `media.py`'s `_even`.
    public static func sampleGray(url: URL, fps: Double = 10.0, width: Int = 160) async throws -> GrayFrames {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideoTrack("no video stream in \(url.path)")
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)

        var srcW = Int(naturalSize.width.rounded())
        var srcH = Int(naturalSize.height.rounded())
        if Probe.rotationDegrees(transform) % 180 == 90 {
            swap(&srcW, &srcH)
        }

        let outW = evenSize(Double(width))
        let outH = evenSize(Double(srcH) * Double(outW) / Double(srcW))

        let reader = try AVAssetReader(asset: asset)
        // Full-range biplanar luma, not `OneComponent8`: `OneComponent8` hands
        // back AVFoundation's tone-mapped/legal-range luma verbatim, which
        // caps well short of the 0-255 media.py/ffmpeg (`format=gray`)
        // decodes to -- silently zeroing the flash signal's `>240` bright-pixel
        // cutoff (detect.py:93). Requesting FullRange explicitly makes
        // AVFoundation do the legal-to-full conversion itself; we just read
        // the Y plane (plane 0) back untouched.
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: outW,
            kCVPixelBufferHeightKey as String: outH,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw MediaError.readerFailed(reader.error?.localizedDescription ?? "AVAssetReader failed to start")
        }

        var decodedPTS: [Double] = []
        var decodedBytes: [[UInt8]] = []
        while let sbuf = output.copyNextSampleBuffer() {
            guard let pbuf = CMSampleBufferGetImageBuffer(sbuf) else { continue }
            decodedBytes.append(Self.extractBytes(pbuf, width: outW, height: outH))
            decodedPTS.append(CMSampleBufferGetPresentationTimeStamp(sbuf).seconds)
        }
        if reader.status == .failed {
            throw MediaError.readerFailed(reader.error?.localizedDescription ?? "AVAssetReader failed while reading")
        }
        guard !decodedBytes.isEmpty else {
            throw MediaError.readerFailed("no frames decoded from \(url.path)")
        }

        let sampled = Self.resample(bytes: decodedBytes, pts: decodedPTS, fps: fps)

        var flat = [UInt8]()
        flat.reserveCapacity(sampled.count * outW * outH)
        for frame in sampled { flat.append(contentsOf: frame) }
        return GrayFrames(count: sampled.count, height: outH, width: outW, data: flat)
    }

    /// Nearest-neighbor resample onto a fixed `1/fps` time grid — the same
    /// selection ffmpeg's `fps` filter makes under its default `round=near`.
    static func resample(bytes: [[UInt8]], pts: [Double], fps: Double) -> [[UInt8]] {
        guard let lastPTS = pts.last else { return [] }
        let step = 1.0 / fps
        var out: [[UInt8]] = []
        var idx = 0
        var j = 0
        while true {
            let target = Double(j) * step
            if target > lastPTS + step / 2 { break }
            while idx < pts.count - 1 && abs(pts[idx + 1] - target) <= abs(pts[idx] - target) {
                idx += 1
            }
            out.append(bytes[idx])
            j += 1
        }
        return out
    }

    /// Reads plane 0 (luma) of a biplanar YCbCr buffer -- the Y bytes are
    /// already full-range 0-255 since the reader was asked for
    /// `420YpCbCr8BiPlanarFullRange`, so no further rescale is needed here.
    private static func extractBytes(_ pbuf: CVPixelBuffer, width: Int, height: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pbuf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pbuf, .readOnly) }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pbuf, 0)
        let base = CVPixelBufferGetBaseAddressOfPlane(pbuf, 0)!.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: width * height)
        out.withUnsafeMutableBufferPointer { dst in
            for row in 0..<height {
                let src = base + row * bytesPerRow
                (dst.baseAddress! + row * width).update(from: src, count: width)
            }
        }
        return out
    }
}
