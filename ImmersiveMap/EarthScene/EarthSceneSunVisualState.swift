// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

struct EarthSceneSunVisualState {
    var screenCenter: SIMD2<Float>
    var clampedScreenCenter: SIMD2<Float>
    var globeScreenCenter: SIMD2<Float>
    var globeScreenRadius: Float
    var diskAlpha: Float
    var edgeGlareAlpha: Float
    var limbHaloAlpha: Float
    var isEnabled: UInt32
    var padding: UInt32 = 0

    var hasVisibleContribution: Bool {
        isEnabled != 0 && (diskAlpha > 0 || edgeGlareAlpha > 0 || limbHaloAlpha > 0)
    }

    func hasVisibleContribution(earthScene: EarthSceneUniform) -> Bool {
        guard isEnabled != 0 else {
            return false
        }

        let diskOrGlow = diskAlpha > 0 && (earthScene.sunDiskIntensity > 0 || earthScene.sunGlowIntensity > 0)
        let edgeGlare = edgeGlareAlpha > 0 && earthScene.sunEdgeGlareIntensity > 0
        let limbHalo = limbHaloAlpha > 0 && earthScene.sunLimbHaloIntensity > 0
        return diskOrGlow || edgeGlare || limbHalo
    }

    static let disabled = EarthSceneSunVisualState(
        screenCenter: SIMD2<Float>(repeating: 0.5),
        clampedScreenCenter: SIMD2<Float>(repeating: 0.5),
        globeScreenCenter: SIMD2<Float>(repeating: 0.5),
        globeScreenRadius: 0,
        diskAlpha: 0,
        edgeGlareAlpha: 0,
        limbHaloAlpha: 0,
        isEnabled: 0
    )

    static func make(earthScene: EarthSceneUniform,
                     globe: GlobeUniform,
                     cameraMatrix: matrix_float4x4,
                     cameraEye: SIMD3<Float>,
                     drawSize: CGSize,
                     starfieldRadiusScale: Float = 10.5) -> EarthSceneSunVisualState {
        guard earthScene.isEnabled != 0,
              earthScene.sunVisualEnabled != 0 else {
            return .disabled
        }

        let width = Float(drawSize.width)
        let height = Float(drawSize.height)
        guard width.isFinite,
              height.isFinite,
              width > 0,
              height > 0 else {
            return .disabled
        }
        let aspectScale = SIMD2<Float>(width / height, 1)

        let rawDirection = earthScene.sunDirection
        let directionLength = simd_length(rawDirection)
        guard directionLength.isFinite,
              directionLength > 0,
              globe.radius.isFinite,
              globe.radius > 0,
              starfieldRadiusScale.isFinite else {
            return .disabled
        }

        let direction = rawDirection / directionLength
        let rotation = Self.globeRotationMatrix(globe: globe)
        let rotatedDirection4 = simd_transpose(rotation) * SIMD4<Float>(direction, 0)
        let rotatedDirection = normalize(SIMD3<Float>(rotatedDirection4.x,
                                                      rotatedDirection4.y,
                                                      rotatedDirection4.z))
        let globeCenterWorld = SIMD3<Float>(0, 0, -globe.radius)
        let sunDistance = globe.radius * max(starfieldRadiusScale, 1.01)
        let sunWorld = globeCenterWorld + rotatedDirection * sunDistance
        guard let screenCenter = Self.projectNormalized(worldPosition: sunWorld,
                                                        cameraMatrix: cameraMatrix) else {
            return .disabled
        }

        guard let globeProjection = Self.projectGlobeSilhouette(globe: globe,
                                                                cameraMatrix: cameraMatrix,
                                                                cameraEye: cameraEye,
                                                                sunScreenCenter: screenCenter,
                                                                aspectScale: aspectScale) else {
            return .disabled
        }
        let clampedScreenCenter = SIMD2<Float>(
            Self.clampedUnit(screenCenter.x),
            Self.clampedUnit(screenCenter.y)
        )
        let distanceToGlobeCenter = simd_length((screenCenter - globeProjection.center) * aspectScale)
        let viewportDistance = simd_length((screenCenter - clampedScreenCenter) * aspectScale)

        let signedLimbDistance = distanceToGlobeCenter - globeProjection.radius
        let diskFadeWidth = max(earthScene.sunDiskAngularSize, EarthSceneUniform.minimumFadeWidth)
        let viewportFadeWidth = max(earthScene.sunDiskAngularSize * 3.5, EarthSceneUniform.minimumFadeWidth)
        let viewportAlpha = 1 - Self.smoothstep(edge0: 0,
                                                edge1: viewportFadeWidth,
                                                x: viewportDistance)
        let diskAlpha = viewportAlpha * Self.smoothstep(edge0: -diskFadeWidth,
                                                        edge1: 0,
                                                        x: signedLimbDistance)
        let edgeGlareAlpha: Float
        let limbDistance = abs(signedLimbDistance)
        let haloWidth = max(earthScene.sunLimbHaloWidth, EarthSceneUniform.minimumFadeWidth)
        let limbHaloAlpha = viewportAlpha * Self.clampedUnit(1 - limbDistance / haloWidth)
        if signedLimbDistance <= 0 {
            edgeGlareAlpha = 0
        } else {
            edgeGlareAlpha = Self.edgeGlareFade(screenCenter: screenCenter)
        }

        return EarthSceneSunVisualState(
            screenCenter: screenCenter,
            clampedScreenCenter: clampedScreenCenter,
            globeScreenCenter: globeProjection.center,
            globeScreenRadius: globeProjection.radius,
            diskAlpha: diskAlpha,
            edgeGlareAlpha: edgeGlareAlpha,
            limbHaloAlpha: limbHaloAlpha,
            isEnabled: 1
        )
    }

