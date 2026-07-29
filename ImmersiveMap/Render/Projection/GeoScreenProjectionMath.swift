// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import simd

/// Единый CPU-проектор геокоординаты в экранную точку drawable (пиксели,
/// origin снизу слева, y вверх), согласованный с вершинным путём рендера:
/// GlobeVisibility.h::globeProjectLatLon и
/// GlobeTransitionProjection.h::globeTransitionLocalPhase.
/// Менять только синхронно с шейдерами.
enum GeoScreenProjectionMath {

    /// Полуширина полосы сглаживания горизонта в нормированном dot-пространстве.
    static let horizonFadeBandWidth: Float = 0.03

    /// Пер-кадровые константы: считаются один раз на кадр,
    /// `project(basis:constants:)` остаётся линейной алгеброй на точку.
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
        /// Зеркало globeVisibilityHorizonThreshold из GlobeVisibility.h:
        /// непрерывное ослабление порога в масштабе геометрии по мере морфа.
        let horizonThreshold: Float

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
            // Зеркало globeTransitionMapSize: плоская цель морфа растёт от
            // cos(широты центра) до полного меркаторного размера.
            let distortion = cos(panLatitude)
            let mapSizeScale = (1.0 - globe.transition) * distortion + globe.transition
            globeMapSize = 2.0 * .pi * globe.radius * mapSizeScale
            globePanMercatorY = Float(ImmersiveMapProjection.yMercatorNormalized(latitude: Double(panLatitude)))
            globeTransposedRotationMatrix = simd_transpose(
                Self.makeRotationMatrix(panLatitude: panLatitude,
                                        panLongitude: panLongitude))
            let horizonFade = GeoScreenProjectionMath.smoothstep(edge0: 0.0,
                                                                 edge1: 0.95,
                                                                 x: globe.transition)
            let radiusSquared = globe.radius * globe.radius
            horizonThreshold = (1.0 - horizonFade) * radiusSquared + horizonFade * (-4.0 * radiusSquared)
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

    /// Зеркало globeTransitionLocalPhase из GlobeTransitionProjection.h:
    /// волна разворота сферы, ближняя к центру взгляда область встаёт в
    /// плоскость первой, дальние углы последними.
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

    /// Мягкий горизонт: точка за краем шара гаснет в полосе
    /// ±`horizonFadeBandWidth` вместо ступеньки, alpha годится как
    /// коэффициент прозрачности.
    static func globeVisibility(worldPosition: SIMD3<Float>,
                                constants: FrameConstants) -> (visible: Bool, alpha: Float) {
        let globeCenter = SIMD3<Float>(0.0, 0.0, -constants.globe.radius)
        let toCamera = constants.cameraUniform.eye - globeCenter
        let toCameraLength = simd_length(toCamera)
        if toCameraLength <= 0.0 || constants.globe.transition >= 0.95 {
            return (true, 1.0)
        }

        let radius = max(constants.globe.radius, 1e-6)
        let dotToCamera = simd_dot(worldPosition - globeCenter, toCamera)
        let normalization = max(toCameraLength * radius, 1e-6)
        let normalizedDot = dotToCamera / normalization
        let normalizedThreshold = constants.horizonThreshold / normalization
        let visibilityDelta = normalizedDot - normalizedThreshold

        if visibilityDelta <= -horizonFadeBandWidth {
            return (false, 0.0)
        }

        let alpha = smoothstep(edge0: -horizonFadeBandWidth,
                               edge1: horizonFadeBandWidth,
                               x: visibilityDelta)
        return (true, alpha)
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

        let visibility = globeVisibility(worldPosition: worldPosition, constants: constants)
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
