// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import simd

/// Unified CPU projector of a geo coordinate into a drawable screen point
/// (pixels, origin bottom-left, y up), consistent with the render vertex path:
/// GlobeVisibility.h::globeProjectLatLon and the sphere-to-plane unroll in
/// GlobeUnroll.h (mirrored by GlobeUnrollMath).
/// Change only in sync with the shaders.
enum GeoScreenProjectionMath {

    /// Half-width of the horizon smoothing band in normalized dot space.
    static let horizonFadeBandWidth: Float = 0.03

    /// Per-frame constants: computed once per frame, so
    /// `project(basis:constants:)` stays per-point linear algebra.
    struct FrameConstants {
        let mode: ScreenSpaceProjectionMode
        let viewport: SIMD2<Float>
        let cameraUniform: CameraUniform
        let flatRenderMapSize: Double
        let flatPan: SIMD2<Double>
        let globe: GlobeUniform
        let globeMapSize: Float
        let globePanMercatorY: Float
        let globeTransposedRotationMatrix: matrix_float4x4

        init(drawSize: CGSize,
             cameraUniform: CameraUniform,
             resolvedPresentation: ResolvedPresentationState) {
            mode = resolvedPresentation.screenSpaceProjectionMode
            viewport = SIMD2<Float>(Float(drawSize.width), Float(drawSize.height))
            self.cameraUniform = cameraUniform
            flatRenderMapSize = resolvedPresentation.flatRenderState.renderMapSize
            flatPan = resolvedPresentation.flatRenderState.pan

            let globe = resolvedPresentation.globeRenderUniform
            self.globe = globe
            let panLatitude = globe.panY * Float(ImmersiveMapProjection.maxMercatorLatitude)
            let panLongitude = globe.panX * Float.pi
            // Mirror of globeTransitionMapSize: the flat morph target grows from
            // cos(center latitude) up to the full Mercator size.
            let distortion = cos(panLatitude)
            let mapSizeScale = (1.0 - globe.transition) * distortion + globe.transition
            globeMapSize = 2.0 * .pi * globe.radius * mapSizeScale
            globePanMercatorY = Float(ImmersiveMapProjection.yMercatorNormalized(latitude: Double(panLatitude)))
            globeTransposedRotationMatrix = simd_transpose(
                Self.makeRotationMatrix(panLatitude: panLatitude,
                                        panLongitude: panLongitude))
        }

        func rotatedSphereWorldPosition(sphereUnit: SIMD3<Float>) -> SIMD3<Float> {
            let scaled = sphereUnit * globe.radius
            let rotated = globeTransposedRotationMatrix * SIMD4<Float>(scaled, 1.0)
            return SIMD3<Float>(rotated.x, rotated.y, rotated.z - globe.radius)
        }

        func globeFlatWorldPosition(basis: GeoProjectionBasis) -> SIMD3<Float> {
            let halfMapSize = globeMapSize * 0.5
            let worldX = Float(basis.normalizedWorldX) * globeMapSize
            let x = Float(ImmersiveMapProjection.wrap(value: Double(worldX - halfMapSize + globe.panX * halfMapSize),
                                                      size: Double(globeMapSize)))
            let y = (Float(basis.mercatorYNormalized) - globePanMercatorY) * halfMapSize
            return SIMD3<Float>(x, y, 0.0)
        }

        private static func makeRotationMatrix(panLatitude: Float,
                                               panLongitude: Float) -> matrix_float4x4 {
            let cx = cos(-panLatitude)
            let sx = sin(-panLatitude)
            let cy = cos(-panLongitude)
            let sy = sin(-panLongitude)

            return matrix_float4x4(columns: (
                SIMD4<Float>(cy, 0, -sy, 0),
                SIMD4<Float>(sy * sx, cx, cy * sx, 0),
                SIMD4<Float>(sy * cx, -sx, cy * cx, 0),
                SIMD4<Float>(0, 0, 0, 1)
            ))
        }
    }

    static func project(basis: GeoProjectionBasis,
                        constants: FrameConstants) -> ScreenPointOutput {
        switch constants.mode {
        case .flat:
            return projectFlat(basis: basis, constants: constants)
        case .globe:
            return projectGlobe(basis: basis, constants: constants)
        }
    }

