// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// Mirror of `GroundReliefUniform` in GroundRelief.h (vertex and fragment
/// buffer 9): the tile's corner and side in its terrain texture and the
/// world units a metre of terrain rises by, then the datum, the terrain's
/// metres the ground is drawn from (`GroundReliefStore.datumMetres`), the
/// frame's strength (`GroundRelief.strength`) and the metres the terrain
/// texture spans, then the frame's shading of the slopes and its fade
/// (`GroundReliefHillshade`).
struct GroundReliefUniform {
    var placement: SIMD4<Float>
    var frame: SIMD4<Float>
    var hillshadeLight: SIMD4<Float>
    var hillshadeShadowColor: SIMD4<Float>
    var hillshadeHighlightColor: SIMD4<Float>
    var hillshadeEye: SIMD4<Float>
    var hillshadeFade: SIMD4<Float>

    init(relief: GroundRelief,
         worldUnitsPerMetre: Float,
         datumMetres: Float,
         terrainSideMetres: Float,
         hillshade: GroundReliefHillshade) {
        placement = SIMD4<Float>(relief.origin.x, relief.origin.y, relief.scale, worldUnitsPerMetre)
        frame = SIMD4<Float>(datumMetres, relief.strength, terrainSideMetres, 0)
        hillshadeLight = hillshade.light
        hillshadeShadowColor = hillshade.shadowColor
        hillshadeHighlightColor = hillshade.highlightColor
        hillshadeEye = hillshade.eye
        hillshadeFade = hillshade.fade
    }

    /// The world units a metre spans at a latitude, by its normalized
    /// world mercator y.
    static func worldUnitsPerMetre(atNormalizedWorldY y: Double, renderMapSize: Double) -> Float {
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: y)
        return Float(ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: latitude, renderMapSize: renderMapSize))
    }

    /// The ground metres a terrain texture spans a side, in the frame's
    /// metres (`GroundReliefStore.worldUnitsPerMetre`): the tile's side
    /// over its share of the texture (`GroundRelief.scale`).
    static func terrainSideMetres(of relief: GroundRelief, over tile: Tile, worldUnitsPerMetre: Float, renderMapSize: Double) -> Float {
        let tileSideWorld = Float(renderMapSize / Double(1 << tile.z))
        return tileSideWorld / max(worldUnitsPerMetre, .leastNormalMagnitude) / max(relief.scale, .leastNormalMagnitude)
    }

    /// Binds the relief of one tile for a draw that rises by it
    /// (Tile.metal, TileRaster.metal, the relief variants): the terrain
    /// texture at vertex texture 0 and fragment texture 3, the uniform at
    /// vertex and fragment buffer 9, with the store's datum, world units a
    /// metre rises by and shading of the slopes this frame: one rise for
    /// every tile, so neighbours meet with one height at one rise. The vertex stage raises the ground by it, the
    /// fills' fragment stage shades the slopes (`groundReliefHillshade`).
    /// Every draw of the flat map that rises by the relief binds it here.
    static func bind(_ relief: GroundRelief,
                     over tile: Tile,
                     store: GroundReliefStore,
                     renderMapSize: Double,
                     encoder: MTLRenderCommandEncoder) {
        let unitsPerMetre = store.worldUnitsPerMetre
        var uniform = GroundReliefUniform(relief: relief,
                                          worldUnitsPerMetre: unitsPerMetre,
                                          datumMetres: store.datumMetres,
                                          terrainSideMetres: terrainSideMetres(of: relief,
                                                                               over: tile,
                                                                               worldUnitsPerMetre: unitsPerMetre,
                                                                               renderMapSize: renderMapSize),
                                          hillshade: store.hillshade)
        encoder.setVertexTexture(relief.texture, index: 0)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<GroundReliefUniform>.stride, index: 9)
        encoder.setFragmentTexture(relief.texture, index: 3)
        encoder.setFragmentBytes(&uniform, length: MemoryLayout<GroundReliefUniform>.stride, index: 9)
    }
}
