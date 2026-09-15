// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// Keeps the rendered shadow map alive across frames. The sun is static and
/// the buildings do not move, so a rendered map only goes stale when the
/// camera leaves the fitted window, the light or resolution changes, the
/// set of tiles with buildings changes, or scene models (which animate)
/// cast.
/// Everything else is the common case: the receivers keep sampling the map
/// rendered some frames ago, through matrices re-materialized for the
/// current pan, and the whole caster pass simply does not run.
///
/// The fit is computed with an inflated receiver footprint (`radiusMargin`),
/// so the camera can travel and turn inside the rendered window for a while
/// before a refit; the fitted centre snaps to whole texels in pan-anchored
/// space, so a refit moves the window by whole texels and shadow edges do not
/// crawl. The window follows the view now, so turning the camera spends that
/// slack faster than panning does: a refit is a re-render of the caster pass.
final class ShadowMapReuseController {
    /// Footprint inflation of the fit, about the camera. The slack is travel
    /// budget: ~10% before the window needs a refit. The price is up to 10%
    /// coarser texels than a frame-exact fit, on top of the √2 quantization
    /// the fit always had.
    static let radiusMargin: Float = 1.1

    /// One caster's identity in the rendered map: the parsed tile object
    /// (re-parsing the same coordinates makes a new object, which correctly
    /// reads as a new caster), the slot it draws in (a parent clipped to a
    /// slot casts from that slot only) and the world-wrap copy.
    struct CasterKey: Hashable {
        let tile: ObjectIdentifier
        let placeIn: Tile
        let loop: Int8
    }

    private var fit: ShadowAnchoredFit?
    private var fitGeneration: UInt64 = 0
    private var renderedGeneration: UInt64?
    private var renderedTextureIdentity: ObjectIdentifier?
    private var renderedCasterKeys: Set<CasterKey> = []

    /// The per-frame shadow state: a cached fit re-materialized under the
    /// current pan when it still covers the frame, a fresh (margined) fit
    /// otherwise. Same inputs contract as `ShadowFrameStateResolver.resolve`.
    func resolveFrameState(renderSurfaceMode: ViewMode,
                           projectionView: matrix_float4x4,
                           cameraEye: SIMD3<Float>,
                           centerWorldMercator: SIMD2<Double>,
                           flatRenderPan: SIMD2<Double>,
                           renderMapSize: Double,
                           scene: ImmersiveMapSettings.SceneSettings) -> ShadowFrameState? {
        guard let inputs = ShadowFrameStateResolver.resolveInputs(renderSurfaceMode: renderSurfaceMode,
                                                                  projectionView: projectionView,
                                                                  cameraEye: cameraEye,
                                                                  centerWorldMercator: centerWorldMercator,
                                                                  flatRenderPan: flatRenderPan,
                                                                  renderMapSize: renderMapSize,
                                                                  scene: scene) else {
            return nil
        }
        if let fit, ShadowFrameStateResolver.fitCovers(fit: fit,
                                                       inputs: inputs,
                                                       radiusMargin: Self.radiusMargin) {
            return ShadowFrameStateResolver.materialize(fit: fit, inputs: inputs)
        }
        guard let freshFit = ShadowFrameStateResolver.resolveAnchoredFit(inputs: inputs,
                                                                         radiusMargin: Self.radiusMargin) else {
            fit = nil
            return nil
        }
        fit = freshFit
        fitGeneration &+= 1
        return ShadowFrameStateResolver.materialize(fit: freshFit, inputs: inputs)
    }

    /// The single render-or-reuse decision, made once per frame at pass
    /// planning. Returns true when the caster pass must run this frame, and
    /// then also records the render, so the next frames can reuse it.
    func planShadowRender(frameContext: FrameContext, texture: MTLTexture) -> Bool {
        planShadowRender(casterKeys: Self.casterKeys(tilePlacementState: frameContext.sharedState.tilePlacementState),
                         hasModelCasters: frameContext.sharedState.sceneModelState.hasShadowCasters,
                         texture: texture)
    }

    func planShadowRender(casterKeys: Set<CasterKey>,
                          hasModelCasters: Bool,
                          texture: MTLTexture) -> Bool {
        let needsRender = renderedGeneration != fitGeneration
            || renderedTextureIdentity != ObjectIdentifier(texture)
            // Scene models animate and move: with model casters in the frame
            // the map is re-rendered every frame, exactly as before.
            || hasModelCasters
            // Any change of the caster set: a caster arriving is not in the
            // rendered map, and a caster leaving may leave its shadows on
            // ground whose buildings are no longer drawn (a cell handing
            // over to a tile without buildings), so both re-render.
            || casterKeys != renderedCasterKeys
        guard needsRender else {
            return false
        }
        renderedGeneration = fitGeneration
        renderedTextureIdentity = ObjectIdentifier(texture)
        renderedCasterKeys = casterKeys
        return true
    }

    /// Every building caster the frame would rasterize: the building
    /// coverage's placements with buildings. The rendered map is reused
    /// only while this set is unchanged.
    static func casterKeys(tilePlacementState: TilePlacementState) -> Set<CasterKey> {
        var keys = Set<CasterKey>()
        for placement in tilePlacementState.buildingPlaceTilesContext.tilePlacements
        where placement.metalTile.tileBuffers.extruded.indicesCount > 0 {
            keys.insert(CasterKey(tile: ObjectIdentifier(placement.metalTile),
                                  placeIn: placement.placeIn.tile,
                                  loop: placement.placeIn.loop))
        }
        return keys
    }
}
