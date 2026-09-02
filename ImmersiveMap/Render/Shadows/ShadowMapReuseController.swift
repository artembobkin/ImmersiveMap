// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// Keeps the rendered shadow map alive across frames. The sun is static and
/// the buildings do not move, so a rendered cascade atlas only goes stale
/// when the camera leaves the fitted windows, the light or resolution
/// changes, a new caster tile arrives, or scene models (which animate) cast.
/// Everything else is the common case: the receivers keep sampling the map
/// rendered some frames ago, through matrices re-materialized for the
/// current pan, and the whole caster pass simply does not run.
///
/// The fit is computed with an inflated receiver disc (`radiusMargin`), so
/// the camera can travel inside the rendered windows for a while before a
/// refit; the fitted centers snap to whole texels in pan-anchored space, so
/// a refit moves the windows by whole texels and shadow edges do not crawl.
final class ShadowMapReuseController {
    /// Disc inflation of the fit. The slack is travel budget: ~10% of the
    /// near-disc radius before the fastest-moving window needs a refit. The
    /// price is up to 10% coarser texels than a frame-exact fit, on top of
    /// the √2 quantization the fit always had.
    static let radiusMargin: Float = 1.1

    /// One caster's identity in the rendered map: the parsed tile object
    /// (re-parsing the same coordinates makes a new object, which correctly
    /// reads as a new caster) in one world-wrap copy.
    struct CasterKey: Hashable {
        let tile: ObjectIdentifier
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
                           cameraEye: SIMD3<Float>,
                           centerWorldMercator: SIMD2<Double>,
                           flatRenderPan: SIMD2<Double>,
                           renderMapSize: Double,
                           scene: ImmersiveMapSettings.SceneSettings) -> ShadowFrameState? {
        guard let inputs = ShadowFrameStateResolver.resolveInputs(renderSurfaceMode: renderSurfaceMode,
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
            || casterKeys.isSubset(of: renderedCasterKeys) == false
        guard needsRender else {
            return false
        }
        renderedGeneration = fitGeneration
        renderedTextureIdentity = ObjectIdentifier(texture)
        renderedCasterKeys = casterKeys
        return true
    }

    /// Every building caster the frame would rasterize: the visible
    /// placements plus the sun-ward strip. A tile leaving the set never
    /// invalidates (its image is already baked and its shadows can no longer
    /// reach the frame); a tile not yet in the rendered map always does.
    static func casterKeys(tilePlacementState: TilePlacementState) -> Set<CasterKey> {
        var keys = Set<CasterKey>()
        for context in [tilePlacementState.placeTilesContext,
                        tilePlacementState.shadowCasterPlaceTilesContext] {
            for placement in context.tilePlacements
            where placement.metalTile.tileBuffers.extruded.indicesCount > 0 {
                keys.insert(CasterKey(tile: ObjectIdentifier(placement.metalTile),
                                      loop: placement.placeIn.loop))
            }
        }
        return keys
    }
}
