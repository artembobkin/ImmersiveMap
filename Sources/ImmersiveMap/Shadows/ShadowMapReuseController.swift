// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// Keeps the rendered shadow map alive across frames. The sun is static and
/// the buildings do not move, so a rendered window only goes stale when the
/// camera leaves its fitted window, the light or resolution changes, the
/// set of tiles with buildings changes, the buildings left out for models
/// or the models of the model tiles change, the terrain under the
/// mountains changes, or scene models (which animate) cast.
/// Everything else is the common case: the receivers keep sampling the map
/// rendered some frames ago, through matrices re-materialized for the
/// current pan, and the caster pass simply does not run.
///
/// Each window of the map (`ShadowCascadeSlot`) is fitted and recorded on
/// its own: the near window follows the camera closely and refits often,
/// the far one is wide and seldom does, and a refit of the near window
/// does not redraw the far one, whose casters are the many tiles of the
/// relief.
///
/// A fit is computed with an inflated receiver footprint (`radiusMargin`),
/// so the camera can travel and turn inside the rendered window for a while
/// before a refit; the fitted centre snaps to whole texels in pan-anchored
/// space, so a refit moves the window by whole texels and shadow edges do not
/// crawl. The window follows the view, so turning the camera spends that
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
        let worldWrap: Int8
    }

    /// What a rendered window holds, compared against the frame to decide
    /// whether its pass runs again.
    private struct RenderedWindow: Equatable {
        let fitGeneration: UInt64
        let textureIdentity: ObjectIdentifier
        let casterKeys: Set<CasterKey>
        let staticModelCasters: Set<StaticModelCasterKey>
        let hiddenBuildings: ReplacedBuildings
        let heightScales: SIMD2<Float>
        /// The mountains the window holds (`GroundReliefFrame.shadowSignature`).
        let terrain: GroundReliefFrame.ShadowSignature?
    }

    private var fits: [ShadowCascadeSlot: ShadowAnchoredFit] = [:]
    private var fitGenerations: [ShadowCascadeSlot: UInt64] = [:]
    private var rendered: [ShadowCascadeSlot: RenderedWindow] = [:]

    /// The per-frame shadow state: every window's cached fit
    /// re-materialized under the current pan when it still covers the
    /// frame, a fresh (margined) fit otherwise. Same inputs contract as
    /// `ShadowFrameStateResolver.resolve`.
    func resolveFrameState(renderSurfaceMode: ViewMode,
                           projectionView: matrix_float4x4,
                           cameraEye: SIMD3<Float>,
                           centerWorldMercator: SIMD2<Double>,
                           flatRenderPan: SIMD2<Double>,
                           renderMapSize: Double,
                           groundHeights: ClosedRange<Float>? = nil,
                           zoom: Double,
                           scene: ImmersiveMapSettings.SceneSettings) -> ShadowFrameState? {
        guard let inputs = ShadowFrameStateResolver.resolveInputs(renderSurfaceMode: renderSurfaceMode,
                                                                  projectionView: projectionView,
                                                                  cameraEye: cameraEye,
                                                                  centerWorldMercator: centerWorldMercator,
                                                                  flatRenderPan: flatRenderPan,
                                                                  renderMapSize: renderMapSize,
                                                                  groundHeights: groundHeights,
                                                                  zoom: zoom,
                                                                  scene: scene) else {
            return nil
        }
        for slot in ShadowCascadeSlot.allCases {
            // A window the frame has not got keeps no fit: when it is back
            // it is fitted afresh and its pass runs.
            guard inputs.cascade(slot) != nil else {
                fits[slot] = nil
                continue
            }
            if let fit = fits[slot], ShadowFrameStateResolver.fitCovers(fit: fit,
                                                                        inputs: inputs,
                                                                        slot: slot,
                                                                        radiusMargin: Self.radiusMargin) {
                continue
            }
            guard let freshFit = ShadowFrameStateResolver.resolveAnchoredFit(inputs: inputs,
                                                                             slot: slot,
                                                                             radiusMargin: Self.radiusMargin) else {
                fits[slot] = nil
                if slot == .near { return nil }
                continue
            }
            fits[slot] = freshFit
            fitGenerations[slot, default: 0] &+= 1
        }
        return ShadowFrameStateResolver.materialize(fits: fits, inputs: inputs)
    }

    /// The single render-or-reuse decision for one window, made once per
    /// frame at pass planning. Returns true when the window's caster pass
    /// must run this frame, and then also records the render, so the next
    /// frames can reuse it.
    func planShadowRender(frameContext: FrameContext, texture: MTLTexture, slot: ShadowCascadeSlot) -> Bool {
        let sceneModelState = frameContext.sharedState.sceneModelState
        return planShadowRender(casterKeys: Self.casterKeys(drawnPlacements: frameContext.sharedState.drawnBuildingPlacements),
                                hasModelCasters: sceneModelState.hasMovingShadowCasters,
                                staticModelCasters: sceneModelState.staticShadowCasters,
                                hiddenBuildings: sceneModelState.replacedBuildings,
                                heightScales: SIMD2<Float>(frameContext.sharedState.buildingRiseSignature,
                                                           frameContext.sharedState.modelTileRiseSignature),
                                terrain: frameContext.services.groundRelief?.shadowSignature,
                                texture: texture,
                                slot: slot)
    }

    /// `hasModelCasters` counts the models that can move. The models of the
    /// model tiles never do and come as `staticModelCasters`.
    func planShadowRender(casterKeys: Set<CasterKey>,
                          hasModelCasters: Bool,
                          staticModelCasters: Set<StaticModelCasterKey> = [],
                          hiddenBuildings: ReplacedBuildings = .none,
                          heightScales: SIMD2<Float> = SIMD2<Float>(1, 1),
                          terrain: GroundReliefFrame.ShadowSignature? = nil,
                          texture: MTLTexture,
                          slot: ShadowCascadeSlot = .near) -> Bool {
        let window = RenderedWindow(fitGeneration: fitGenerations[slot] ?? 0,
                                    textureIdentity: ObjectIdentifier(texture),
                                    casterKeys: casterKeys,
                                    staticModelCasters: staticModelCasters,
                                    hiddenBuildings: hiddenBuildings,
                                    heightScales: heightScales,
                                    terrain: terrain)
        // Scene models animate and move: with model casters in the frame
        // the window is re-rendered every frame, exactly as before.
        // Otherwise any difference from the rendered window: a fresh fit, a
        // recreated (blank) texture, a model of a model tile arriving or
        // leaving, a building left out or brought back for one, the
        // buildings and the models rising out of the ground or going when
        // the camera leaves their zoom (`ExtrusionRise`), the mountains (a
        // terrain tile arriving or welded, the rise, the datum the ground
        // is drawn from, which a pan over the relief moves), and any change
        // of the caster set: a caster arriving is not in the rendered map,
        // and a caster leaving may leave its shadows on ground whose
        // buildings are no longer drawn (a cell handing over to a tile
        // without buildings), so both re-render.
        let needsRender = hasModelCasters || rendered[slot] != window
        guard needsRender else {
            return false
        }
        rendered[slot] = window
        return true
    }

    /// Every building caster the frame rasterizes: the placements it draws
    /// buildings for (`FrameContextSharedState.drawnBuildingPlacements`).
    /// The rendered map is reused only while this set is unchanged.
    static func casterKeys(drawnPlacements: [PlaceTile]) -> Set<CasterKey> {
        var keys = Set<CasterKey>()
        for placement in drawnPlacements {
            keys.insert(CasterKey(tile: ObjectIdentifier(placement.metalTile),
                                  placeIn: placement.placeIn.tile,
                                  worldWrap: placement.placeIn.worldWrap))
        }
        return keys
    }
}
