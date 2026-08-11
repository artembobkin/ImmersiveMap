// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Metal

/// Gets a rendered offscreen frame off the GPU and into a `CGImage`.
///
/// The other direction of pixel egress, into a `CVPixelBuffer` for the video
/// encoder, is `VideoExportPixelBufferTextureCache`. Both live here rather than
/// next to their callers because command queues, blit encoders and texture
/// storage modes are GPU resource lifetime, which `UI` must not own.
struct OffscreenTextureImageReadback {
    enum Failure: Error {
        case textureUnavailable
        case synchronizeFailed
        case imageCreationFailed
    }

    let device: MTLDevice

    /// A render target the CPU can read back.
    ///
    /// Shared storage everywhere it exists, which is every Apple GPU and the
    /// simulator. A discrete GPU on an Intel Mac keeps its own copy, so the
    /// texture is managed there and its contents have to be synchronized back
    /// over the bus before `getBytes` sees them; without the distinction the
    /// readback would hand back an uninitialized image instead of failing.
    ///
    /// The platform split is deliberate rather than a bare `hasUnifiedMemory`
    /// test: `.managed` exists only on macOS, and the iOS Simulator also
    /// reports no unified memory, so keying on that flag alone would ask the
    /// simulator for a storage mode its platform does not have.
    func makeReadableTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        #if os(macOS)
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        #else
        descriptor.storageMode = .shared
        #endif
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw Failure.textureUnavailable
        }
        return texture
    }

    /// Reads `texture` back and wraps the pixels in a `CGImage`.
    func makeImage(from texture: MTLTexture) throws -> CGImage {
        try synchronizeIfNeeded(texture)

        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height

        // The GPU writes straight into the buffer the image will be built
        // from. Reading into an array and then copying it into `Data` would
        // hold the frame twice, which at the largest allowed capture is about
        // a gigabyte of avoidable duplication.
        guard let storage = CFDataCreateMutable(nil, byteCount) else {
            throw Failure.imageCreationFailed
        }
        CFDataSetLength(storage, byteCount)
        guard let base = CFDataGetMutableBytePtr(storage) else {
            throw Failure.imageCreationFailed
        }
        texture.getBytes(base,
                         bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)

        // The render target is `bgra8Unorm` with premultiplied alpha, which is
        // little-endian 32-bit with alpha first once the byte order is named.
        let bitmapInfo = CGBitmapInfo.byteOrder32Little
            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let provider = CGDataProvider(data: storage),
              let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo,
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw Failure.imageCreationFailed
        }
        return image
    }

    private func synchronizeIfNeeded(_ texture: MTLTexture) throws {
        #if os(macOS)
        guard texture.storageMode == .managed else {
            return
        }
        guard let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw Failure.synchronizeFailed
        }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #endif
    }
}
