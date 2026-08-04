// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Fits the directional light's two cascade cameras and produces the per-frame
/// `ShadowFrameState`. Pure input → output; runs once per frame in
/// `RenderFrameEngine.collectInput`.
///
/// Both cascades are fitted to **pose-invariant discs** centered at the flat
/// world origin, the camera's look-at point (`RenderCameraPoseResolver` orbits
/// the origin). Disc radii are multiples of the camera distance `|eye|`, which
/// does not depend on pitch or bearing, so tilting or rotating the camera
/// changes nothing about the shadow windows: texel world size, and therefore
/// edge sharpness, stays constant. The price is fitting a full disc instead
/// of the camera frustum's footprint; the near cascade keeps density where it
/// matters, the far cascade covers the rest coarsely.
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
enum ShadowFrameStateResolver {
    /// Below this light elevation (z of the normalized direction) shadows are
    /// dropped: near-horizontal light produces quasi-infinite shadows the
    /// cascade maps cannot represent.
    static let minimumLightDirectionZ: Float = 0.05
    /// Cascade disc radii in camera distances. Near is the crisp contact
    /// zone; middle covers where most visible shadows land at a tilted
    /// camera (far-cascade texels there would visibly wobble diagonal
    /// edges); far is the coverage/fade zone.
    static let nearCascadeRadiusCameraDistances: Float = 1.0
    static let middleCascadeRadiusCameraDistances: Float = 3.0
    /// Caster-height caps per cascade. The tighter caps on the closer
    /// cascades keep their windows (and texels) small: receivers above a cap
    /// simply fall through to the next cascade in the sampling chain, and
    /// taller casters are pancaked onto the near plane by the depth clamp.
    static let nearCascadeMaxCasterHeightMeters = 300.0
    static let middleCascadeMaxCasterHeightMeters = 500.0
    static let farCascadeMaxCasterHeightMeters = 1000.0
    /// Constant receiver bias measured in shadow-map texels of depth slope.
    /// The receiver-plane bias in `sampleShadowFactor` predicts each tap's own
    /// plane depth, so the constant part only needs to cover storage
    /// quantization and derivative error; keeping it small keeps shadows
    /// attached to building bases (any bias shrinks contact by ~its world size).
    static let receiverBiasTexels: Float = 0.5
    /// Floor for the bias at near-vertical light (horizontal slope → 0),
    /// in texels of depth, against numeric self-comparison on flat roofs.
    static let receiverBiasFloorTexels: Float = 0.15
    /// Cap (in surface-slope units, depth per world unit of light-space XY)
    /// for the receiver-plane gradient. It must admit the steepest *lit* wall:
    /// the geometric self-shadow threshold (N·L = 0.15) lets through walls
    /// with depth slope up to cot(asin(0.15)) ≈ 6.6, an under-clamped
    /// gradient mispredicts their plane and stripes them with acne. 8 covers
    /// that with margin while still bounding garbage silhouette derivatives.
    static let gradientClampMaxSlope: Float = 8.0
    /// Receivers with normals shift their sample point along the normal by
    /// this many cascade texels (see ShadowCascadeUniform.normalOffsetWorld)…
    static let normalOffsetTexels: Float = 1.5
    /// …capped in ground meters: 1.5 far-cascade texels can reach 10+ meters,
    /// which would push wall receivers past real neighboring occluders and
    /// delete their received shadows. Acne beyond the cap is handled by the
    /// slope-proportional per-tap bias instead.
    static let normalOffsetMetersCap = 2.5
    // (The PCF filter is a fixed 3x3 Castaño tent in the shader, an
    // orientation-independent ~2-texel edge; no per-cascade kernel radius.)
    /// Sampling-rectangle inset per cascade, in texels: keeps kernel taps from
    /// bleeding across the atlas seam or the window border.
    static let uvInsetTexels: Float = 4.0
    static let mapResolutionRange: ClosedRange<Int> = 256...4096

    private struct CascadeSpec {
        let radius: Float
        let maxCasterHeight: Float
        let atlasIndex: Int
    }

