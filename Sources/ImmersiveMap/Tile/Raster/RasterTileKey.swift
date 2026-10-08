// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// One raster tile: a map tile's ground drawn into a square texture of
/// `size` texels a side, its zoom fades evaluated at `fadeZoom`
/// (`RasterTileSpec`). The same tile at two sizes or two fade zooms is two
/// textures, kept and stored apart.
struct RasterTileKey: Hashable {
    let tile: Tile
    let size: Int
    let fadeZoom: Int

    init(tile: Tile, size: Int, fadeZoom: Int) {
        self.tile = tile
        self.size = size
        self.fadeZoom = fadeZoom
    }

    init(tile: Tile, spec: RasterTileSpec) {
        self.init(tile: tile, size: spec.size, fadeZoom: spec.fadeZoom)
    }
}

/// The texture of a raster tile and its bytes: every mip level, from the
/// full size down to one texel, tightly packed one after the other in the
/// order the GPU levels go. The disk file holds exactly these bytes, so a
/// file loads level by level straight into the texture, and the readback
/// after a bake writes them in the same order.
enum RasterTileLayout {
    /// The texture format: the colour the engine renders in, unconverted.
    /// The world pass draws into `bgra8Unorm` and blends there, so the
    /// texture keeps the same encoded values, and a raster tile shows the
    /// colours its geometry would.
    static let pixelFormat: MTLPixelFormat = .rgba8Unorm
    static let bytesPerTexel = 4

    static func levelCount(size: Int) -> Int {
        var count = 1
        var edge = max(size, 1)
        while edge > 1 {
            edge >>= 1
            count += 1
        }
        return count
    }

    static func edge(size: Int, level: Int) -> Int {
        max(size >> level, 1)
    }

    static func bytesPerRow(size: Int, level: Int) -> Int {
        edge(size: size, level: level) * bytesPerTexel
    }

    static func levelByteCount(size: Int, level: Int) -> Int {
        bytesPerRow(size: size, level: level) * edge(size: size, level: level)
    }

    /// Where each level starts in the packed bytes.
    static func levelOffsets(size: Int) -> [Int] {
        var offsets: [Int] = []
        var offset = 0
        for level in 0 ..< levelCount(size: size) {
            offsets.append(offset)
            offset += levelByteCount(size: size, level: level)
        }
        return offsets
    }

    static func totalByteCount(size: Int) -> Int {
        (0 ..< levelCount(size: size)).reduce(0) { $0 + levelByteCount(size: size, level: $1) }
    }

    /// The texture a raster tile lives in: private to the GPU, drawn into
    /// by the bake, loaded into by the IO queue, sampled by the draw.
    static func makeTexture(device: MTLDevice, size: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                  width: size,
                                                                  height: size,
                                                                  mipmapped: true)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "RasterTile"
        return texture
    }
}
