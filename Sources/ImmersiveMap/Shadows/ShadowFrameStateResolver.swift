// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Fits the directional light's camera and produces the per-frame
/// `ShadowFrameState`. Pure input → output; runs once per frame in
/// `RenderFrameEngine.collectInput`.
///
/// There is one shadow window, fitted to a **pose-invariant disc** centered at
/// the flat world origin, the camera's look-at point
/// (`RenderCameraPoseResolver` orbits the origin). Its radius is a multiple of
/// the camera distance `|eye|`, which does not depend on pitch or bearing, so
/// tilting or rotating the camera changes nothing about the window: texel
/// world size, and therefore edge sharpness, stays constant. The price is
/// fitting a full disc instead of the camera frustum's footprint, and the
/// reach the single window can cover at a usable density: shadows end at
/// `coverageCameraDistances` and the eye-distance fade hides that edge.
///
/// Casters outside a disc are captured by extending the **near** plane towards
/// the light by `maxCasterHeight / L.z`: any caster occluding a receiver `r`
/// lies on the ray `r + t·L`, which projects to the same light-space XY as `r`.
///
/// The texel grid is stabilized so shadow edges do not crawl while the camera
/// moves: window sizes are power-of-two-quantized (integer-zoom
/// re-normalization scales them exactly in step with the world) and window
/// centers snap to whole texels in *pan-anchored* coordinates. Snapping in raw
/// world space would be wrong: `flatRenderState.pan` re-centers the world
/// around the camera every frame, so map content translates by
/// `(pan.x, -pan.y) · mapSize/2` and the grid must translate with it. That
/// snap mixes a camera-local center with a world-sized pan offset, so it is
/// computed in Double: at high zoom the offset reaches ~10^6 units where
/// Float ULP already exceeds a texel.
/// The fitted window, expressed in pan-anchored light-space
/// coordinates: the pieces that stay glued to the map content while
/// `flatRenderState.pan` re-centers the world around the camera every frame.
/// A fit can therefore outlive the frame it was computed on: materializing
/// it under a later pan rebuilds the world-space matrices for the SAME
/// content window, which is what lets a rendered shadow map be reused
/// across frames (`ShadowMapReuseController`).
struct ShadowCascadeAnchoredFit {
    /// Snapped window center in pan-anchored light-space X/Y (Double: the
    /// pan offset reaches ~10^6 world units at street zooms, past Float ULP).
    let anchoredCenterX: Double
    let anchoredCenterY: Double
    /// Quantized square window side in world units.
    let extent: Float
    /// Fitted depth window in pan-anchored light-space depth, already
    /// including the caster near extension and the far slack.
    let anchoredNearDepth: Double
    let anchoredFarDepth: Double
}

/// A full fitted shadow frame in pan-anchored form, plus the inputs it is
/// only valid for (light and resolution: either changing invalidates it).
struct ShadowAnchoredFit {
    let lightDirection: SIMD3<Float>
    let mapResolution: Int
    let window: ShadowCascadeAnchoredFit
}