    static func resolve(renderSurfaceMode: ViewMode,
                        cameraEye: SIMD3<Float>,
                        centerWorldMercator: SIMD2<Double>,
                        flatRenderPan: SIMD2<Double>,
                        renderMapSize: Double,
                        scene: ImmersiveMapSettings.SceneSettings) -> ShadowFrameState? {
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

        // Floor 2: at coverage 1 the fade band [0.75R, R] would end exactly at
        // the camera distance, and no visible ground is ever closer than that,
        // every shadow would fade to nothing while the pass still runs.
        let farRadius = max(scene.shadows.coverageCameraDistances, 2.0) * cameraDistance
        let nearRadius = min(nearCascadeRadiusCameraDistances * cameraDistance, farRadius)
        let middleRadius = min(middleCascadeRadiusCameraDistances * cameraDistance, farRadius)
        let specs = [
            CascadeSpec(radius: nearRadius,
                        maxCasterHeight: Float(nearCascadeMaxCasterHeightMeters * unitsPerMeter),
                        atlasIndex: 0),
            CascadeSpec(radius: middleRadius,
                        maxCasterHeight: Float(middleCascadeMaxCasterHeightMeters * unitsPerMeter),
                        atlasIndex: 1),
            CascadeSpec(radius: farRadius,
                        maxCasterHeight: Float(farCascadeMaxCasterHeightMeters * unitsPerMeter),
                        atlasIndex: 2)
        ]

        var lightProjectionViews: [matrix_float4x4] = []
        var cascadeUniforms: [ShadowCascadeUniform] = []
        for spec in specs {
            guard let cascade = fitCascade(spec: spec,
                                           lightView: lightView,
                                           lightDirection: lightDirection,
                                           flatRenderPan: flatRenderPan,
                                           renderMapSize: renderMapSize,
                                           unitsPerMeter: unitsPerMeter,
                                           mapResolution: mapResolution) else {
                return nil
            }
            lightProjectionViews.append(cascade.lightProjectionView)
            cascadeUniforms.append(cascade.uniform)
        }

        let strength = min(max(scene.shadows.strength, 0), 1)
        let uniform = ShadowUniform(cascadeNear: cascadeUniforms[0],
                                    cascadeMiddle: cascadeUniforms[1],
                                    cascadeFar: cascadeUniforms[2],
                                    eye: cameraEye,
                                    strength: strength,
                                    fadeStartDistance: farRadius * 0.75,
                                    fadeEndDistance: farRadius,
                                    lightDirection: lightDirection)
        return ShadowFrameState(lightProjectionViews: lightProjectionViews,
                                shadowUniform: uniform,
                                mapResolution: mapResolution)
    }

