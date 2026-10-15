// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// Mirror of `GroundReliefUniform` in GroundRelief.h (vertex buffer 9):
/// the tile's corner and side in its terrain texture and the world units
/// a metre of terrain rises by, then the datum, the terrain's metres the
/// ground is drawn from (`GroundReliefStore.datumMetres`), and the frame's
/// strength (`GroundRelief.strength`).
struct GroundReliefUniform {
    var placement: SIMD4<Float>
    var frame: SIMD4<Float>

    init(relief: GroundRelief, worldUnitsPerMetre: Float, datumMetres: Float) {
        placement = SIMD4<Float>(relief.origin.x, relief.origin.y, relief.scale, worldUnitsPerMetre)
        frame = SIMD4<Float>(datumMetres, relief.strength, 0, 0)
    }

    /// The world units a metre of terrain rises by over `tile`, at its
    /// middle's latitude.
    static func worldUnitsPerMetre(over tile: Tile, renderMapSize: Double) -> Float {
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: (Double(tile.y) + 0.5) / Double(1 << tile.z))
        return Float(ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: latitude, renderMapSize: renderMapSize))
    }

    /// Binds the relief of one tile for a vertex stage that rises by it
    /// (Tile.metal, TileRaster.metal, the relief variants): the terrain
    /// texture at vertex texture 0, the uniform at vertex buffer 9. Every
    /// draw of the flat map that rises by the relief binds it here.
    static func bind(_ relief: GroundRelief,
                     over tile: Tile,
                     datumMetres: Float,
                     renderMapSize: Double,
                     encoder: MTLRenderCommandEncoder) {
        var uniform = GroundReliefUniform(relief: relief,
                                          worldUnitsPerMetre: worldUnitsPerMetre(over: tile, renderMapSize: renderMapSize),
                                          datumMetres: datumMetres)
        encoder.setVertexTexture(relief.texture, index: 0)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<GroundReliefUniform>.stride, index: 9)
    }
}
