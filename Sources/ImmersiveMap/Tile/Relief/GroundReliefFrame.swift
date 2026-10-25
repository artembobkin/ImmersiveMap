// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The ground relief of one frame, as everything of the frame reads it:
/// the values the frame draws the relief by, settled once
/// (`GroundReliefFrameState.frame`), and the terrain tiles in
/// (`GroundReliefStore`) read through them. A value: whatever reads it
/// reads one frame's relief throughout, and cannot change it. The frame
/// hands it to its features through `FrameContextServices.groundRelief`.
///
/// Off the terrain (`isActive` false) every tile and whatever stands on it
/// lies on the plane: no relief is handed out, and every height reads 0.
struct GroundReliefFrame {
    /// What the mountains' shadow in the map is drawn from: the terrain
    /// tiles in and their welds (`version`), the rise, the world scale and
    /// the datum the ground is drawn from. The map is drawn again when it
    /// changes (`ShadowMapReuseController`).
    struct ShadowSignature: Equatable {
        let version: UInt64
        let strength: Float
        let worldUnitsPerMetre: Float
        let datumMetres: Float
    }

    private let store: GroundReliefStore
    /// Whether the frame is on the terrain
    /// (`GroundReliefFrameState.setActive`): the flat map with tiles of the
    /// relief's zoom or deeper, at a zoom within the relief's zooms or on
    /// its way out of them. Off, every tile and whatever stands on it lies
    /// on the plane, and the camera stands on the plane.
    let isActive: Bool
    /// How much taller than the terrain the ground is drawn this frame: the
    /// configured exaggeration times the share of the relief standing,
    /// eased (`GroundReliefFrameState.setFrame`).
    let strength: Float
    /// How much of the relief stands: 1 standing, 0 lying in the plane.
    let standingShare: Float
    /// The terrain under the point the camera looks at, in metres before
    /// the exaggeration (`GroundReliefCameraLift.datumMetres`): the height
    /// the relief is drawn from. Zero off the terrain.
    let datumMetres: Float
    /// The world units a metre of terrain rises by this frame, one for
    /// every tile (`GroundReliefFrameState.setWorldScale`). The frame's
    /// strength is not in it.
    let worldUnitsPerMetre: Float
    /// The shading of the slopes this frame, what every draw on the relief
    /// binds (`GroundReliefUniform`).
    let hillshade: GroundReliefHillshade
    /// The strength the fills darken by where the terrain hides the sky,
    /// and whether they draw the occlusion alone
    /// (`GroundReliefUniform.occlusion`).
    let occlusionUniform: SIMD4<Float>
    /// Whether the mountains cast into the shadow map this frame
    /// (`GroundReliefShadowCasterSubsystem`): allowed to, on the terrain,
    /// and risen. It opens the shadow pass as a building does
    /// (`ShadowPassGateResolver`).
    let castsShadows: Bool
    /// The tile zoom the ground rises from
    /// (`GroundReliefFrameState.fromTileZoom`).
    let fromTileZoom: Int
    /// The deepest tile zoom whose frames the relief stands on
    /// (`GroundReliefFrameState.collapseTileZoom`).
    let collapseTileZoom: Int

    init(store: GroundReliefStore,
         isActive: Bool,
         strength: Float,
         standingShare: Float,
         datumMetres: Float,
         worldUnitsPerMetre: Float,
         hillshade: GroundReliefHillshade,
         occlusionUniform: SIMD4<Float>,
         castsShadows: Bool,
         fromTileZoom: Int,
         collapseTileZoom: Int) {
        self.store = store
        self.isActive = isActive
        self.strength = strength
        self.standingShare = standingShare
        self.datumMetres = datumMetres
        self.worldUnitsPerMetre = worldUnitsPerMetre
        self.hillshade = hillshade
        self.occlusionUniform = occlusionUniform
        self.castsShadows = castsShadows
        self.fromTileZoom = fromTileZoom
        self.collapseTileZoom = collapseTileZoom
    }

    // MARK: - The terrain in

    /// The terrain in's version (`GroundReliefStore.version`).
    var version: UInt64 { store.version }

    /// The heights of every terrain tile in (`GroundReliefStore.heightRangeMetres`).
    var heightRangeMetres: ClosedRange<Float>? { store.heightRangeMetres }

    /// What a draw samples for a tile whose occlusion is not computed.
    var occlusionFallbackTexture: MTLTexture? { store.occlusionFallbackTexture }

    /// The zoom of the camera's terrain map (`GroundReliefStore.cameraTerrainZoom`).
    var cameraTerrainZoom: Int { store.cameraTerrainZoom }

    /// The zoom a ring of `zoom` reads its terrain at.
    func terrainZoom(forTargetZoom zoom: Int) -> Int {
        store.terrainZoom(forTargetZoom: zoom)
    }

    /// What the mountains' shadow is drawn from, nil while they cast
    /// nothing.
    var shadowSignature: ShadowSignature? {
        guard castsShadows else { return nil }
        return ShadowSignature(version: store.version,
                               strength: strength,
                               worldUnitsPerMetre: worldUnitsPerMetre,
                               datumMetres: datumMetres)
    }

