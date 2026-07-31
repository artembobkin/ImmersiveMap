// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import simd

/// Unified CPU projector of a geo coordinate into a drawable screen point
/// (pixels, origin bottom-left, y up), consistent with the render vertex path:
/// GlobeVisibility.h::globeProjectLatLon and
/// GlobeTransitionProjection.h::globeTransitionLocalPhase.
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

    /// Mirror of globeTransitionLocalPhase from GlobeTransitionProjection.h:
    /// the sphere unfurl wave, the area nearest the view center settles into
    /// the plane first, the far corners last.
    static func transitionLocalPhase(_ transition: Float, frontDot: Float) -> Float {
        let spread: Float = 0.6
        let lagWeight = acos(simd_clamp(frontDot, -1.0, 1.0)) / Float.pi
        return simd_clamp((transition - lagWeight * spread) / (1.0 - spread), 0.0, 1.0)
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

    /// Soft horizon: a point beyond the globe's edge fades out within a
    /// ±`horizonFadeBandWidth` band instead of a hard step; the alpha is
    /// usable as an opacity coefficient.
    ///
    /// The threshold for the morphed position is relaxed by this point's LOCAL
    /// unfurl-wave phase (`transitionLocalPhase`), not by the global transition
    /// as in GlobeVisibility.h: a point on the still-spherical part (local
    /// phase 0) must pass the strict spherical test, otherwise the back side
    /// of the globe leaks through mid-morph. For tiles this leak is hidden by
    /// the depth test; the overlay (SwiftUI markers, avatars) has no depth.
    ///
    /// An additional gate on the SPHERICAL position: while the morph is not
    /// finished, a point far past the sphere's horizon stays hidden even when
    /// its local phase has already unfurled the position toward the plane.
    /// Otherwise far markers "fly" through the viewport on the way to their
    /// flat spots: tiles do not show that transit (far coverage is not drawn),
    /// and the marker hangs over empty ocean for several frames. The
    /// `unfurlVisibilityMarginRadians` margin past the spherical horizon keeps
    /// visible the points that the unfurl legitimately brings into frame (at
    /// strong tilt the visible range of the plane exceeds the spherical one).
    static let unfurlVisibilityMarginRadians: Float = 0.5

    static func globeVisibility(worldPosition: SIMD3<Float>,
                                sphereWorldPosition: SIMD3<Float>,
                                localTransition: Float,
                                constants: FrameConstants) -> (visible: Bool, alpha: Float) {
        let globeCenter = SIMD3<Float>(0.0, 0.0, -constants.globe.radius)
        let toCamera = constants.cameraUniform.eye - globeCenter
        let toCameraLength = simd_length(toCamera)
        if toCameraLength <= 0.0 || constants.globe.transition >= 0.95 {
            return (true, 1.0)
        }

        let radius = max(constants.globe.radius, 1e-6)
        let radiusSquared = radius * radius
        let normalization = max(toCameraLength * radius, 1e-6)
        let horizonFade = smoothstep(edge0: 0.0, edge1: 0.95, x: localTransition)
        let morphedThreshold = (1.0 - horizonFade) * radiusSquared + horizonFade * (-4.0 * radiusSquared)

        let horizonAngle = acos(simd_clamp(radius / toCameraLength, -1.0, 1.0))
        let gateAngle = min(horizonAngle + Self.unfurlVisibilityMarginRadians, Float.pi)
        let gateThreshold = cos(gateAngle) * normalization

        guard let morphedAlpha = horizonAlpha(position: worldPosition,
                                              globeCenter: globeCenter,
                                              toCamera: toCamera,
                                              threshold: morphedThreshold,
                                              normalization: normalization),
              let gateAlpha = horizonAlpha(position: sphereWorldPosition,
                                           globeCenter: globeCenter,
                                           toCamera: toCamera,
                                           threshold: gateThreshold,
                                           normalization: normalization) else {
            return (false, 0.0)
        }

        return (true, min(morphedAlpha, gateAlpha))
    }

    private static func horizonAlpha(position: SIMD3<Float>,
                                     globeCenter: SIMD3<Float>,
                                     toCamera: SIMD3<Float>,
                                     threshold: Float,
                                     normalization: Float) -> Float? {
        let normalizedDot = simd_dot(position - globeCenter, toCamera) / normalization
        let visibilityDelta = normalizedDot - threshold / normalization
        guard visibilityDelta > -horizonFadeBandWidth else {
            return nil
        }

        return smoothstep(edge0: -horizonFadeBandWidth,
                          edge1: horizonFadeBandWidth,
                          x: visibilityDelta)
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
        let flatWorldPosition = constants.globeFlatWorldPosition(basis: basis)
        let frontDot = (sphereWorldPosition.z + constants.globe.radius) / max(constants.globe.radius, 1e-6)
        let localTransition = transitionLocalPhase(constants.globe.transition, frontDot: frontDot)
        let worldPosition = sphereWorldPosition + (flatWorldPosition - sphereWorldPosition) * localTransition
        let clip = constants.cameraUniform.matrix * SIMD4<Float>(worldPosition, 1.0)
        var point = screenPointFromClip(clip: clip, viewportSize: constants.viewport)
        guard point.visible != 0 else {
            return point
        }

        let visibility = globeVisibility(worldPosition: worldPosition,
                                         sphereWorldPosition: sphereWorldPosition,
                                         localTransition: localTransition,
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
