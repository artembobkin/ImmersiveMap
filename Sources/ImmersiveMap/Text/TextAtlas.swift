// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import Metal

/// The two glyph atlases as the draws sample them, the bold and the thin,
/// with the metrics that describe them and the layout that reads those
/// (`GlyphAtlasMetrics`, `TextLayout`). One set for the process: the atlas
/// pixels are uploaded once.
final class TextAtlas {
    let metrics: GlyphAtlasMetrics
    let layout: TextLayout
    let texture: MTLTexture
    let thinTexture: MTLTexture

    /// `resourceBundle` holds the atlases (`ImmersiveMapResourceBundle`).
    init(device: MTLDevice, resourceBundle: Bundle) {
        // The JSON first: it carries the dimensions the raw pixel file has
        // no header for.
        let metrics = GlyphAtlasMetrics(bundle: resourceBundle)
        self.metrics = metrics
        self.layout = TextLayout(metrics: metrics)
        let texture = Self.loadTexture(named: GlyphAtlasMetrics.boldAtlasName,
                                       atlas: metrics.bold.atlas,
                                       device: device,
                                       bundle: resourceBundle) ?? Self.makeFallbackTexture(device: device)
        texture.label = RenderResourceName.labelGlyphAtlas.rawValue
        self.texture = texture
        self.thinTexture = Self.loadTexture(named: GlyphAtlasMetrics.thinAtlasName,
                                            atlas: metrics.thin.atlas,
                                            device: device,
                                            bundle: resourceBundle) ?? texture
    }

    private static func makeFallbackTexture(device: MTLDevice) -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2D
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.width = 1
        descriptor.height = 1
        descriptor.usage = [.shaderRead]
        return device.makeTexture(descriptor: descriptor)!
    }

    /// The atlas pixels ship raw (`<name>.bgra`: BGRA8, the byte order of
    /// `bgra8Unorm`, row major, top row first, `width * height * 4` bytes,
    /// no header), the bytes the image decoder used to produce, written
    /// once by `Tools/TextAtlas/png_to_rgba.swift`. Loading is then a copy into a
    /// staging buffer and a blit into the private texture: no PNG inflate
    /// and unfilter, which was the largest single item of the engine's
    /// creation on the main thread.
    private static func loadTexture(named name: String,
                                    atlas: AtlasInfo,
                                    device: MTLDevice,
                                    bundle: Bundle) -> MTLTexture? {
        guard let url = bundle.url(forResource: name, withExtension: "bgra") else {
            #if DEBUG
            print("Could not find atlas pixels in bundle: \(name).bgra")
            #endif
            return nil
        }
        let width = atlas.width
        let height = atlas.height
        let bytesPerRow = width * 4
        guard width > 0, height > 0,
              let pixels = try? Data(contentsOf: url, options: .mappedIfSafe),
              pixels.count == bytesPerRow * height else {
            #if DEBUG
            print("Atlas pixels \(name).bgra do not match the \(width)x\(height) atlas in \(name).json")
            #endif
            return nil
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        // .private: the atlas is static, no CPU access is needed after the
        // upload, and a shared texture would keep a CPU copy for its whole
        // lifetime (2 x 16 MB).
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let staging = pixels.withUnsafeBytes({ bytes in
                  device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
              }),
              let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }
        blit.copy(from: staging,
                  sourceOffset: 0,
                  sourceBytesPerRow: bytesPerRow,
                  sourceBytesPerImage: bytesPerRow * height,
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: texture,
                  destinationSlice: 0,
                  destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        // The render queues that sample the atlas are not ordered against
        // this one; waiting here is what makes the texture whole for them.
        commandBuffer.waitUntilCompleted()
        return texture
    }
}

/// Shared by every renderer of the process (`SharedRenderResources`): the
/// atlases and the glyph tables are made once.
extension TextAtlas: SharedGPUResources {
    static func make(_ build: SharedGPUResourceBuild) -> TextAtlas {
        TextAtlas(device: build.device, resourceBundle: build.resourceBundle)
    }
}
