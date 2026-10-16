// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The texture a raster tile is drawn into (`RasterTileRenderSubsystem`):
/// a square of the ring rule's size, with its mip chain, private to the
/// GPU, kept from frame to frame and filled again only when what it shows
/// changes, copied from the frame's atlas pass and sampled by the frame's
/// draws.
enum RasterTileTexture {
    /// The texture format: the colour the engine renders in, unconverted.
    /// The world pass draws into `bgra8Unorm` and blends there, so the
    /// texture keeps the same encoded values, and a raster tile shows the
    /// colours its geometry would.
    static let pixelFormat: MTLPixelFormat = .rgba8Unorm

    static func make(device: MTLDevice, size: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                  width: size,
                                                                  height: size,
                                                                  mipmapped: true)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "RasterTile.\(size)"
        return texture
    }
}