    /// Soft horizon against the unrolling sphere the surface lives on
    /// (GlobeUnrollMath.horizonAlpha), times the unroll's cut: a point whose
    /// remaining chart travel is long is hidden exactly like the ground
    /// under it (GlobeUnrollMath.cutClearance), so a marker never flies
    /// across the view on its way to its Mercator home.
    static func globeVisibility(worldPosition: SIMD3<Float>,
                                sphereWorldPosition: SIMD3<Float>,
                                flatWorldPosition: SIMD2<Float>,
                                constants: FrameConstants) -> (visible: Bool, alpha: Float) {
        var alpha = GlobeUnrollMath.horizonAlpha(worldPosition: worldPosition,
                                                 cameraEye: constants.cameraUniform.eye,
                                                 transition: constants.globe.transition,
                                                 radius: constants.globe.radius)
        if constants.globe.transition > 0 {
            let clearance = GlobeUnrollMath.cutClearance(sphereWorldPosition: sphereWorldPosition,
                                                         flatWorldPosition: flatWorldPosition,
                                                         transition: constants.globe.transition,
                                                         radius: constants.globe.radius)
            let t = simd_clamp(clearance / 0.05, 0.0, 1.0)
            alpha *= t * t * (3.0 - 2.0 * t)
        }
        return (alpha > 0.0, alpha)
    }

    private static func projectFlat(basis: GeoProjectionBasis,
                                    constants: FrameConstants) -> ScreenPointOutput {
        let halfMapSize = constants.flatRenderMapSize * 0.5
        let xWorld = ImmersiveMapProjection.wrap(
            value: basis.normalizedWorldX * constants.flatRenderMapSize - halfMapSize + constants.flatPan.x * halfMapSize,
            size: constants.flatRenderMapSize)
        let yWorld = (basis.mercatorYNormalized - constants.flatPan.y) * halfMapSize
        let clip = constants.cameraUniform.matrix * SIMD4<Float>(Float(xWorld), Float(yWorld), 0.0, 1.0)
        return screenPointFromClip(clip: clip, viewportSize: constants.viewport)
    }

    private static func projectGlobe(basis: GeoProjectionBasis,
                                     constants: FrameConstants) -> ScreenPointOutput {
        let sphereWorldPosition = constants.rotatedSphereWorldPosition(sphereUnit: basis.sphereUnit)
        let worldPosition: SIMD3<Float>
        if constants.globe.transition <= 0.0 {
            worldPosition = sphereWorldPosition
        } else {
            let flatWorldPosition = constants.globeFlatWorldPosition(basis: basis)
            worldPosition = GlobeUnrollMath.worldPosition(sphereWorldPosition: sphereWorldPosition,
                                                          flatWorldPosition: SIMD2<Float>(flatWorldPosition.x,
                                                                                          flatWorldPosition.y),
                                                          transition: constants.globe.transition,
                                                          radius: constants.globe.radius)
        }
        let clip = constants.cameraUniform.matrix * SIMD4<Float>(worldPosition, 1.0)
        var point = screenPointFromClip(clip: clip, viewportSize: constants.viewport)
        guard point.visible != 0 else {
            return point
        }

        let flatForCut = constants.globe.transition > 0
            ? constants.globeFlatWorldPosition(basis: basis) : SIMD3<Float>(0, 0, 0)
        let visibility = globeVisibility(worldPosition: worldPosition,
                                         sphereWorldPosition: sphereWorldPosition,
                                         flatWorldPosition: SIMD2<Float>(flatForCut.x, flatForCut.y),
                                         constants: constants)
        guard visibility.alpha > 0.0 else {
            return ScreenPointOutput(position: point.position,
                                     depth: point.depth,
                                     visible: 0,
                                     visibilityAlpha: 0.0)
        }
        point.visibilityAlpha = visibility.alpha
        return point
    }

    private static func screenPointFromClip(clip: SIMD4<Float>,
                                            viewportSize: SIMD2<Float>) -> ScreenPointOutput {
        guard clip.w > 0.0 else {
            return ScreenPointOutput(position: .zero,
                                     depth: 0.0,
                                     visible: 0,
                                     visibilityAlpha: 0.0)
        }

        let ndc = SIMD2<Float>(clip.x, clip.y) / clip.w
        let depth = clip.z / clip.w
        let position = (ndc * 0.5 + 0.5) * viewportSize
        return ScreenPointOutput(position: position,
                                 depth: depth,
                                 visible: 1,
                                 visibilityAlpha: 1.0)
    }

    private static func smoothstep(edge0: Float, edge1: Float, x: Float) -> Float {
        let t = simd_clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
        return t * t * (3.0 - 2.0 * t)
    }
}