enum ShadowFrameStateResolver {
    /// Below this light elevation (z of the normalized direction) shadows are
    /// dropped: near-horizontal light produces quasi-infinite shadows the
    /// cascade maps cannot represent.
    static let minimumLightDirectionZ: Float = 0.05
    /// Range `ShadowSettings.maxCasterHeightMeters` is clamped to. Receivers
    /// above the limit fall outside the fitted depth window, and taller
    /// casters are pancaked onto the near plane by the depth clamp.
    static let maxCasterHeightRange: ClosedRange<Float> = 10...500
    /// ...and never taller than this many window radii.
    ///
    /// The window must be wider than its own disc by `height * |L.xy| / L.z`,
    /// because that is how far a caster of that height throws its shadow into
    /// the disc. Under a sun 54 degrees up that is about 0.72 of the height,
    /// so a flat 1000 m cap adds ~720 m to every window no matter how small
    /// the disc is. At a street camera that addition was ten times the disc
    /// itself: the window stayed ~700 m wide however far the coverage was
    /// wound down, so coverage moved the fade and nothing else, and the shadow
    /// map's texels never got finer.
    ///
    /// Tying the cap to the radius makes coverage mean what it says at every
    /// zoom. What it costs is casters above the cap not reaching that window,
    /// which is the right trade by construction: a tower 700 m away throws
    /// nothing meaningful into a disc nine meters across. Ten radii leaves the
    /// full 1000 m in place at the shipping coverages and only bites where the
    /// window is deliberately wound down.
    static let maxCasterHeightWindowRadii: Float = 10
    /// Constant receiver bias, in shadow-map texels of depth slope. It is the
    /// only depth-side defense left: there is no receiver-plane gradient, so
    /// this has to cover the receiver's own depth variation across the
    /// bilinear tap's footprint. Keeping it as small as the look allows keeps
    /// shadows attached to building bases (any bias shrinks contact by ~its
    /// world size), and the normal offset carries what it cannot.
    static let receiverBiasTexels: Float = 1.0
    /// Floor for the bias at near-vertical light (horizontal slope → 0),
    /// in texels of depth, against numeric self-comparison on flat roofs.
    static let receiverBiasFloorTexels: Float = 0.15
    /// Range `ShadowSettings.normalOffsetTexels` is clamped to. Receivers with
    /// normals shift their sample point along the normal by that many window
    /// texels (see `ShadowCascadeUniform.normalOffsetWorld`).
    ///
    /// There is no meter cap: the window is sized to the camera distance, so
    /// the offset is always the same fraction of it (and so a roughly constant
    /// size on screen) instead of growing without bound the way a fixed
    /// far-cascade window used to. The cost is exact and worth knowing: an
    /// occluder closer to a wall than the offset stops shadowing it, which at
    /// street zooms is under a meter and only reaches a few meters when the
    /// camera is high enough that such gaps are a pixel or two wide.
    static let normalOffsetTexelsRange: ClosedRange<Float> = 0...8
    /// Grazing-wall cutoff of the geometric self-shadow test, in N·L; mirrors
    /// `kShadowGeometricCutoffStart` / `kShadowGeometricCutoffEnd` in
    /// RenderUniforms.h (pinned by `ShadowFrameStateResolverTests`). Below the
    /// start a face is declared self-shadowed instead of sampled: its depth
    /// varies by more than a texel across the receiver, which neither the
    /// constant bias nor the normal offset can cover once the receiver-plane
    /// gradient is gone.
    static let geometricCutoffStart: Float = 0.18
    static let geometricCutoffEnd: Float = 0.35
    /// Range `ShadowSettings.softness` is clamped to: the factor the tent's
    /// four taps are pushed out by, about the sample point (see
    /// `shadowWindowVisibility`). 1 is the plain 3x3 tent.
    ///
    /// The ceiling is what the tap positions stay honest at. The weights are
    /// the exact 3x3 tent's, so spreading the taps without recomputing them
    /// drifts the reconstructed kernel away from a tent; well past this the
    /// four lobes start to read as a cross in the ramp. It is also what
    /// `uvInsetTexels` is sized for.
    static let softnessRange: ClosedRange<Float> = 1...2.5
    /// Sampling-rectangle inset in texels: keeps the tent's taps inside the
    /// fitted window, at the widest spread `softnessRange` allows.
    ///
    /// A tap sits at most one texel from the sample point before the spread
    /// (the offsets `u0`/`u1` reach exactly 1 at their extremes), so at most
    /// `softnessRange.upperBound` after it, and its own bilinear footprint
    /// adds half a texel. Pinned by `ShadowFrameStateResolverTests`.
    static let uvInsetTexels: Float = 4.0
    static let mapResolutionRange: ClosedRange<Int> = 256...4096
    /// Range `ShadowSettings.coverageCameraDistances` is clamped to. The floor
    /// is far below anything worth shipping on purpose: it is what lets the
    /// debug panel wind the window right down and look at the texel grid
    /// itself. See `fadeDistances` for what happens under a coverage of 1.
    static let coverageRange: ClosedRange<Float> = 0.25...48

