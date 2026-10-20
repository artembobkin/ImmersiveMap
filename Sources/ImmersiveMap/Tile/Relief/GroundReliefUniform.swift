// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// Mirror of `GroundReliefUniform` in GroundRelief.h (vertex and fragment
/// buffer 9): the tile's corner and side in the terrain texture its grid
/// rises by and the world units a metre of terrain rises by, then the
/// datum, the terrain's metres the ground is drawn from
/// (`GroundReliefStore.datumMetres`), the frame's strength
/// (`GroundRelief.strength`) and the metres the shading's terrain texture
/// spans, then the frame's shading of the slopes and its fade
/// (`GroundReliefHillshade`), and last the tile's corner and side in the
/// terrain texture its slopes are shaded by.
struct GroundReliefUniform {
    var placement: SIMD4<Float>
    var frame: SIMD4<Float>
    var hillshadeLight: SIMD4<Float>
    var hillshadeShadowColor: SIMD4<Float>
    var hillshadeHighlightColor: SIMD4<Float>
    var hillshadeEye: SIMD4<Float>
    var hillshadeFade: SIMD4<Float>
    var shading: SIMD4<Float>
    var occlusion: SIMD4<Float>

    /// `relief` is the terrain the grid rises by, `shading` the one the
    /// slopes are shaded by, the same where the ring's terrain is no finer
    /// than the displacement's. `terrainSideMetres` is the shading's.
    /// `occlusion` is the frame's darkening by the occlusion of the sky
    /// (`GroundReliefStore.occlusionUniform`).
    init(relief: GroundRelief,
         shading: GroundRelief,
         worldUnitsPerMetre: Float,
         datumMetres: Float,
         terrainSideMetres: Float,
         hillshade: GroundReliefHillshade,
         occlusion: SIMD4<Float> = .zero) {
        placement = SIMD4<Float>(relief.origin.x, relief.origin.y, relief.scale, worldUnitsPerMetre)
        frame = SIMD4<Float>(datumMetres, relief.strength, terrainSideMetres, 0)
        hillshadeLight = hillshade.light
        hillshadeShadowColor = hillshade.shadowColor
        hillshadeHighlightColor = hillshade.highlightColor
        hillshadeEye = hillshade.eye
        hillshadeFade = hillshade.fade
        self.shading = SIMD4<Float>(shading.origin.x, shading.origin.y, shading.scale, 0)
        self.occlusion = occlusion
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
    /// the grid rises by (`relief`, `PlaceTile.displacement`) at vertex
    /// texture 0, the terrain the slopes are shaded by (`shading`,
    /// `PlaceTile.terrain`, the ring's, nil for the same) at fragment
    /// texture 3, its occlusion of the sky (`GroundRelief.occlusion`, or
    /// one texel of none while it is not computed) at fragment texture 4,
    /// the uniform at vertex and fragment buffer 9, with the
    /// store's datum, world units a metre rises by and shading of the
    /// slopes this frame: one rise for every tile, so neighbours meet with
    /// one height at one rise. The vertex stage raises the ground by the
    /// first, the fills' fragment stage shades the slopes by the second
    /// (`groundReliefHillshade`), as fine as the ring's terrain whatever
    /// the grid. Every draw of the flat map that rises by the relief binds
    /// it here.
    static func bind(_ relief: GroundRelief,
                     shading: GroundRelief? = nil,
                     over tile: Tile,
                     store: GroundReliefStore,
                     renderMapSize: Double,
                     encoder: MTLRenderCommandEncoder) {
        let unitsPerMetre = store.worldUnitsPerMetre
        let shading = shading ?? relief
        var uniform = GroundReliefUniform(relief: relief,
                                          shading: shading,
                                          worldUnitsPerMetre: unitsPerMetre,
                                          datumMetres: store.datumMetres,
                                          terrainSideMetres: terrainSideMetres(of: shading,
                                                                               over: tile,
                                                                               worldUnitsPerMetre: unitsPerMetre,
                                                                               renderMapSize: renderMapSize),
                                          hillshade: store.hillshade,
                                          occlusion: store.occlusionUniform)
        encoder.setVertexTexture(relief.texture, index: 0)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<GroundReliefUniform>.stride, index: 9)
        encoder.setFragmentTexture(shading.texture, index: 3)
        encoder.setFragmentTexture(shading.occlusion ?? store.occlusionFallbackTexture, index: 4)
        encoder.setFragmentBytes(&uniform, length: MemoryLayout<GroundReliefUniform>.stride, index: 9)
    }
}
