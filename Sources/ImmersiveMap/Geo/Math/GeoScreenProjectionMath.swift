// Copyright (c) 2025-2026 Artem Bobkin.
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
            globeFlatWorldPosition(normalizedWorldX: Float(basis.normalizedWorldX),
                                   mercatorYNormalized: Float(basis.mercatorYNormalized))
        }

        /// The point's place on the plane the globe unrolls into, by its
        /// normalized world X ((lon + pi) / 2pi) and Mercator Y.
        func globeFlatWorldPosition(normalizedWorldX: Float,
                                    mercatorYNormalized: Float) -> SIMD3<Float> {
            let halfMapSize = globeMapSize * 0.5
            let worldX = normalizedWorldX * globeMapSize
            let x = Float(ImmersiveMapProjection.wrap(value: Double(worldX - halfMapSize + globe.panX * halfMapSize),
                                                      size: Double(globeMapSize)))
            let y = (mercatorYNormalized - globePanMercatorY) * halfMapSize
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

    /// A point of the globe's surface as the frame draws it: on the sphere,
    /// on the plane, and where the unroll has it between the two.
    struct GlobeSurfacePoint {
        /// Where the point is drawn this frame.
        let worldPosition: SIMD3<Float>
        let sphereWorldPosition: SIMD3<Float>
        /// The point's place on the plane, zero on the resting sphere,
        /// where nothing reads it.
        let flatWorldPosition: SIMD2<Float>
    }

    /// Where a point of the globe is this frame: on the resting sphere its
    /// place on the sphere, and through the morph where the unroll carries
    /// it (`GlobeUnrollMath.worldPosition`), as the ground's vertex stage
    /// does. The one place a CPU projection gets a globe point from, so a
    /// name, a pin and a marker stand where the ground under them is drawn.
    static func globeSurfacePoint(sphereUnit: SIMD3<Float>,
                                  normalizedWorldX: Float,
                                  mercatorYNormalized: Float,
                                  constants: FrameConstants) -> GlobeSurfacePoint {
        let sphereWorldPosition = constants.rotatedSphereWorldPosition(sphereUnit: sphereUnit)
        guard constants.globe.transition > 0.0 else {
            return GlobeSurfacePoint(worldPosition: sphereWorldPosition,
                                     sphereWorldPosition: sphereWorldPosition,
                                     flatWorldPosition: .zero)
        }
        let flat = constants.globeFlatWorldPosition(normalizedWorldX: normalizedWorldX,
                                                    mercatorYNormalized: mercatorYNormalized)
        let flatWorldPosition = SIMD2<Float>(flat.x, flat.y)
        let worldPosition = GlobeUnrollMath.worldPosition(sphereWorldPosition: sphereWorldPosition,
                                                          flatWorldPosition: flatWorldPosition,
                                                          transition: constants.globe.transition,
                                                          radius: constants.globe.radius)
        return GlobeSurfacePoint(worldPosition: worldPosition,
                                 sphereWorldPosition: sphereWorldPosition,
                                 flatWorldPosition: flatWorldPosition)
    }

    private static func projectGlobe(basis: GeoProjectionBasis,
                                     constants: FrameConstants) -> ScreenPointOutput {
        let surface = globeSurfacePoint(sphereUnit: basis.sphereUnit,
                                        normalizedWorldX: Float(basis.normalizedWorldX),
                                        mercatorYNormalized: Float(basis.mercatorYNormalized),
                                        constants: constants)
        let clip = constants.cameraUniform.matrix * SIMD4<Float>(surface.worldPosition, 1.0)
        var point = screenPointFromClip(clip: clip, viewportSize: constants.viewport)
        guard point.visible != 0 else {
            return point
        }

        let visibility = globeVisibility(worldPosition: surface.worldPosition,
                                         sphereWorldPosition: surface.sphereWorldPosition,
                                         flatWorldPosition: surface.flatWorldPosition,
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

    static func screenPointFromClip(clip: SIMD4<Float>,
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

}
