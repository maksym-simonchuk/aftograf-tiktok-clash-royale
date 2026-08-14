import AVFoundation
import Foundation

/// Port of `media.py:55-83` `probe`/`_rotation` — reads container metadata via
/// AVFoundation instead of ffprobe. Rotation comes from the track's
/// `preferredTransform` (ffprobe reads the same rotation from side-data/tags);
/// width/height are swapped when the rotation is a quarter turn, exactly like
/// `_rotation(st) % 180 == 90` in the Python version.
public enum Probe {
    public static func probe(url: URL) async throws -> Meta {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideoTrack("no video stream in \(url.path)")
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominalFPS = try await track.load(.nominalFrameRate)
        let assetDuration = try await asset.load(.duration)

        var width = Int(naturalSize.width.rounded())
        var height = Int(naturalSize.height.rounded())
        if rotationDegrees(transform) % 180 == 90 {
            swap(&width, &height)
        }

        let duration = assetDuration.seconds
        guard duration.isFinite, duration > 0 else {
            throw MediaError.indeterminateDuration("cannot determine duration of \(url.path)")
        }

        let fps = nominalFPS > 0 ? Double(nominalFPS) : 30.0

        return Meta(path: url.path, width: width, height: height, fps: fps, duration: duration)
    }

    /// Rotation implied by a track's `preferredTransform`, in `0..<360`, matching
    /// `media.py`'s `_rotation` which returns `abs(rotation)` (direction doesn't
    /// matter — only whether it's a quarter turn).
    static func rotationDegrees(_ transform: CGAffineTransform) -> Int {
        let radians = atan2(Double(transform.b), Double(transform.a))
        var degrees = Int(radians * 180.0 / .pi).magnitude
        degrees = degrees % 360
        return Int(degrees)
    }
}