    struct CascadeSpec {
        let radius: Float
        let maxCasterHeight: Float
    }

    /// The window this frame asks for: one disc, sized by
    /// `coverageCameraDistances`, with the caster-height cap in world units.
    static func windowSpec(cameraDistance: Float,
                           unitsPerMeter: Double,
                           coverageCameraDistances: Float,
                           maxCasterHeightMeters: Float) -> CascadeSpec {
        let coverage = min(max(coverageCameraDistances, coverageRange.lowerBound),
                           coverageRange.upperBound)
        let radius = coverage * cameraDistance
        let limit = min(max(maxCasterHeightMeters, maxCasterHeightRange.lowerBound),
                        maxCasterHeightRange.upperBound)
        return CascadeSpec(radius: radius,
                           maxCasterHeight: min(Float(Double(limit) * unitsPerMeter),
                                                maxCasterHeightWindowRadii * radius))
    }

    /// Where shadows finish fading out, and where the band before it starts,
    /// as radial distances from the window's centre.
    ///
    /// The window's own radius, always: the band is the outer quarter of the
    /// fitted disc, so the window's edge is never reached and never shows as a
    /// circle, at any coverage. This works only because the fade is measured
    /// from the same point the window is fitted around. Measuring it from the
    /// eye (as it was) described a different shape: it made the fade depend on
    /// pitch, which is exactly what the pose-invariant disc exists to prevent,
    /// and once the radius dropped under one camera distance the whole band
    /// lay in front of the nearest visible ground, so every shadow in the
    /// frame vanished instead of an edge being hidden.
    static func fadeDistances(farRadius: Float) -> (start: Float, end: Float) {
        (farRadius * 0.75, farRadius)
    }

    /// Everything the fit and the materialization derive from the frame:
    /// resolved once per frame, shared by `resolveAnchoredFit`,
    /// `materialize` and `fitCovers` so the three can never disagree.
    struct FitInputs {
        let lightDirection: SIMD3<Float>
        let lightView: matrix_float4x4
        let cameraEye: SIMD3<Float>
        let unitsPerMeter: Double
        let mapResolution: Int
        let farRadius: Float
        let spec: CascadeSpec
        /// The visible ground the window has to cover, in flat world XY.
        let footprint: [SIMD2<Float>]
        let normalOffsetTexels: Float
        /// Tap spread of the tent, clamped to `softnessRange`.
        let softness: Float
        let panShift: SIMD3<Double>
        let strength: Float
        let tint: SIMD3<Float>
    }

    static func resolveInputs(renderSurfaceMode: ViewMode,
                              projectionView: matrix_float4x4,
                              cameraEye: SIMD3<Float>,
                              centerWorldMercator: SIMD2<Double>,
                              flatRenderPan: SIMD2<Double>,
                              renderMapSize: Double,
                              scene: ImmersiveMapSettings.SceneSettings) -> FitInputs? {
        guard renderSurfaceMode == .flat,
              scene.shadows.isEnabled,
              scene.shadows.strength > 0 else {
            return nil
        }

        let requestedDirection = scene.light.direction
        guard simd_length_squared(requestedDirection) > 1e-8 else { return nil }
        let lightDirection = simd_normalize(requestedDirection)
        guard lightDirection.x.isFinite, lightDirection.y.isFinite, lightDirection.z.isFinite,
              lightDirection.z >= minimumLightDirectionZ else {
            return nil
        }

        let cameraDistance = simd_length(cameraEye)
        guard cameraDistance > 1e-4, cameraDistance.isFinite else { return nil }

        let latitudeRadians = ImmersiveMapProjection.latitude(fromNormalizedWorldY: centerWorldMercator.y)
        let unitsPerMeter = ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: latitudeRadians,
                                                                      renderMapSize: renderMapSize)
        guard unitsPerMeter > 0, unitsPerMeter.isFinite else { return nil }

        let mapResolution = min(max(scene.shadows.mapResolution, mapResolutionRange.lowerBound),
                                mapResolutionRange.upperBound)

