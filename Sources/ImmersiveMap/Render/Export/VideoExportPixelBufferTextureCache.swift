// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreVideo
import Metal

/// Wraps writer-vended `CVPixelBuffer`s as BGRA render-target textures through
/// a `CVMetalTextureCache`: the export frame renders straight into the pixel
/// buffer's IOSurface, so no readback or copy is needed before encoding.
final class VideoExportPixelBufferTextureCache {
    /// One export frame: the pixel buffer handed to the video writer and the
    /// Metal texture the engine renders into. `retainedTexture` keeps the
    /// CoreVideo↔Metal binding alive; hold the frame until the GPU finished
    /// writing and the buffer was appended.
    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let texture: MTLTexture
        let retainedTexture: CVMetalTexture
    }

    enum Failure: Error {
        case cacheCreationFailed(CVReturn)
        case textureCreationFailed(CVReturn)
    }

    /// Recycled cache entries are drained every this many frames.
    private static let flushInterval = 120

    private let cache: CVMetalTextureCache
    private var framesSinceFlush = 0

    init(device: MTLDevice) throws {
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw Failure.cacheCreationFailed(status)
        }
        self.cache = cache
    }

    func makeFrame(wrapping pixelBuffer: CVPixelBuffer) throws -> Frame {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        // The texture is the world/overlay pass color destination (MSAA resolve
        // target) and the FXAA pass samples it, hence both usages.
        let textureAttributes: [CFString: Any] = [
            kCVMetalTextureUsage: NSNumber(value: MTLTextureUsage([.renderTarget, .shaderRead]).rawValue)
        ]
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                               cache,
                                                               pixelBuffer,
                                                               textureAttributes as CFDictionary,
                                                               .bgra8Unorm,
                                                               width,
                                                               height,
                                                               0,
                                                               &texture)
        guard status == kCVReturnSuccess,
              let texture,
              let metalTexture = CVMetalTextureGetTexture(texture) else {
            throw Failure.textureCreationFailed(status)
        }

        framesSinceFlush += 1
        if framesSinceFlush >= Self.flushInterval {
            flush()
        }
        return Frame(pixelBuffer: pixelBuffer, texture: metalTexture, retainedTexture: texture)
    }

    /// Drains cache entries whose textures are no longer referenced. Safe to
    /// call at any point: live frames hold their `retainedTexture`.
    func flush() {
        CVMetalTextureCacheFlush(cache, 0)
        framesSinceFlush = 0
    }
}
