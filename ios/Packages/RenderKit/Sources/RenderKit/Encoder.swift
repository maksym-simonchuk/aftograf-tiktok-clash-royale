import AVFoundation
import CoreImage
import PlanKit

/// Re-encodes a composition through AVAssetReader -> AVAssetWriter (not
/// AVAssetExportSession, which only exposes fixed presets) so the output
/// hits an explicit bitrate/profile and bt709 color tagging (plan §2.6/§2.8).
/// H.264/AAC here are hardware-accelerated automatically by VideoToolbox on
/// device; there is no separate "hardware" flag to set.
public enum Encoder {
    public static func export(
        composition: AVAsset,
        videoComposition: AVVideoComposition,
        target: RenderTarget,
        group: Group,
        audioMix: AVAudioMix? = nil,
        to outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let reader = try AVAssetReader(asset: composition)

        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        )
        videoOutput.videoComposition = videoComposition
        guard reader.canAdd(videoOutput) else {
            throw RenderError.readerFailed("cannot add video composition output")
        }
        reader.add(videoOutput)

        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
            ])
            out.audioMix = audioMix
            if reader.canAdd(out) {
                reader.add(out)
                audioOutput = out
            }
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let colorProperties: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: target.width,
            AVVideoHeightKey: target.height,
            AVVideoColorPropertiesKey: colorProperties,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 20_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: target.fps,
            ] as [String: Any],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw RenderError.writerFailed("cannot add video input")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVEncoderBitRateKey: 256_000,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard reader.startReading() else {
            throw RenderError.readerFailed(reader.error?.localizedDescription ?? "startReading failed")
        }
        guard writer.startWriting() else {
            throw RenderError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(target.fps))
        let compositionDuration = try await composition.load(.duration)
        let pixelBufferPool = try makePixelBufferPool(target: target)
        let overlay = makeOverlay(group: group, target: target, totalSeconds: compositionDuration.seconds)
        if let audioOutput, let audioInput {
            // A single AVAssetReader with two live outputs must have both
            // drained roughly in tandem: draining video to completion before
            // touching audio (or vice versa) lets the untouched output's
            // internal buffer fill and backpressures the reader's shared
            // demux/mix pipeline -- an internal AVFoundation deadlock
            // (observed as coremedia.readerOfflineMixer/videoprocessor
            // threads parked on condvars forever), not a Swift-level bug.
            // videoOutput/videoInput/pixelBufferPool/overlay/audioOutput/audioInput
            // predate Sendable -- same trusted rebind pump/pumpVideoCFR already use
            // to cross into their own queue, applied here to cross into the two
            // concurrent child tasks below (each only touches its own values).
            nonisolated(unsafe) let videoOutput = videoOutput
            nonisolated(unsafe) let videoInput = videoInput
            nonisolated(unsafe) let pixelBufferPool = pixelBufferPool
            nonisolated(unsafe) let overlay = overlay
            nonisolated(unsafe) let audioOutput = audioOutput
            nonisolated(unsafe) let audioInput = audioInput
            async let videoTask: Void = pumpVideoCFR(
                output: videoOutput, into: videoInput, frameDuration: frameDuration, totalDuration: compositionDuration,
                pixelBufferPool: pixelBufferPool, overlay: overlay, progress: progress
            )
            async let audioTask: Void = pump(output: audioOutput, into: audioInput)
            do {
                _ = try await (videoTask, audioTask)
            } catch is CancellationError {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                throw CancellationError()
            }
        } else {
            do {
                try await pumpVideoCFR(
                    output: videoOutput, into: videoInput, frameDuration: frameDuration, totalDuration: compositionDuration,
                    pixelBufferPool: pixelBufferPool, overlay: overlay, progress: progress
                )
            } catch is CancellationError {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                throw CancellationError()
            }
        }

        await writer.finishWriting()
        if writer.status != .completed {
            throw RenderError.writerFailed(writer.error?.localizedDescription ?? "status=\(writer.status.rawValue)")
        }
        if reader.status == .failed {
            throw RenderError.readerFailed(reader.error?.localizedDescription ?? "reader failed after writing")
        }
    }

    /// Progress bar (full render) + active captions (group's absolute
    /// timeline) -- render.py's post-`_join` overlay stage (retention bar +
    /// _overlay_stickers), applied here rather than in the compositor since
    /// both work in the OUTPUT's absolute time, not any one segment's local
    /// clock.
    private static func makeOverlay(
        group: Group, target: RenderTarget, totalSeconds: Double
    ) -> (CIImage, Double) -> CIImage {
        let captionCues = Stickers.captionCues(for: group, width: target.width)
        let targetSize = CGSize(width: target.width, height: target.height)
        return { image, t in
            var out = ProgressBar.apply(
                image, target: targetSize, progress: totalSeconds > 0 ? t / totalSeconds : 0
            )
            for cue in captionCues where t >= cue.start && t <= cue.start + StickerMotion.captionLength {
                let elapsed = t - cue.start
                let opacity = StickerMotion.opacity(elapsed: elapsed)
                guard opacity > 0 else { continue }
                out = overlayCaption(out, cue: cue, elapsed: elapsed, opacity: opacity, target: targetSize)
            }
            return out
        }
    }

    private static func overlayCaption(
        _ base: CIImage, cue: CaptionCue, elapsed: Double, opacity: Double, target: CGSize
    ) -> CIImage {
        var image = CIImage(cgImage: cue.image)
        if opacity < 1 {
            let alpha = CIFilter(name: "CIColorMatrix", parameters: [
                kCIInputImageKey: image,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
            ])
            image = alpha?.outputImage ?? image
        }
        let yTopLeft = StickerMotion.y(elapsed: elapsed, height: Double(target.height))
        let cx = (target.width - image.extent.width) / 2
        // caller's y-expr is the sticker's top edge in top-left/y-down
        // coords (straight from the ffmpeg overlay this ports) -- flip into
        // CIImage's bottom-left/y-up space.
        let cy = target.height - CGFloat(yTopLeft) - image.extent.height
        image = image.transformed(by: CGAffineTransform(translationX: cx - image.extent.minX, y: cy - image.extent.minY))

        guard let over = CIFilter(name: "CISourceOverCompositing", parameters: [
            kCIInputImageKey: image, kCIInputBackgroundImageKey: base,
        ]) else { return base }
        return (over.outputImage ?? base).cropped(to: CGRect(origin: .zero, size: target))
    }

    private static func makePixelBufferPool(target: RenderTarget) throws -> CVPixelBufferPool {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: target.width,
            kCVPixelBufferHeightKey as String: target.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw RenderError.writerFailed("could not create pixel buffer pool (status \(status))")
        }
        return pool
    }

    /// Drains one AVAssetReaderOutput into its AVAssetWriterInput. Called
    /// concurrently with the video pump (see the call site) when an audio
    /// track is present -- a shared AVAssetReader needs every live output
    /// drained roughly in tandem, not one fully drained before another.
    private static func pump(output: AVAssetReaderOutput, into input: AVAssetWriterInput) async throws {
        // AVAssetReaderOutput/AVAssetWriterInput predate Sendable but are safe to
        // hop onto their own serial queue: nothing else touches them meanwhile.
        nonisolated(unsafe) let output = output
        nonisolated(unsafe) let input = input
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "renderkit.encoder.pump")
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    if !input.append(sample) {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }

    /// AVAssetReaderVideoCompositionOutput passes composed frames through at
    /// their native (speed-scaled) timing instead of resampling to
    /// `videoComposition.frameDuration` -- confirmed empirically (a 15fps
    /// source with speed ramps came out ~12.8fps average, not the requested
    /// 30). Ports render.py:139's `fps={fps}` filter: walk a fixed CFR grid
    /// and hold the last composed frame at each slot, duplicating/dropping
    /// same as ffmpeg's fps filter would. Each held frame is re-rendered
    /// through `overlay` (progress bar + captions, plan §6 M4(e)/(f)) into a
    /// freshly pooled pixel buffer before being handed to the writer.
    private static func pumpVideoCFR(
        output: AVAssetReaderOutput, into input: AVAssetWriterInput,
        frameDuration: CMTime, totalDuration: CMTime,
        pixelBufferPool: CVPixelBufferPool, overlay: @escaping (CIImage, Double) -> CIImage,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        nonisolated(unsafe) let output = output
        nonisolated(unsafe) let input = input
        nonisolated(unsafe) let pool = pixelBufferPool
        let ciContext = CIContext()
        let frameCount = Int((totalDuration.seconds / frameDuration.seconds).rounded(.up))
        // requestMediaDataWhenReady's callback runs on our own DispatchQueue,
        // outside any Swift Task context -- Task.checkCancellation() called
        // from inside it would never see the caller's cancellation (no
        // ambient task there to check). Bridge cancellation in via
        // withTaskCancellationHandler instead, flipping this flag with the
        // same trusted nonisolated(unsafe) rebind already used above for the
        // AVFoundation objects; the loop below polls it once per frame.
        nonisolated(unsafe) var cancelled = false
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let queue = DispatchQueue(label: "renderkit.encoder.pump.video")
                // requestMediaDataWhenReady only ever re-enters on `queue`, serially --
                // safe to mutate from the closure despite not being actor-isolated.
                nonisolated(unsafe) var heldSample: CMSampleBuffer?
                nonisolated(unsafe) var pending: CMSampleBuffer?
                nonisolated(unsafe) var slotIndex = 0
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        guard !cancelled else {
                            input.markAsFinished()
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        guard slotIndex < frameCount else {
                            input.markAsFinished()
                            continuation.resume()
                            return
                        }
                        let slotTime = CMTimeMultiply(frameDuration, multiplier: Int32(slotIndex))

                        while true {
                            if pending == nil {
                                pending = output.copyNextSampleBuffer()
                            }
                            guard let candidate = pending else { break }
                            if CMSampleBufferGetPresentationTimeStamp(candidate) <= slotTime {
                                heldSample = candidate
                                pending = nil
                            } else {
                                break
                            }
                        }

                        guard let sample = heldSample,
                            let composited = compositedSampleBuffer(
                                from: sample, presentationTime: slotTime, duration: frameDuration,
                                context: ciContext, pixelBufferPool: pool, overlay: overlay
                            )
                        else {
                            input.markAsFinished()
                            continuation.resume(throwing: RenderError.readerFailed("no composed frame available for slot \(slotIndex)"))
                            return
                        }
                        if !input.append(composited) {
                            input.markAsFinished()
                            continuation.resume()
                            return
                        }
                        slotIndex += 1
                        if frameCount > 0, slotIndex % 10 == 0 || slotIndex == frameCount {
                            progress?(Double(slotIndex) / Double(frameCount))
                        }
                    }
                }
            }
        } onCancel: {
            cancelled = true
        }
    }

    private static func compositedSampleBuffer(
        from sampleBuffer: CMSampleBuffer, presentationTime: CMTime, duration: CMTime,
        context: CIContext, pixelBufferPool: CVPixelBufferPool, overlay: (CIImage, Double) -> CIImage
    ) -> CMSampleBuffer? {
        guard let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let composed = overlay(CIImage(cvPixelBuffer: sourceBuffer), presentationTime.seconds)

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer)
        guard status == kCVReturnSuccess, let outBuffer = pixelBuffer else { return nil }
        context.render(composed, to: outBuffer)

        var formatDescription: CMVideoFormatDescription?
        let fdStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: outBuffer, formatDescriptionOut: &formatDescription
        )
        guard fdStatus == noErr, let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var newSample: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: outBuffer, formatDescription: formatDescription,
            sampleTiming: &timing, sampleBufferOut: &newSample
        )
        return sbStatus == noErr ? newSample : nil
    }
}