        // The light view is anchored at the world origin: its basis and
        // translation depend only on the light direction, so light-space
        // coordinates of fixed content stay frame-coherent for the texel snap.
        let up: SIMD3<Float> = abs(lightDirection.z) > 0.99
            ? SIMD3<Float>(0, 1, 0)
            : SIMD3<Float>(0, 0, 1)
        let lightView = Matrix.lookAt(eye: lightDirection, center: .zero, up: up)

        let spec = windowSpec(cameraDistance: cameraDistance,
                              unitsPerMeter: unitsPerMeter,
                              coverageCameraDistances: scene.shadows.coverageCameraDistances,
                              maxCasterHeightMeters: scene.shadows.maxCasterHeightMeters)

        let halfMapSize = renderMapSize * 0.5
        let panShift = SIMD3<Double>(flatRenderPan.x * halfMapSize,
                                     -flatRenderPan.y * halfMapSize,
                                     0)

        let footprint = visibleGroundFootprint(inverseProjectionView: simd_inverse(projectionView),
                                               cameraEye: cameraEye,
                                               maxDistance: spec.radius)
        guard footprint.isEmpty == false else { return nil }

        let normalOffsetTexels = min(max(scene.shadows.normalOffsetTexels,
                                         normalOffsetTexelsRange.lowerBound),
                                     normalOffsetTexelsRange.upperBound)

