// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Computes the sun-ward sweep that widens tile coverage for the shadow pass.
///
/// The cascade windows are fitted to discs far wider than the viewport, but a
/// caster can only rasterize into them if its tile is resolved, demanded, and
/// placed. Coverage that stops at the visible frustum drops every building
/// standing between the frame and the sun just outside the screen edge, so
/// their shadows pop in and out of the frame while the camera pans. Sweeping
/// the coverage polygon by this offset adds exactly the strip of tiles whose
/// buildings can still cast into the frame: a caster shadowing a receiver `r`
/// lies on the sun ray `r + t·L`, so the caster area is the receiver area
/// swept by `t_max · L.xy` with `t_max = casterHeight / L.z`.
enum ShadowCasterSweepResolver {
    /// Cap on the caster height the sweep accounts for, in meters. Matches the
    /// middle-cascade caster cap: it covers real towers just outside the
    /// viewport at street zooms, while keeping the sweep to roughly one tile.
    /// A rare taller caster can still pop at the frustum edge; widening for it
    /// would tax every frame for a case the far cascade's fade already softens.
    static let maxCasterHeightMeters = ShadowFrameStateResolver.middleCascadeMaxCasterHeightMeters

    /// World-space offset (render units) to sweep the coverage polygon by, or
    /// nil when the shadow pass cannot run (globe, shadows disabled, sun too
    /// low): then the visible coverage needs no widening.
    static func resolve(renderSurfaceMode: ViewMode,
                        scene: ImmersiveMapSettings.SceneSettings,
                        centerWorldMercator: SIMD2<Double>,
                        renderMapSize: Double) -> SIMD2<Float>? {
        guard renderSurfaceMode == .flat,
              scene.shadows.isEnabled,
              scene.shadows.strength > 0 else {
            return nil
        }

        let requestedDirection = scene.light.direction
        guard simd_length_squared(requestedDirection) > 1e-8 else { return nil }
        let lightDirection = simd_normalize(requestedDirection)
        guard lightDirection.x.isFinite, lightDirection.y.isFinite, lightDirection.z.isFinite,
              lightDirection.z >= ShadowFrameStateResolver.minimumLightDirectionZ else {
            return nil
        }

        let latitudeRadians = ImmersiveMapProjection.latitude(fromNormalizedWorldY: centerWorldMercator.y)
        let unitsPerMeter = ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: latitudeRadians,
                                                                      renderMapSize: renderMapSize)
        guard unitsPerMeter > 0, unitsPerMeter.isFinite else { return nil }

        let casterHeightWorld = Float(maxCasterHeightMeters * unitsPerMeter)
        let sunRayLength = casterHeightWorld / lightDirection.z
        let sweep = SIMD2<Float>(lightDirection.x, lightDirection.y) * sunRayLength
        guard sweep.x.isFinite, sweep.y.isFinite else { return nil }
        return sweep
    }
}
