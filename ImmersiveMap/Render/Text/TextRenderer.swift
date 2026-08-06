// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

/// GPU side of text drawing: the glyph atlas textures and the pipelines that
/// sample them. Layout stays renderer independent in `Text` and is reachable
/// through `layout`, so tile preparation can measure and place glyphs without
/// touching Metal.
final class TextRenderer {
    /// Renderer independent glyph metrics, measurement and layout.
    let layout: TextLayoutResolver
    /// Bold MSDF atlas, the one every label falls back to.
    let texture: MTLTexture
    /// Thin MSDF atlas; the bold texture when the thin one is missing, matching
    /// the metrics fallback in `TextLayoutResolver`.
    let thinTexture: MTLTexture
    let pipelines: TextPipelines

    init(device: MTLDevice,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        self.layout = TextLayoutResolver()
        let boldTexture = Self.loadAtlasTexture(.bold, device: device)
            ?? Self.makeFallbackTexture(device: device)
        self.texture = boldTexture
        self.thinTexture = Self.loadAtlasTexture(.thin, device: device) ?? boldTexture
        self.pipelines = TextPipelines(device: device,
                                       library: library,
                                       sampleCount: sampleCount)
    }

    private static func loadAtlasTexture(_ resource: TextAtlasResource,
                                         device: MTLDevice,
                                         bundle: Bundle = .module) -> MTLTexture? {
        guard let url = bundle.url(forResource: resource.rawValue, withExtension: "png") else {
            #if DEBUG
            print("Could not find atlas texture in bundle: \(resource.rawValue).png")
            #endif
            return nil
        }
        let textureLoader = MTKTextureLoader(device: device)
        // .private: the atlas is static, no CPU access is needed after upload. The
        // loader fills the data via a staging blit, and the texture keeps no shadow
        // CPU copy (managed/shared would hold one for its entire lifetime).
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)
        ]
        do {
            return try textureLoader.newTexture(URL: url, options: options)
        } catch {
            #if DEBUG
            print("Failed to load atlas texture \(resource.rawValue).png: \(error)")
            #endif
            return nil
        }
    }

    /// 1x1 stand-in so a missing atlas draws nothing instead of leaving the
    /// pipelines without a bound texture.
    private static func makeFallbackTexture(device: MTLDevice) -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2D
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.width = 1
        descriptor.height = 1
        descriptor.usage = [.shaderRead]
        return device.makeTexture(descriptor: descriptor)!
    }
}