        return FitInputs(lightDirection: lightDirection,
                         lightView: lightView,
                         cameraEye: cameraEye,
                         unitsPerMeter: unitsPerMeter,
                         mapResolution: mapResolution,
                         farRadius: spec.radius,
                         spec: spec,
                         footprint: footprint,
                         normalOffsetTexels: normalOffsetTexels,
                         softness: min(max(scene.shadows.softness, softnessRange.lowerBound),
                                       softnessRange.upperBound),
                         panShift: panShift,
                         strength: min(max(scene.shadows.strength, 0), 1),
                         tint: simd_clamp(scene.shadows.tint,
                                          SIMD3<Float>(repeating: 0),
                                          SIMD3<Float>(repeating: 1)))
    }

    static func resolve(renderSurfaceMode: ViewMode,
                        projectionView: matrix_float4x4,
                        cameraEye: SIMD3<Float>,
                        centerWorldMercator: SIMD2<Double>,
                        flatRenderPan: SIMD2<Double>,
                        renderMapSize: Double,
                        scene: ImmersiveMapSettings.SceneSettings) -> ShadowFrameState? {
        guard let inputs = resolveInputs(renderSurfaceMode: renderSurfaceMode,
                                         projectionView: projectionView,
                                         cameraEye: cameraEye,
                                         centerWorldMercator: centerWorldMercator,
                                         flatRenderPan: flatRenderPan,
                                         renderMapSize: renderMapSize,
                                         scene: scene),
              let fit = resolveAnchoredFit(inputs: inputs, radiusMargin: 1.0) else {
            return nil
        }
        return materialize(fit: fit, inputs: inputs)
    }

    /// The ground the camera can actually see, in flat world XY.
    ///
    /// The window is fitted to this instead of to a disc around the look-at
    /// point. A disc has to reach as far as the farthest visible ground, and
    /// then covers just as much ground *behind* the camera, which nobody is
    /// looking at: at a tilted camera that was half the window's side spent on
    /// nothing, and the texels went with it.
    ///
    /// The price is that the window now depends on where the camera points, so
    /// turning changes the fitted rectangle and, with it, the texel grid. That
    /// is the trade the disc was originally chosen to avoid; `radiusMargin`
    /// and the texel snap still keep the grid still while the camera travels
    /// inside a fit.
    ///
    /// Corner and edge rays of the view frustum are intersected with z = 0.
    /// A ray that passes above the horizon never meets the plane, and one that
    /// meets it kilometres out would size the window for ground the fade has
    /// already taken to nothing, so every point is clamped to `maxDistance`
    /// horizontally from the camera. That clamp is a circle around the camera,
    /// which is exactly what the fade hides.
    static func visibleGroundFootprint(inverseProjectionView: matrix_float4x4,
                                       cameraEye: SIMD3<Float>,
                                       maxDistance: Float) -> [SIMD2<Float>] {
        guard maxDistance > 0, maxDistance.isFinite else { return [] }

        let cameraGround = SIMD2<Float>(cameraEye.x, cameraEye.y)
        var points: [SIMD2<Float>] = []
        // The NDC boundary, sampled rather than just cornered: clamping turns
        // the far edge into an arc, whose extremes are not at the corners.
        let samplesPerEdge = 4
        let edges: [(SIMD2<Float>, SIMD2<Float>)] = [
            (SIMD2<Float>(-1, -1), SIMD2<Float>(1, -1)),
            (SIMD2<Float>(1, -1), SIMD2<Float>(1, 1)),
            (SIMD2<Float>(1, 1), SIMD2<Float>(-1, 1)),
            (SIMD2<Float>(-1, 1), SIMD2<Float>(-1, -1))
        ]
        for (from, to) in edges {
            for step in 0..<samplesPerEdge {
                let t = Float(step) / Float(samplesPerEdge)
                let ndc = from + (to - from) * t
                guard let ground = groundPoint(ndc: ndc,
                                               inverseProjectionView: inverseProjectionView,
                                               cameraGround: cameraGround,
                                               maxDistance: maxDistance) else {
                    continue
                }
                points.append(ground)
            }
        }
        return points
    }

    /// One NDC point's ground position, clamped into the coverage circle.
    private static func groundPoint(ndc: SIMD2<Float>,
                                    inverseProjectionView: matrix_float4x4,
                                    cameraGround: SIMD2<Float>,
                                    maxDistance: Float) -> SIMD2<Float>? {
        func unproject(_ depth: Float) -> SIMD3<Float>? {
            let clip = SIMD4<Float>(ndc.x, ndc.y, depth, 1)
            let world = inverseProjectionView * clip
            guard abs(world.w) > 1e-9 else { return nil }
            return SIMD3<Float>(world.x, world.y, world.z) / world.w
        }
        guard let near = unproject(0), let far = unproject(1) else { return nil }

        let direction = far - near
        let horizontal = SIMD2<Float>(direction.x, direction.y)
        guard simd_length_squared(horizontal) > 1e-20 else { return nil }

        // Above the horizon the ray never reaches the ground: take the
        // coverage circle in the direction it was heading, so the window still
        // covers everything up to the fade.
        var hit = cameraGround + simd_normalize(horizontal) * maxDistance
        if abs(direction.z) > 1e-9 {
            let t = -near.z / direction.z
            if t > 0, t <= 1 {
                let ground = near + direction * t
                hit = SIMD2<Float>(ground.x, ground.y)
            }
        }
        let offset = hit - cameraGround
        let distance = simd_length(offset)
        if distance > maxDistance, distance > 1e-9 {
            hit = cameraGround + offset * (maxDistance / distance)
        }
        guard hit.x.isFinite, hit.y.isFinite else { return nil }
        return hit
    }

    /// Raw light-space extremes of the receiver volume: the footprint at the
    /// ground and lifted to the caster-height cap. Shared by the fit (which
    /// quantizes a window around them) and by the coverage check of a cached
    /// fit (which asks whether they still land inside the fitted window).
    struct CascadeExtremes {
        let minX: Float
        let maxX: Float
        let minY: Float
        let maxY: Float
        let minDepth: Float
        let maxDepth: Float
    }

    static func cascadeExtremes(footprint: [SIMD2<Float>],
                                maxCasterHeight: Float,
                                lightView: matrix_float4x4) -> CascadeExtremes? {
        guard footprint.isEmpty == false,
              maxCasterHeight > 0, maxCasterHeight.isFinite else {
            return nil
        }

        var minX = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        var minDepth = Float.greatestFiniteMagnitude
        var maxDepth = -Float.greatestFiniteMagnitude
        // The lifted copies matter for the light-space extent, which grows
        // with the horizontal light tilt: a caster that tall standing on the
        // footprint's rim still has to be inside the window.
        for point in footprint {
            for z in [Float(0), maxCasterHeight] {
                let view = lightView * SIMD4<Float>(point.x, point.y, z, 1)
                minX = min(minX, view.x)
                maxX = max(maxX, view.x)
                minY = min(minY, view.y)
                maxY = max(maxY, view.y)
                let depth = -view.z
                minDepth = min(minDepth, depth)
                maxDepth = max(maxDepth, depth)
            }
        }
        guard maxX - minX > 1e-6, maxY - minY > 1e-6,
              minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite,
              minDepth.isFinite, maxDepth.isFinite else {
            return nil
        }
        return CascadeExtremes(minX: minX, maxX: maxX, minY: minY, maxY: maxY,
                               minDepth: minDepth, maxDepth: maxDepth)
    }

    /// The footprint inflated about the camera, which is the travel slack the
    /// reuse controller spends: the camera can move and turn inside it before
    /// the fit stops covering the frame.
    static func inflated(footprint: [SIMD2<Float>],
                         about cameraGround: SIMD2<Float>,
                         margin: Float) -> [SIMD2<Float>] {
        guard margin != 1 else { return footprint }
        return footprint.map { cameraGround + ($0 - cameraGround) * margin }
    }

    /// Light-space pan projections: how the pan shift reads along each
    /// light-view axis, in Double (see the type comment on the snap).
    private static func panProjections(lightView: matrix_float4x4,
                                       panShift: SIMD3<Double>) -> (x: Double, y: Double, depth: Double) {
        let lightRowX = SIMD3<Double>(Double(lightView[0][0]), Double(lightView[1][0]), Double(lightView[2][0]))
        let lightRowY = SIMD3<Double>(Double(lightView[0][1]), Double(lightView[1][1]), Double(lightView[2][1]))
        // depth = -view.z, so the depth axis is the negated view-z row.
        let lightRowDepth = SIMD3<Double>(-Double(lightView[0][2]), -Double(lightView[1][2]), -Double(lightView[2][2]))
        return (simd_dot(lightRowX, panShift),
                simd_dot(lightRowY, panShift),
                simd_dot(lightRowDepth, panShift))
    }

    /// Fits the window and returns it in pan-anchored form.
    /// `radiusMargin` inflates the receiver discs before fitting: the slack
    /// is what lets `ShadowMapReuseController` keep a rendered map alive
    /// while the camera travels inside it. `resolve` (and its tests) fit
    /// with margin 1.0, which reproduces the historical frame-exact fit.
    static func resolveAnchoredFit(inputs: FitInputs, radiusMargin: Float) -> ShadowAnchoredFit? {
        let pan = panProjections(lightView: inputs.lightView, panShift: inputs.panShift)
        let cameraGround = SIMD2<Float>(inputs.cameraEye.x, inputs.cameraEye.y)
        let fitFootprint = inflated(footprint: inputs.footprint,
                                    about: cameraGround,
                                    margin: radiusMargin)
        guard let extremes = cascadeExtremes(footprint: fitFootprint,
                                             maxCasterHeight: inputs.spec.maxCasterHeight,
                                             lightView: inputs.lightView) else {
            return nil
        }
        let spec = inputs.spec

        // Square quantized window: the raw extent varies smoothly with the
        // zoom fraction, and letting the texel size follow it makes shadow
        // edges crawl. Quantizing in √2 steps keeps the grid constant between
        // rare re-anchor steps while capping the density overshoot at 1.41×
        // (a plain pow2 wastes up to 2×), and integer-zoom re-normalization
        // scales it exactly ×2 (two √2 steps), so grid lines stay glued to the
        // map content.
        // Margin: 2 × 4-texel uv inset + 1 texel for the half-texel center
        // snap on each axis, so the disc rim always stays inside the inset
        // sampling rectangle even when quantization lands exactly on the
        // needed size.
        let neededExtent = max(extremes.maxX - extremes.minX,
                               extremes.maxY - extremes.minY) * (1.0 + 10.0 / Float(inputs.mapResolution))
        guard neededExtent > 0, neededExtent.isFinite else { return nil }
        let extent = pow(2.0, ceil(log2(neededExtent) * 2.0) / 2.0)
        let texelWorldSize = extent / Float(inputs.mapResolution)

        // Snap the window center to whole texels in pan-anchored space (see
        // the type comment): content world positions are `anchored + panShift`,
        // so the snapped quantity is `center - R·panShift`, evaluated in Double.
        let texelWorldDouble = Double(texelWorldSize)
        func snapToTexelGrid(center: Float, panShiftLight: Double) -> Double {
            let anchored = Double(center) - panShiftLight
            return (anchored / texelWorldDouble).rounded() * texelWorldDouble
        }
        let anchoredCenterX = snapToTexelGrid(center: (extremes.minX + extremes.maxX) * 0.5,
                                              panShiftLight: pan.x)
        let anchoredCenterY = snapToTexelGrid(center: (extremes.minY + extremes.maxY) * 0.5,
                                              panShiftLight: pan.y)

        let near = extremes.minDepth - spec.maxCasterHeight / inputs.lightDirection.z
        // Scale-proportional slack (the old absolute 0.01 vanished next to
        // world sizes that grow 2^zoom).
        let far = extremes.maxDepth + max(0.01, 2.0 * texelWorldSize)
        let window = ShadowCascadeAnchoredFit(anchoredCenterX: anchoredCenterX,
                                              anchoredCenterY: anchoredCenterY,
                                              extent: extent,
                                              anchoredNearDepth: Double(near) - pan.depth,
                                              anchoredFarDepth: Double(far) - pan.depth)
        return ShadowAnchoredFit(lightDirection: inputs.lightDirection,
                                 mapResolution: inputs.mapResolution,
                                 window: window)
    }

    /// Whether a cached fit still serves the current frame: same light and
    /// resolution, the receiver volume inside the fitted window (with the
    /// uv-inset margin the tap needs), and the window no coarser than a fresh
    /// fit would be by more than the quantization step (else the shadows would
    /// stay visibly softer than a refit while zooming in).
    static func fitCovers(fit: ShadowAnchoredFit, inputs: FitInputs, radiusMargin: Float) -> Bool {
        guard fit.lightDirection == inputs.lightDirection,
              fit.mapResolution == inputs.mapResolution else {
            return false
        }
        let pan = panProjections(lightView: inputs.lightView, panShift: inputs.panShift)
        let resolution = Float(fit.mapResolution)
        let spec = inputs.spec
        guard let extremes = cascadeExtremes(footprint: inputs.footprint,
                                             maxCasterHeight: spec.maxCasterHeight,
                                             lightView: inputs.lightView) else {
            return false
        }
        let window = fit.window
        let texelWorldSize = window.extent / resolution
        let usableHalfExtent = window.extent * 0.5 - (uvInsetTexels + 1.0) * texelWorldSize
        let centerX = Float(window.anchoredCenterX + pan.x)
        let centerY = Float(window.anchoredCenterY + pan.y)
        guard extremes.minX >= centerX - usableHalfExtent,
              extremes.maxX <= centerX + usableHalfExtent,
              extremes.minY >= centerY - usableHalfExtent,
              extremes.maxY <= centerY + usableHalfExtent else {
            return false
        }
        let near = Float(window.anchoredNearDepth + pan.depth)
        let far = Float(window.anchoredFarDepth + pan.depth)
        let requiredNear = extremes.minDepth - spec.maxCasterHeight / inputs.lightDirection.z
        guard requiredNear >= near, extremes.maxDepth <= far else {
            return false
        }
        // Sharpness: a fresh fit would quantize a window for the margined
        // disc; if the cached window is more than one √2 quantum above
        // that, the refit would be visibly sharper, so take it.
        let neededExtent = max(extremes.maxX - extremes.minX,
                               extremes.maxY - extremes.minY)
            * radiusMargin * (1.0 + 10.0 / resolution)
        return window.extent <= neededExtent * sqrt(2.0) * 1.001
    }

    /// Rebuilds the frame's world-space matrix and sampling uniform from a
    /// pan-anchored fit: the window follows the pan by whole construction
    /// (its center was snapped in pan-anchored space), so a shadow map
    /// rendered under one pan reads back correctly under any later pan for
    /// which `fitCovers` still holds.
    static func materialize(fit: ShadowAnchoredFit, inputs: FitInputs) -> ShadowFrameState? {
        guard fit.lightDirection == inputs.lightDirection,
              fit.mapResolution == inputs.mapResolution else {
            return nil
        }
        let pan = panProjections(lightView: inputs.lightView, panShift: inputs.panShift)
        let resolution = Float(fit.mapResolution)

        let window = fit.window
        let extent = window.extent
        let texelWorldSize = extent / resolution
        let centerX = Float(window.anchoredCenterX + pan.x)
        let centerY = Float(window.anchoredCenterY + pan.y)
        let halfExtent = extent * 0.5
        let near = Float(window.anchoredNearDepth + pan.depth)
        let far = Float(window.anchoredFarDepth + pan.depth)

        let lightProjection = Matrix.metalOrthographicMatrix(left: centerX - halfExtent,
                                                             right: centerX + halfExtent,
                                                             bottom: centerY - halfExtent,
                                                             top: centerY + halfExtent,
                                                             near: near,
                                                             far: far)
        let lightProjectionView = lightProjection * inputs.lightView

        // NDC → the shadow map: u = 0.5x + 0.5, v = -0.5y + 0.5 (Metal
        // texture origin is top-left); z passes through as the comparison
        // depth.
        let uvBias = matrix_float4x4(
            SIMD4<Float>(0.5, 0.0, 0.0, 0.0),
            SIMD4<Float>(0.0, -0.5, 0.0, 0.0),
            SIMD4<Float>(0.0, 0.0, 1.0, 0.0),
            SIMD4<Float>(0.5, 0.5, 0.0, 1.0)
        )

        // Receiver bias, normalized by the depth window and scaled by the
        // steeper of the two slopes the light makes with the ground, so a low
        // sun (long depth run across a texel) biases more than a high one.
        // With no receiver-plane gradient this is the whole depth-side
        // defense; the normal offset carries the rest.
        let depthWindow = max(far - near, 1e-6)
        let horizontalSlope = simd_length(SIMD2<Float>(inputs.lightDirection.x,
                                                       inputs.lightDirection.y)) / inputs.lightDirection.z
        let steepestSlope = max(horizontalSlope, 1.0 / max(horizontalSlope, 1e-3))
        let depthBias = (receiverBiasTexels * min(steepestSlope, 2.0) + receiverBiasFloorTexels)
            * texelWorldSize / depthWindow

        let texelUV = SIMD2<Float>(repeating: 1.0 / resolution)
        let inset = uvInsetTexels * texelUV
        let cascade = ShadowCascadeUniform(worldToShadowTexture: uvBias * lightProjectionView,
                                           tentSpread: inputs.softness,
                                           depthBias: depthBias,
                                           uvMinimum: inset,
                                           uvMaximum: SIMD2<Float>(1, 1) - inset,
                                           normalOffsetWorld: inputs.normalOffsetTexels * texelWorldSize,
                                           texelSizeUV: texelUV)

        let fade = fadeDistances(farRadius: inputs.farRadius)
        let uniform = ShadowUniform(cascade: cascade,
                                    eye: inputs.cameraEye,
                                    strength: inputs.strength,
                                    fadeStartDistance: fade.start,
                                    fadeEndDistance: fade.end,
                                    lightDirection: inputs.lightDirection,
                                    tint: inputs.tint,
                                    // The footprint is clamped to a circle
                                    // around the camera, so that circle is the
                                    // only window edge a viewer can reach, and
                                    // the fade has to be measured from there.
                                    fadeCenter: SIMD2<Float>(inputs.cameraEye.x,
                                                             inputs.cameraEye.y))
        return ShadowFrameState(lightProjectionView: lightProjectionView,
                                shadowUniform: uniform,
                                mapResolution: fit.mapResolution)
    }
}
