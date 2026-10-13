// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The texture a raster tile is drawn into each frame
/// (`RasterTileRenderSubsystem`): a square of the ring rule's size, with
/// its mip chain, private to the GPU, drawn into by the frame's pass and
/// sampled by the frame's draw.
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