    private static func globeRotationMatrix(globe: GlobeUniform) -> matrix_float4x4 {
        let maxLatitude = Float(ImmersiveMapProjection.maxMercatorLatitude)
        let latitude = globe.panY * maxLatitude
        let longitude = globe.panX * .pi
        let cx = cos(-latitude)
        let sx = sin(-latitude)
        let cy = cos(-longitude)
        let sy = sin(-longitude)

        return matrix_float4x4(columns: (
            SIMD4<Float>(cy, 0, -sy, 0),
            SIMD4<Float>(sy * sx, cx, cy * sx, 0),
            SIMD4<Float>(sy * cx, -sx, cy * cx, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    private static func projectGlobeSilhouette(globe: GlobeUniform,
                                               cameraMatrix: matrix_float4x4,
                                               cameraEye: SIMD3<Float>,
                                               sunScreenCenter: SIMD2<Float>,
                                               aspectScale: SIMD2<Float>) -> (center: SIMD2<Float>, radius: Float)? {
        let centerWorld = SIMD3<Float>(0, 0, -globe.radius)
        guard let center = projectNormalized(worldPosition: centerWorld,
                                             cameraMatrix: cameraMatrix) else {
            return nil
        }

        let samples = Self.projectedLimbSamples(centerWorld: centerWorld,
                                                radius: globe.radius,
                                                cameraEye: cameraEye,
                                                cameraMatrix: cameraMatrix)
        let projectedSamples = samples.isEmpty
            ? Self.projectedSphereSamples(centerWorld: centerWorld,
                                          radius: globe.radius,
                                          cameraMatrix: cameraMatrix)
            : samples
        guard projectedSamples.isEmpty == false else {
            return nil
        }

        let sunVector = (sunScreenCenter - center) * aspectScale
        let sunDistance = simd_length(sunVector)
        let radius: Float
        if sunDistance > Float.ulpOfOne {
            let sunDirection = sunVector / sunDistance
            radius = projectedSamples.reduce(-Float.greatestFiniteMagnitude) { partial, sample in
                let sampleVector = (sample - center) * aspectScale
                let support = simd_dot(sampleVector, sunDirection)
                return support.isFinite ? max(partial, support) : partial
            }
        } else {
            radius = projectedSamples.reduce(Float(0)) { partial, sample in
                let distance = simd_length((sample - center) * aspectScale)
                return distance.isFinite ? max(partial, distance) : partial
            }
        }

        guard radius.isFinite,
              radius > 0 else {
            return nil
        }
        return (center, radius)
    }

    private static func projectedLimbSamples(centerWorld: SIMD3<Float>,
                                             radius: Float,
                                             cameraEye: SIMD3<Float>,
                                             cameraMatrix: matrix_float4x4) -> [SIMD2<Float>] {
        let centerToCamera = cameraEye - centerWorld
        let cameraDistance = simd_length(centerToCamera)
        guard cameraDistance.isFinite,
              cameraDistance > radius,
              radius > 0 else {
            return []
        }

        let cameraAxis = centerToCamera / cameraDistance
        let cosine = radius / cameraDistance
        let sine = sqrt(max(0, 1 - cosine * cosine))
        let basis = makeOrthonormalBasis(axis: cameraAxis)

        return limbSampleAngles.compactMap { angle in
            let radial = cameraAxis * cosine
                + (basis.u * cos(angle) + basis.v * sin(angle)) * sine
            return projectNormalized(worldPosition: centerWorld + radial * radius,
                                     cameraMatrix: cameraMatrix)
        }
    }

    private static func projectedSphereSamples(centerWorld: SIMD3<Float>,
                                               radius: Float,
                                               cameraMatrix: matrix_float4x4) -> [SIMD2<Float>] {
        sphereSampleDirections.compactMap { direction in
            projectNormalized(worldPosition: centerWorld + direction * radius,
                              cameraMatrix: cameraMatrix)
        }
    }

    private static func makeOrthonormalBasis(axis: SIMD3<Float>) -> (u: SIMD3<Float>, v: SIMD3<Float>) {
        let helper = abs(axis.y) < 0.95
            ? SIMD3<Float>(0, 1, 0)
            : SIMD3<Float>(1, 0, 0)
        let u = normalize(cross(axis, helper))
        let v = normalize(cross(axis, u))
        return (u, v)
    }

    private static func projectNormalized(worldPosition: SIMD3<Float>,
                                          cameraMatrix: matrix_float4x4) -> SIMD2<Float>? {
        let clip = cameraMatrix * SIMD4<Float>(worldPosition, 1)
        guard clip.w.isFinite,
              clip.w > 0 else {
            return nil
        }
        let ndc = SIMD2<Float>(clip.x, clip.y) / clip.w
        guard ndc.x.isFinite,
              ndc.y.isFinite else {
            return nil
        }
        return ndc * 0.5 + SIMD2<Float>(repeating: 0.5)
    }

    private static func edgeGlareFade(screenCenter: SIMD2<Float>) -> Float {
        guard screenCenter.x >= 0,
              screenCenter.x <= 1,
              screenCenter.y >= 0,
              screenCenter.y <= 1 else {
            return 1
        }

        let edgeDistance = min(screenCenter.x, 1 - screenCenter.x, screenCenter.y, 1 - screenCenter.y)
        return 1 - smoothstep(edge0: 0, edge1: 0.18, x: edgeDistance)
    }

    private static func smoothstep(edge0: Float, edge1: Float, x: Float) -> Float {
        let t = clampedUnit((x - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    private static func clampedUnit(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    private static let sphereSampleDirections: [SIMD3<Float>] = {
        let cardinal = [
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(-1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, -1, 0),
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(0, 0, -1)
        ]
        let sampleCount = 96
        let goldenAngle = Float.pi * (3 - sqrt(Float(5)))
        let fibonacci = (0..<sampleCount).map { index -> SIMD3<Float> in
            let t = Float(index) + 0.5
            let z = 1 - 2 * t / Float(sampleCount)
            let radius = sqrt(max(0, 1 - z * z))
            let theta = goldenAngle * t
            return SIMD3<Float>(cos(theta) * radius, sin(theta) * radius, z)
        }
        return cardinal + fibonacci
    }()

    private static let limbSampleAngles: [Float] = {
        let count = 192
        return (0..<count).map { index in
            2 * Float.pi * Float(index) / Float(count)
        }
    }()
}
