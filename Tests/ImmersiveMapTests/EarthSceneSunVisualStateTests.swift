// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class EarthSceneSunVisualStateTests: XCTestCase {
    func testDisabledStateHasNoVisibleContribution() {
        XCTAssertFalse(EarthSceneSunVisualState.disabled.hasVisibleContribution)
    }

    func testOutsideGlobeStateHasVisibleContribution() {
        var earthScene = Self.earthScene()
        earthScene.sunDirection = normalize(SIMD3<Float>(0.9, 0, 0.44))

        let state = Self.makeState(
            earthScene: earthScene,
            globe: Self.globe,
            cameraMatrix: matrix_identity_float4x4,
            drawSize: CGSize(width: 1024, height: 768)
        )

        XCTAssertTrue(state.hasVisibleContribution)
    }

    func testInsideGlobeAwayFromLimbHasNoVisibleContribution() {
        var earthScene = Self.earthScene(limbHaloIntensity: 1)
        earthScene.sunDirection = SIMD3<Float>(0, 0, 1)

        let state = Self.makeState(
            earthScene: earthScene,
            globe: Self.globe,
            cameraMatrix: matrix_identity_float4x4,
            drawSize: CGSize(width: 1000, height: 1000)
        )

        XCTAssertEqual(state.isEnabled, 1)
        XCTAssertEqual(state.diskAlpha, 0.0, accuracy: 0.0001)
        XCTAssertEqual(state.edgeGlareAlpha, 0.0, accuracy: 0.0001)
        XCTAssertEqual(state.limbHaloAlpha, 0.0, accuracy: 0.0001)
        XCTAssertFalse(state.hasVisibleContribution)
    }

    func testDisabledEarthSceneReturnsDisabledState() {
        let state = Self.makeState(
            earthScene: .disabled,
            globe: Self.globe,
            cameraMatrix: matrix_identity_float4x4,
            drawSize: CGSize(width: 1024, height: 768)
        )

        XCTAssertEqual(state.screenCenter.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(state.screenCenter.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(state.clampedScreenCenter.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(state.clampedScreenCenter.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(state.globeScreenCenter.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(state.globeScreenCenter.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(state.globeScreenRadius, 0.0, accuracy: 0.0001)
        XCTAssertEqual(state.diskAlpha, 0.0, accuracy: 0.0001)
        XCTAssertEqual(state.edgeGlareAlpha, 0.0, accuracy: 0.0001)
        XCTAssertEqual(state.limbHaloAlpha, 0.0, accuracy: 0.0001)
        XCTAssertEqual(state.isEnabled, 0)
        XCTAssertEqual(state.padding, 0)
    }

    func testVisibleSunOutsideGlobeSilhouetteDrawsDiskWithoutEdgeGlareAwayFromViewportEdge() {
        var earthScene = Self.earthScene()
        earthScene.sunDirection = normalize(SIMD3<Float>(0.9, 0, 0.44))
        var cameraMatrix = matrix_identity_float4x4
        cameraMatrix[0][0] = 0.05
        cameraMatrix[1][1] = 0.05
        let expectedScreenCenter = SIMD2<Float>(
            0.5 + earthScene.sunDirection.x * 10.5 * 0.05 * 0.5,
            0.5 + earthScene.sunDirection.y * 10.5 * 0.05 * 0.5
        )

        let state = Self.makeState(
            earthScene: earthScene,
            globe: Self.globe,
            cameraMatrix: cameraMatrix,
            drawSize: CGSize(width: 1024, height: 768)
        )

        XCTAssertEqual(state.isEnabled, 1)
        XCTAssertEqual(state.screenCenter.x, expectedScreenCenter.x, accuracy: 0.0001)
        XCTAssertEqual(state.screenCenter.y, expectedScreenCenter.y, accuracy: 0.0001)
        XCTAssertEqual(state.clampedScreenCenter.x, expectedScreenCenter.x, accuracy: 0.0001)
        XCTAssertEqual(state.clampedScreenCenter.y, expectedScreenCenter.y, accuracy: 0.0001)
        XCTAssertEqual(state.globeScreenRadius, 0.0333333, accuracy: 0.0001)
        XCTAssertEqual(state.diskAlpha, 1.0, accuracy: 0.0001)
        XCTAssertEqual(state.edgeGlareAlpha, 0.0, accuracy: 0.0001)
        XCTAssertEqual(state.limbHaloAlpha, 0.0, accuracy: 0.0001)
    }

    func testVisibleSunGlowContributesWhenDiskIntensityIsZero() {
        var earthScene = EarthSceneUniform(
            settings: ImmersiveMapSettings.EarthSceneSettings(
                sun: .init(
                    diskIntensity: 0,
                    glowIntensity: 1,
                    edgeGlareIntensity: 0,
                    limbHaloIntensity: 0
                )
            ),
            now: .distantPast
        )
        earthScene.sunDirection = normalize(SIMD3<Float>(0.9, 0, 0.44))
        var cameraMatrix = matrix_identity_float4x4
        cameraMatrix[0][0] = 0.05
        cameraMatrix[1][1] = 0.05

        let state = Self.makeState(
            earthScene: earthScene,
            globe: Self.globe,
            cameraMatrix: cameraMatrix,
            drawSize: CGSize(width: 1024, height: 768)
        )

        XCTAssertEqual(state.diskAlpha, 1.0, accuracy: 0.0001)
        XCTAssertTrue(state.hasVisibleContribution)
        XCTAssertTrue(state.hasVisibleContribution(earthScene: earthScene))
    }

    func testVisibleSunHasNoRenderableContributionWhenAllIntensitiesAreZero() {
        var earthScene = EarthSceneUniform(
            settings: ImmersiveMapSettings.EarthSceneSettings(
                sun: .init(
                    diskIntensity: 0,
                    glowIntensity: 0,
                    edgeGlareIntensity: 0,
                    limbHaloIntensity: 0
                )
            ),
            now: .distantPast
        )
        earthScene.sunDirection = normalize(SIMD3<Float>(0.9, 0, 0.44))
        var cameraMatrix = matrix_identity_float4x4
        cameraMatrix[0][0] = 0.05
        cameraMatrix[1][1] = 0.05

        let state = Self.makeState(
            earthScene: earthScene,
            globe: Self.globe,
            cameraMatrix: cameraMatrix,
            drawSize: CGSize(width: 1024, height: 768)
        )

        XCTAssertEqual(state.diskAlpha, 1.0, accuracy: 0.0001)
        XCTAssertTrue(state.hasVisibleContribution)
        XCTAssertFalse(state.hasVisibleContribution(earthScene: earthScene))
    }

    func testSunBehindGlobeLimbPastDiskRadiusSuppressesDiskAndKeepsHalo() {
        var earthScene = Self.earthScene(limbHaloIntensity: 1)
        let direction = normalize(SIMD3<Float>(0.415, 0, 0.91))
        earthScene.sunDirection = direction
        let expectedGlobeRadius: Float = 0.5
        let expectedScreenCenter = SIMD2<Float>(
            0.5 + direction.x,
            0.5
        )
        let distanceFromGlobeCenter = simd_length(expectedScreenCenter - SIMD2<Float>(0.5, 0.5))
        let limbDistance = abs(distanceFromGlobeCenter - expectedGlobeRadius)
        let expectedHalo = max(0, 1 - limbDistance / earthScene.sunLimbHaloWidth)

        let state = Self.makeState(
            earthScene: earthScene,
            globe: Self.globe,
            cameraMatrix: matrix_identity_float4x4,
            drawSize: CGSize(width: 1000, height: 1000),
            starfieldRadiusScale: 2
        )

        XCTAssertEqual(state.isEnabled, 1)
        XCTAssertEqual(state.screenCenter.x, expectedScreenCenter.x, accuracy: 0.0001)
        XCTAssertEqual(state.screenCenter.y, expectedScreenCenter.y, accuracy: 0.0001)
        XCTAssertEqual(state.globeScreenRadius, expectedGlobeRadius, accuracy: 0.0001)
        XCTAssertEqual(state.diskAlpha, 0.0, accuracy: 0.0001)
        XCTAssertEqual(state.edgeGlareAlpha, 0.0, accuracy: 0.0001)
        XCTAssertEqual(state.limbHaloAlpha, expectedHalo, accuracy: 0.0001)
    }

    func testSunPartiallyBehindGlobeLimbKeepsFadedDiskContribution() {
        var earthScene = Self.earthScene(limbHaloIntensity: 1)
        earthScene.sunDiskAngularSize = 0.075
        let direction = normalize(SIMD3<Float>(0.47, 0, 0.88))
        earthScene.sunDirection = direction

        let state = Self.makeState(
            earthScene: earthScene,
            globe: Self.globe,
            cameraMatrix: matrix_identity_float4x4,
            drawSize: CGSize(width: 1000, height: 1000),
            starfieldRadiusScale: 2
        )

        XCTAssertEqual(state.isEnabled, 1)
        XCTAssertGreaterThan(state.diskAlpha, 0.0)
        XCTAssertLessThan(state.diskAlpha, 1.0)
        XCTAssertEqual(state.edgeGlareAlpha, 0.0, accuracy: 0.0001)
        XCTAssertGreaterThan(state.limbHaloAlpha, 0.0)
    }

    func testSunJustOutsideGlobeLimbAlreadyHasLimbHaloContribution() {
        var earthScene = Self.earthScene(limbHaloIntensity: 1)
        let direction = SIMD3<Float>(0.56, 0, sqrt(1 - 0.56 * 0.56))
        earthScene.sunDirection = direction
        var cameraMatrix = matrix_identity_float4x4
        cameraMatrix[0][0] = 0.5
        cameraMatrix[1][1] = 0.5

        let state = Self.makeState(
            earthScene: earthScene,
            globe: Self.globe,
            cameraMatrix: cameraMatrix,
            drawSize: CGSize(width: 1000, height: 1000),
            starfieldRadiusScale: 2
        )

        XCTAssertEqual(state.isEnabled, 1)
        XCTAssertEqual(state.diskAlpha, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(state.limbHaloAlpha, 0.0)
        XCTAssertLessThan(state.limbHaloAlpha, 1.0)
    }

    func testSunJustOutsideViewportKeepsFadedDiskContribution() {
        var earthScene = Self.earthScene(limbHaloIntensity: 0)
        earthScene.sunDiskAngularSize = 0.075
        let direction = normalize(SIMD3<Float>(0.53, 0, 0.85))
        earthScene.sunDirection = direction

        let state = Self.makeState(
            earthScene: earthScene,
            globe: Self.globe,
            cameraMatrix: matrix_identity_float4x4,
            drawSize: CGSize(width: 1000, height: 1000),
            starfieldRadiusScale: 2
        )

        XCTAssertEqual(state.isEnabled, 1)
        XCTAssertGreaterThan(state.screenCenter.x, 1.0)
        XCTAssertEqual(state.clampedScreenCenter.x, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(state.diskAlpha, 0.0)
        XCTAssertLessThan(state.diskAlpha, 1.0)
    }

    func testWideViewportUsesAspectScaledGlobeRadius() {
        var earthScene = Self.earthScene()
        earthScene.sunDirection = SIMD3<Float>(0, 0.5, Float(sqrt(0.75)))

        let state = Self.makeState(
            earthScene: earthScene,
            globe: Self.globe,
            cameraMatrix: matrix_identity_float4x4,
            drawSize: CGSize(width: 1000, height: 500)
        )

        XCTAssertEqual(state.globeScreenRadius, 0.5, accuracy: 0.0001)
        XCTAssertEqual(state.diskAlpha, 0.0, accuracy: 0.0001)
        XCTAssertEqual(state.edgeGlareAlpha, 1.0, accuracy: 0.0001)
        XCTAssertEqual(state.limbHaloAlpha, 0.0, accuracy: 0.0001)
    }

    func testValidFiniteDirectionsKeepClampedCenterInsideViewport() {
        let directions = [
            normalize(SIMD3<Float>(0.9, 0, 0.44)),
            normalize(SIMD3<Float>(-0.7, 0.2, 0.8)),
            normalize(SIMD3<Float>(0, -0.9, 0.6))
        ]

        for direction in directions {
            var earthScene = Self.earthScene()
            earthScene.sunDirection = direction

            let state = Self.makeState(
                earthScene: earthScene,
                globe: Self.globe,
                cameraMatrix: matrix_identity_float4x4,
                drawSize: CGSize(width: 1024, height: 768)
            )

            XCTAssertGreaterThanOrEqual(state.clampedScreenCenter.x, 0)
            XCTAssertLessThanOrEqual(state.clampedScreenCenter.x, 1)
            XCTAssertGreaterThanOrEqual(state.clampedScreenCenter.y, 0)
            XCTAssertLessThanOrEqual(state.clampedScreenCenter.y, 1)
        }
    }

    func testGlobePanChangesProjectedSunCenter() {
        var earthScene = Self.earthScene()
        earthScene.sunDirection = normalize(SIMD3<Float>(0.55, 0, 0.83))

        let unpanned = Self.makeState(
            earthScene: earthScene,
            globe: GlobeUniform(panX: 0, panY: 0, radius: 1, transition: 0),
            cameraMatrix: matrix_identity_float4x4,
            drawSize: CGSize(width: 1000, height: 1000)
        )
        let panned = Self.makeState(
            earthScene: earthScene,
            globe: GlobeUniform(panX: 0.5, panY: 0, radius: 1, transition: 0),
            cameraMatrix: matrix_identity_float4x4,
            drawSize: CGSize(width: 1000, height: 1000)
        )

        XCTAssertNotEqual(unpanned.screenCenter.x, panned.screenCenter.x, accuracy: 0.0001)
    }

    func testOffscreenProjectedSunKeepsUnclampedCenterAndUsesEdgeGlare() {
        var earthScene = Self.earthScene()
        earthScene.sunDirection = normalize(SIMD3<Float>(1, 0, 0.12))

        let state = Self.makeState(
            earthScene: earthScene,
            globe: GlobeUniform(panX: 0, panY: 0, radius: 1, transition: 0),
            cameraMatrix: matrix_identity_float4x4,
            drawSize: CGSize(width: 1000, height: 1000)
        )

        XCTAssertGreaterThan(state.screenCenter.x, 1.0)
        XCTAssertEqual(state.clampedScreenCenter.x, 1.0, accuracy: 0.0001)
        XCTAssertEqual(state.diskAlpha, 0.0, accuracy: 0.0001)
        XCTAssertEqual(state.edgeGlareAlpha, 1.0, accuracy: 0.0001)
    }

    func testProjectionMatrixChangesGlobeSilhouetteRadius() {
        var earthScene = Self.earthScene()
        earthScene.sunDirection = normalize(SIMD3<Float>(0.2, 0, 0.98))
        let globe = GlobeUniform(panX: 0, panY: 0, radius: 1, transition: 0)
        var wideProjection = matrix_identity_float4x4
        wideProjection[0][0] = 0.5
        wideProjection[1][1] = 0.5

        let regular = Self.makeState(
            earthScene: earthScene,
            globe: globe,
            cameraMatrix: matrix_identity_float4x4,
            drawSize: CGSize(width: 1000, height: 1000)
        )
        let wide = Self.makeState(
            earthScene: earthScene,
            globe: globe,
            cameraMatrix: wideProjection,
            drawSize: CGSize(width: 1000, height: 1000)
        )

        XCTAssertLessThan(wide.globeScreenRadius, regular.globeScreenRadius)
    }

    func testPerspectiveSilhouetteUsesDenseSphereSamples() {
        var earthScene = Self.earthScene()
        earthScene.sunDirection = normalize(SIMD3<Float>(0.2, 0, -0.98))
        let cameraEye = SIMD3<Float>(0.35, 0.2, 1.4)
        let cameraMatrix = Matrix.perspectiveMatrix(fovRadians: .pi / 4,
                                                    aspect: 1,
                                                    near: 0.01,
                                                    far: 20)
            * Matrix.lookAt(eye: cameraEye,
                            center: SIMD3<Float>(0, 0, -1),
                            up: SIMD3<Float>(0, 1, 0))

        let state = Self.makeState(
            earthScene: earthScene,
            globe: Self.globe,
            cameraMatrix: cameraMatrix,
            cameraEye: cameraEye,
            drawSize: CGSize(width: 1000, height: 1000)
        )

        XCTAssertGreaterThan(state.globeScreenRadius, 0.54)
    }

    func testEdgeGlareFadesOutAwayFromViewportEdge() {
        var earthScene = Self.earthScene()
        earthScene.sunDirection = normalize(SIMD3<Float>(0.9, 0, 0.44))
        var cameraMatrix = matrix_identity_float4x4
        cameraMatrix[0][0] = 0.05
        cameraMatrix[1][1] = 0.05

        let state = Self.makeState(
            earthScene: earthScene,
            globe: Self.globe,
            cameraMatrix: cameraMatrix,
            drawSize: CGSize(width: 1024, height: 768)
        )

        XCTAssertEqual(state.diskAlpha, 1.0, accuracy: 0.0001)
        XCTAssertEqual(state.edgeGlareAlpha, 0.0, accuracy: 0.0001)
    }

    func testSunBehindCameraSuppressesAllVisibleContributions() {
        var earthScene = Self.earthScene()
        earthScene.sunDirection = normalize(SIMD3<Float>(0.2, 0, 1))

        let state = Self.makeState(
            earthScene: earthScene,
            globe: Self.globe,
            cameraMatrix: Matrix.perspectiveMatrix(fovRadians: .pi / 4,
                                                   aspect: 1,
                                                   near: 0.01,
                                                   far: 20),
            drawSize: CGSize(width: 1024, height: 768)
        )

        XCTAssertEqual(state.isEnabled, 0)
        XCTAssertEqual(state.diskAlpha, 0.0, accuracy: 0.0001)
        XCTAssertEqual(state.edgeGlareAlpha, 0.0, accuracy: 0.0001)
        XCTAssertEqual(state.limbHaloAlpha, 0.0, accuracy: 0.0001)
    }

    func testDisabledSunVisualReturnsDisabledState() {
        let earthScene = EarthSceneUniform(
            settings: ImmersiveMapSettings.EarthSceneSettings(sun: .init(isEnabled: false)),
            now: .distantPast
        )

        let state = Self.makeState(
            earthScene: earthScene,
            globe: Self.globe,
            cameraMatrix: matrix_identity_float4x4,
            drawSize: CGSize(width: 1024, height: 768)
        )

        XCTAssertEqual(state.isEnabled, 0)
        XCTAssertEqual(state.diskAlpha, 0.0, accuracy: 0.0001)
        XCTAssertEqual(state.edgeGlareAlpha, 0.0, accuracy: 0.0001)
        XCTAssertEqual(state.limbHaloAlpha, 0.0, accuracy: 0.0001)
    }

    func testInvalidDrawSizeReturnsDisabledState() {
        let invalidSizes = [
            CGSize(width: 0, height: 768),
            CGSize(width: 1024, height: -1),
            CGSize(width: CGFloat.nan, height: 768),
            CGSize(width: 1024, height: CGFloat.infinity)
        ]

        for drawSize in invalidSizes {
            let state = Self.makeState(
                earthScene: Self.earthScene(),
                globe: Self.globe,
                cameraMatrix: matrix_identity_float4x4,
                drawSize: drawSize
            )

            XCTAssertEqual(state.isEnabled, 0)
            XCTAssertEqual(state.screenCenter.x, EarthSceneSunVisualState.disabled.screenCenter.x, accuracy: 0.0001)
            XCTAssertEqual(state.screenCenter.y, EarthSceneSunVisualState.disabled.screenCenter.y, accuracy: 0.0001)
            XCTAssertEqual(state.globeScreenRadius, EarthSceneSunVisualState.disabled.globeScreenRadius, accuracy: 0.0001)
            XCTAssertEqual(state.diskAlpha, 0.0, accuracy: 0.0001)
            XCTAssertEqual(state.edgeGlareAlpha, 0.0, accuracy: 0.0001)
            XCTAssertEqual(state.limbHaloAlpha, 0.0, accuracy: 0.0001)
        }
    }

    func testZeroOrNonFiniteSunDirectionReturnsDisabledState() {
        let invalidDirections = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(.nan, 0, 1),
            SIMD3<Float>(0, .infinity, 1)
        ]

        for direction in invalidDirections {
            var earthScene = Self.earthScene()
            earthScene.sunDirection = direction

            let state = Self.makeState(
                earthScene: earthScene,
                globe: Self.globe,
                cameraMatrix: matrix_identity_float4x4,
                drawSize: CGSize(width: 1024, height: 768)
            )

            XCTAssertEqual(state.isEnabled, 0)
            XCTAssertEqual(state.diskAlpha, 0.0, accuracy: 0.0001)
            XCTAssertEqual(state.edgeGlareAlpha, 0.0, accuracy: 0.0001)
            XCTAssertEqual(state.limbHaloAlpha, 0.0, accuracy: 0.0001)
        }
    }

    func testVisualStateMatchesShaderABIRelatedLayout() {
        XCTAssertEqual(MemoryLayout<EarthSceneSunVisualState>.stride, 48)
        XCTAssertEqual(MemoryLayout<EarthSceneSunVisualState>.alignment, 8)
        XCTAssertEqual(MemoryLayout<EarthSceneSunVisualState>.offset(of: \.screenCenter), 0)
        XCTAssertEqual(MemoryLayout<EarthSceneSunVisualState>.offset(of: \.clampedScreenCenter), 8)
        XCTAssertEqual(MemoryLayout<EarthSceneSunVisualState>.offset(of: \.globeScreenCenter), 16)
        XCTAssertEqual(MemoryLayout<EarthSceneSunVisualState>.offset(of: \.globeScreenRadius), 24)
        XCTAssertEqual(MemoryLayout<EarthSceneSunVisualState>.offset(of: \.diskAlpha), 28)
        XCTAssertEqual(MemoryLayout<EarthSceneSunVisualState>.offset(of: \.edgeGlareAlpha), 32)
        XCTAssertEqual(MemoryLayout<EarthSceneSunVisualState>.offset(of: \.limbHaloAlpha), 36)
        XCTAssertEqual(MemoryLayout<EarthSceneSunVisualState>.offset(of: \.isEnabled), 40)
        XCTAssertEqual(MemoryLayout<EarthSceneSunVisualState>.offset(of: \.padding), 44)
    }
}

private extension EarthSceneSunVisualStateTests {
    static let globe = GlobeUniform(panX: 0, panY: 0, radius: 1, transition: 0)

    static func makeState(earthScene: EarthSceneUniform,
                          globe: GlobeUniform,
                          cameraMatrix: matrix_float4x4,
                          cameraEye: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
                          drawSize: CGSize,
                          starfieldRadiusScale: Float = 10.5) -> EarthSceneSunVisualState {
        EarthSceneSunVisualState.make(earthScene: earthScene,
                                      globe: globe,
                                      cameraMatrix: cameraMatrix,
                                      cameraEye: cameraEye,
                                      drawSize: drawSize,
                                      starfieldRadiusScale: starfieldRadiusScale)
    }

    static func earthScene(limbHaloIntensity: Float = 0.4) -> EarthSceneUniform {
        EarthSceneUniform(
            settings: ImmersiveMapSettings.EarthSceneSettings(
                sun: .init(
                    edgeGlareIntensity: 0.6,
                    limbHaloIntensity: limbHaloIntensity,
                    limbHaloWidth: 0.1
                )
            ),
            now: .distantPast
        )
    }
}
