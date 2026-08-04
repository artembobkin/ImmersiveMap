// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreVideo
import Foundation

/// Writes export frames to a QuickTime file: owns the `AVAssetWriter`
/// pipeline, vends pool pixel buffers for the renderer to draw into, and
/// appends them with fixed-step presentation times.
@MainActor
final class VideoExportAssetWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let framesPerSecond: Int
    private let outputURL: URL

    init(url: URL, configuration: ImmersiveMapVideoExportConfiguration) throws {
        // AVAssetWriter refuses to start over an existing file.
        try? FileManager.default.removeItem(at: url)
        self.outputURL = url
        self.framesPerSecond = configuration.framesPerSecond

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw ImmersiveMapVideoExportError.videoWriterFailure(error)
        }

        let codec: AVVideoCodecType = configuration.codec == .hevc ? .hevc : .h264
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: configuration.resolvedAverageBitRate,
                AVVideoExpectedSourceFrameRateKey: configuration.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: configuration.framesPerSecond * 2
            ],
            // Tag the stream as BT.709, the standard for SDR video, so
            // players reproduce the map's colors consistently.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: configuration.width,
                kCVPixelBufferHeightKey as String: configuration.height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
        )

        guard writer.canAdd(input) else {
            throw ImmersiveMapVideoExportError.videoWriterFailure(writer.error)
        }
        writer.add(input)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    func start() throws {
        guard writer.startWriting() else {
            throw ImmersiveMapVideoExportError.videoWriterFailure(writer.error)
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// Vends a pool pixel buffer for the renderer to draw into. The pool is
    /// created lazily after `start()`, hence the brief retry.
    func makePixelBuffer() async throws -> CVPixelBuffer {
        var attempts = 0
        while true {
            if let pool = adaptor.pixelBufferPool {
                var pixelBuffer: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
                if status == kCVReturnSuccess, let pixelBuffer {
                    Self.applyColorAttachments(to: pixelBuffer)
                    return pixelBuffer
                }
            }
            attempts += 1
            guard attempts < 200 else {
                throw ImmersiveMapVideoExportError.pixelBufferUnavailable
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func append(_ pixelBuffer: CVPixelBuffer, frameIndex: Int) async throws {
        while input.isReadyForMoreMediaData == false {
            guard writer.status == .writing else {
                throw ImmersiveMapVideoExportError.videoWriterFailure(writer.error)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let presentationTime = CMTime(value: CMTimeValue(frameIndex),
                                      timescale: CMTimeScale(framesPerSecond))
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw ImmersiveMapVideoExportError.videoWriterFailure(writer.error)
        }
    }

    func finish() async throws {
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw ImmersiveMapVideoExportError.videoWriterFailure(writer.error)
        }
    }

    /// Aborts the export and deletes the partial file.
    func cancel() {
        if writer.status == .writing {
            writer.cancelWriting()
        }
        try? FileManager.default.removeItem(at: outputURL)
    }

    /// Matches the buffer's color metadata to the stream tags so the encoder
    /// treats the rendered pixels exactly as they will be labeled.
    private static func applyColorAttachments(to pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(pixelBuffer,
                              kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2,
                              .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer,
                              kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2,
                              .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer,
                              kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                              .shouldPropagate)
    }
}