    // MARK: - Reading the relief

    /// The relief of a ground tile out of one terrain tile, `source`, the
    /// one its placement is bound to (`PlaceTile.terrain`): the tile placed
    /// in the source, whole or a part of it. Nil off the terrain, where
    /// every tile lies on the plane, and nil for a source not in, which the
    /// planner never binds a placement to.
    ///
    /// Nil too for a terrain tile the source has not got or does not
    /// answer for (`GroundReliefStore.isResident`, which counts such a tile
    /// as in): the placement bound to it lies flat, as every tile does off
    /// the terrain, and rises when the tile lands after all.
    func relief(for tile: Tile, terrain source: Tile) -> GroundRelief? {
        guard isActive, source.z <= tile.z, let found = store.terrain(at: source) else {
            return nil
        }
        let placement = GroundRelief.placement(of: tile, in: source)
        return GroundRelief(terrain: found.terrain, origin: placement.origin, scale: placement.scale, strength: strength,
                            occlusion: found.occlusion)
    }

    /// The relief under a tile out of the terrain of `terrainZoom` over it,
    /// or the finest coarser one in while that is on its way: what the
    /// camera and the frame's datum read, off the camera's one map, where a
    /// coarser stand-in for a frame is better than no ground. The ground's
    /// draws read the terrain their placements are bound to instead
    /// (`relief(for:terrain:)`). Nil while no terrain over the tile is in
    /// at all, and nil off the terrain. `orCoarser` false asks for the
    /// terrain of `terrainZoom` only. It carries no occlusion of the sky.
    func relief(for tile: Tile, terrainZoom: Int, orCoarser: Bool = true) -> GroundRelief? {
        guard isActive, let found = store.finestTerrain(over: tile, terrainZoom: terrainZoom, orCoarser: orCoarser) else {
            return nil
        }
        let placement = GroundRelief.placement(of: tile, in: found.source)
        return GroundRelief(terrain: found.terrain, origin: placement.origin, scale: placement.scale, strength: strength)
    }

    /// The relief under a point of the world (normalized world mercator),
    /// from the terrain tile of `terrainZoom` that holds it, or the finest
    /// coarser one in, with the point's uv in the tile: nil while no
    /// terrain over the point is in, and nil off the terrain.
    private func relief(atNormalizedWorld point: SIMD2<Double>, terrainZoom zoom: Int) -> (relief: GroundRelief, uv: SIMD2<Float>)? {
        let tilesCount = Double(1 << max(0, zoom))
        let wrappedX = ImmersiveMapProjection.wrapNormalizedWorldX(point.x)
        let clampedY = ImmersiveMapProjection.clampNormalizedWorldY(point.y)
        let column = min(Int(wrappedX * tilesCount), Int(tilesCount) - 1)
        let row = min(Int(clampedY * tilesCount), Int(tilesCount) - 1)
        guard let relief = relief(for: Tile(x: column, y: row, z: zoom), terrainZoom: zoom) else {
            return nil
        }
        return (relief, SIMD2<Float>(Float(wrappedX * tilesCount - Double(column)), Float(clampedY * tilesCount - Double(row))))
    }

    /// The terrain's height in metres under a point of the world, from
    /// the terrain tile of `terrainZoom` that holds it: bilinear between
    /// the four texels around it, as the vertex stage samples it. From
    /// the finest coarser terrain in while that one is on its way, nil
    /// while no terrain over the point is in, and zero off the terrain,
    /// on the plane.
    func elevation(atNormalizedWorld point: SIMD2<Double>, terrainZoom zoom: Int) -> Float? {
        guard isActive else {
            return 0
        }
        guard let found = relief(atNormalizedWorld: point, terrainZoom: zoom) else {
            return nil
        }
        return found.relief.metres(atTileUV: found.uv)
    }

    /// How much taller than the terrain the ground under a point of the
    /// world is drawn this frame: zero off the terrain, nil while no
    /// terrain over the point is in.
    func strength(atNormalizedWorld point: SIMD2<Double>, terrainZoom zoom: Int) -> Float? {
        guard isActive else {
            return 0
        }
        guard relief(atNormalizedWorld: point, terrainZoom: zoom) != nil else {
            return nil
        }
        return strength
    }

    /// The terrain under a point of the world as drawn: the datum plus
    /// the height over it at the frame's strength, in metres, so the
    /// point the camera looks at reads as its own height and the country
    /// around it as high as it is drawn. Nil while no terrain over the
    /// point is in, zero off the terrain.
    func drawnMetres(atNormalizedWorld point: SIMD2<Double>, terrainZoom zoom: Int) -> Float? {
        guard isActive else {
            return 0
        }
        guard let found = relief(atNormalizedWorld: point, terrainZoom: zoom) else {
            return nil
        }
        return datumMetres + found.relief.drawnMetres(atTileUV: found.uv, datumMetres: datumMetres)
    }

    /// What the store holds and does now with the frame's own values, for
    /// the debug panel's relief tab.
    func statusSnapshot() -> GroundReliefStatusSnapshot {
        store.statusSnapshot(isActive: isActive, standingShare: standingShare, datumMetres: datumMetres)
    }
}