    private static func fitCascade(spec: CascadeSpec,
                                   lightView: matrix_float4x4,
                                   lightDirection: SIMD3<Float>,
                                   flatRenderPan: SIMD2<Double>,
                                   renderMapSize: Double,
                                   unitsPerMeter: Double,
                                   mapResolution: Int) -> (lightProjectionView: matrix_float4x4,
                                                           uniform: ShadowCascadeUniform)? {
        guard spec.radius > 0, spec.radius.isFinite,
              spec.maxCasterHeight > 0, spec.maxCasterHeight.isFinite else {
            return nil
        }

        // Receiver volume samples: the disc boundary (8 fixed directions PLUS
        // the two exact depth-extreme azimuths ±L.xy: the fixed grid can miss
        // the true disc depth extremum by up to (1-cos 22.5°)·|L.xy|·R, which
        // would cut long shadows with a hard line inside the fade zone) and
        // the center, at the ground and lifted to the caster-height cap. The
        // lifted copies matter for the light-space Y extent, which grows with
        // the horizontal light tilt.
        var boundaryDirections: [SIMD2<Float>] = (0..<8).map { pointIndex in
            let angle = Float(pointIndex) * (.pi / 4)
            return SIMD2<Float>(cos(angle), sin(angle))
        }
        let horizontalLight = SIMD2<Float>(lightDirection.x, lightDirection.y)
        if simd_length(horizontalLight) > 1e-5 {
            let sunAzimuth = simd_normalize(horizontalLight)
            boundaryDirections.append(sunAzimuth)
            boundaryDirections.append(-sunAzimuth)
        }

        var minX = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        var minDepth = Float.greatestFiniteMagnitude
        var maxDepth = -Float.greatestFiniteMagnitude
        for point in boundaryDirections.map({ $0 * spec.radius }) + [SIMD2<Float>.zero] {
            for z in [Float(0), spec.maxCasterHeight] {
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
        let neededExtent = max(maxX - minX, maxY - minY) * (1.0 + 10.0 / Float(mapResolution))
        guard neededExtent > 0, neededExtent.isFinite else { return nil }
        let extent = pow(2.0, ceil(log2(neededExtent) * 2.0) / 2.0)
        let texelWorldSize = extent / Float(mapResolution)

        // Snap the window center to whole texels in pan-anchored space (see
        // the type comment): content world positions are `anchored + panShift`,
        // so the snapped quantity is `center - R·panShift`, evaluated in Double.
        let halfMapSize = renderMapSize * 0.5
        let panShift = SIMD3<Double>(flatRenderPan.x * halfMapSize,
                                     -flatRenderPan.y * halfMapSize,
                                     0)
        let lightRowX = SIMD3<Double>(Double(lightView[0][0]), Double(lightView[1][0]), Double(lightView[2][0]))
        let lightRowY = SIMD3<Double>(Double(lightView[0][1]), Double(lightView[1][1]), Double(lightView[2][1]))
        let texelWorldDouble = Double(texelWorldSize)
        func snapToTexelGrid(center: Float, panShiftLight: Double) -> Float {
            let anchored = Double(center) - panShiftLight
            let snapped = (anchored / texelWorldDouble).rounded() * texelWorldDouble
            return Float(snapped + panShiftLight)
        }
        let centerX = snapToTexelGrid(center: (minX + maxX) * 0.5,
                                      panShiftLight: simd_dot(lightRowX, panShift))
        let centerY = snapToTexelGrid(center: (minY + maxY) * 0.5,
                                      panShiftLight: simd_dot(lightRowY, panShift))
        let halfExtent = extent * 0.5

        let near = minDepth - spec.maxCasterHeight / lightDirection.z
        // Scale-proportional slack (the old absolute 0.01 vanished next to
        // world sizes that grow 2^zoom).
        let far = maxDepth + max(0.01, 2.0 * texelWorldSize)
        let lightProjection = Matrix.metalOrthographicMatrix(left: centerX - halfExtent,
                                                             right: centerX + halfExtent,
                                                             bottom: centerY - halfExtent,
                                                             top: centerY + halfExtent,
                                                             near: near,
                                                             far: far)
        let lightProjectionView = lightProjection * lightView

        // NDC → atlas slot `atlasIndex` of `cascadeCount`: the slot spans
        // 1/count of the atlas U, so u = x·(0.5/count) + (index + 0.5)/count;
        // v = -0.5y + 0.5 (Metal texture origin is top-left); z passes
        // through as the comparison depth.
        let slotWidth = 1.0 / Float(ShadowCascadeAtlas.cascadeCount)
        let uOffset = (Float(spec.atlasIndex) + 0.5) * slotWidth
        let uvBias = matrix_float4x4(
            SIMD4<Float>(0.5 * slotWidth, 0.0, 0.0, 0.0),
            SIMD4<Float>(0.0, -0.5, 0.0, 0.0),
            SIMD4<Float>(0.0, 0.0, 1.0, 0.0),
            SIMD4<Float>(uOffset, 0.5, 0.0, 1.0)
        )

        // Receiver bias, normalized by the depth window. Scaled by the wall
        // slope at head-on light (1/horizontalSlope): oblique walls are
        // covered by the receiver-plane gradient and the normal offset, so the
        // constant part stays small enough not to detach ground contact.
        let depthWindow = max(far - near, 1e-6)
        let horizontalSlope = simd_length(SIMD2<Float>(lightDirection.x, lightDirection.y)) / lightDirection.z
        let steepestSlope = max(horizontalSlope, 1.0 / max(horizontalSlope, 1e-3))
        let depthBias = (receiverBiasTexels * min(steepestSlope, 2.0) + receiverBiasFloorTexels)
            * texelWorldSize / depthWindow
        // Anything above the cap is a derivative artifact. Units: normalized
        // depth per atlas U: the window extent maps to `0.5 · slotWidth` of
        // the atlas U axis, so one full U spans extent / (0.5 · slotWidth)
        // world units.
        let worldPerAtlasU = extent / (0.5 * slotWidth)
        let gradientClamp = gradientClampMaxSlope * worldPerAtlasU / depthWindow

        let texelUV = SIMD2<Float>(slotWidth / Float(mapResolution), 1.0 / Float(mapResolution))
        let inset = uvInsetTexels * texelUV
        let uvMinimum = SIMD2<Float>(slotWidth * Float(spec.atlasIndex), 0) + inset
        let uvMaximum = SIMD2<Float>(slotWidth * Float(spec.atlasIndex + 1), 1) - inset
        let normalOffsetWorld = min(normalOffsetTexels * texelWorldSize,
                                    Float(normalOffsetMetersCap * unitsPerMeter))
        let uniform = ShadowCascadeUniform(worldToShadowTexture: uvBias * lightProjectionView,
                                           kernelRadiusUV: .zero,
                                           depthBias: depthBias,
                                           gradientClamp: gradientClamp,
                                           uvMinimum: uvMinimum,
                                           uvMaximum: uvMaximum,
                                           normalOffsetWorld: normalOffsetWorld,
                                           texelSizeUV: texelUV)
        return (lightProjectionView, uniform)
    }
}
