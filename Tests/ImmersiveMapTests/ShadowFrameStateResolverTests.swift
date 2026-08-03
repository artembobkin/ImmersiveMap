// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class ShadowFrameStateResolverTests: XCTestCase {
    private static let equatorCenter = SIMD2<Double>(0.5, 0.5)
    private static let renderMapSize = 2.0 * Double.pi * 0.14 * pow(2.0, 16)

    // MARK: - Gates

    func testDisabledShadowsReturnNil() {
        var scene = Self.makeScene()
        scene.shadows.isEnabled = false
        XCTAssertNil(Self.resolve(scene: scene))

        scene.shadows.isEnabled = true
        scene.shadows.strength = 0
        XCTAssertNil(Self.resolve(scene: scene))
    }

    func testSphericalModeReturnsNil() {
        XCTAssertNil(Self.resolve(renderSurfaceMode: .spherical))
    }

    func testHorizontalOrDegenerateLightReturnsNil() {
        var scene = Self.makeScene()
        scene.light.direction = SIMD3<Float>(1, 1, 0.01)
        XCTAssertNil(Self.resolve(scene: scene))

        scene.light.direction = SIMD3<Float>(0.3, 0.3, -1)
        XCTAssertNil(Self.resolve(scene: scene))

        scene.light.direction = .zero
        XCTAssertNil(Self.resolve(scene: scene))
    }

    func testStrengthAndResolutionAreClamped() {
        var scene = Self.makeScene()
        scene.shadows.strength = 3.0
        scene.shadows.mapResolution = 100_000

        let state = try? XCTUnwrap(Self.resolve(scene: scene))
        XCTAssertEqual(state?.shadowUniform.strength, 1.0)
        XCTAssertEqual(state?.mapResolution, 4096)

        scene.shadows.mapResolution = 16
        let smallState = try? XCTUnwrap(Self.resolve(scene: scene))
        XCTAssertEqual(smallState?.mapResolution, 256)
    }

    // MARK: - Cascade fit properties

    /// Every receiver point of a cascade's disc (boundary at the ground and
    /// lifted to the caster cap) must land inside that cascade's NDC volume,
    /// and a caster on the ray towards the light above such a point must keep
    /// a non-negative depth (the extended near plane covers it).
    func testDiscReceiversAndCastersStayInsideCascadeVolumes() {
        var random = SplitMix64ShadowTests(seed: 0x5AD0_11FE)
        let caps = [ShadowFrameStateResolver.nearCascadeMaxCasterHeightMeters,
                    ShadowFrameStateResolver.farCascadeMaxCasterHeightMeters]

        for iteration in 0..<30 {
            let pitch = Float.random(in: 0...(75 * .pi / 180), using: &random)
            let bearing = Float.random(in: 0...(2 * .pi), using: &random)
            let distance = Float.random(in: 0.5...1.0, using: &random)
            let lightDirection = simd_normalize(SIMD3<Float>(Float.random(in: -1...1, using: &random),
                                                             Float.random(in: -1...1, using: &random),
                                                             Float.random(in: 0.15...1.2, using: &random)))
            let eye = Self.makeEye(pitch: pitch, bearing: bearing, distance: distance)
            var scene = Self.makeScene()
            scene.light.direction = lightDirection

            guard let state = Self.resolve(eye: eye, scene: scene) else {
                XCTFail("iteration \(iteration): expected a shadow state")
                continue
            }

            let cameraDistance = simd_length(eye)
            let radii = [ShadowFrameStateResolver.nearCascadeRadiusCameraDistances * cameraDistance,
                         scene.shadows.coverageCameraDistances * cameraDistance]
            let unitsPerMeter = ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: 0,
                                                                          renderMapSize: Self.renderMapSize)
            let tolerance: Float = 1e-3
            for cascadeIndex in 0..<2 {
                let maxCasterHeight = Float(caps[cascadeIndex] * unitsPerMeter)
                let matrix = state.lightProjectionViews[cascadeIndex]
                for pointIndex in 0..<8 {
                    let angle = Float(pointIndex) * (.pi / 4)
                    let vertex = SIMD2<Float>(cos(angle), sin(angle)) * radii[cascadeIndex]
                    for z in [Float(0), maxCasterHeight] {
                        let ndc = Self.project(matrix, SIMD3<Float>(vertex.x, vertex.y, z))
                        XCTAssertLessThanOrEqual(abs(ndc.x), 1 + tolerance, "iteration \(iteration)")
                        XCTAssertLessThanOrEqual(abs(ndc.y), 1 + tolerance, "iteration \(iteration)")
                        XCTAssertGreaterThanOrEqual(ndc.z, -tolerance, "iteration \(iteration)")
                        XCTAssertLessThanOrEqual(ndc.z, 1 + tolerance, "iteration \(iteration)")
                    }

                    let liftDistance = maxCasterHeight / lightDirection.z
                    let caster = SIMD3<Float>(vertex.x, vertex.y, 0) + lightDirection * liftDistance
                    let casterNDC = Self.project(matrix, caster)
                    XCTAssertGreaterThanOrEqual(casterNDC.z, -tolerance,
                                                "iteration \(iteration): caster fell out of the near plane")
                }
            }
        }
    }

    /// The whole point of disc fitting: with the camera distance fixed, pitch
    /// and bearing must not change the cascades at all — same matrices, same
    /// bias, same kernel. Only `eye` (the fade origin) differs.
    func testCascadesAreInvariantToPitchAndBearing() throws {
        let reference = try XCTUnwrap(Self.resolve(eye: Self.makeEye(pitch: 0.01, bearing: 0, distance: 0.8)))
        let poses: [(Float, Float)] = [(40 * .pi / 180, 0.7), (70 * .pi / 180, 2.1), (10 * .pi / 180, 4.0)]
        for (pitch, bearing) in poses {
            let state = try XCTUnwrap(Self.resolve(eye: Self.makeEye(pitch: pitch, bearing: bearing, distance: 0.8)))
            for cascadeIndex in 0..<2 {
                let expected = cascadeIndex == 0 ? reference.shadowUniform.cascadeNear : reference.shadowUniform.cascadeFar
                let actual = cascadeIndex == 0 ? state.shadowUniform.cascadeNear : state.shadowUniform.cascadeFar
                for column in 0..<4 {
                    XCTAssertEqual(simd_distance(expected.worldToShadowTexture[column],
                                                 actual.worldToShadowTexture[column]), 0, accuracy: 1e-5,
                                   "cascade \(cascadeIndex) matrix drifted at pitch \(pitch)")
                }
                XCTAssertEqual(expected.depthBias, actual.depthBias, accuracy: 1e-9)
                XCTAssertEqual(expected.kernelRadiusUV, actual.kernelRadiusUV)
            }
        }
    }

    /// The texel grid must stay glued to map content while the camera pans:
    /// content translates by `(Δpan.x, -Δpan.y) · mapSize/2`, and after the
    /// pan-anchored snap the same content point may land in a different texel
    /// *index*, but its position *inside* a texel must not change — otherwise
    /// shadow edges crawl during movement.
    func testTexelGridStaysGluedToContentAcrossPan() throws {
        let eye = Self.makeEye(pitch: 40 * .pi / 180, bearing: 0.7, distance: 0.8)
        let halfMapSize = Self.renderMapSize * 0.5
        let pan1 = SIMD2<Double>(0.312, -0.144)
        let pan2 = pan1 + SIMD2<Double>(3.7e-7, -2.2e-7)

        let state1 = try XCTUnwrap(Self.resolve(eye: eye, flatRenderPan: pan1))
        let state2 = try XCTUnwrap(Self.resolve(eye: eye, flatRenderPan: pan2))

        let contentShift = SIMD2<Double>((pan2.x - pan1.x) * halfMapSize,
                                         -(pan2.y - pan1.y) * halfMapSize)
        // Atlas texel counts: u spans two cascade halves.
        let texelsU = Float(state1.mapResolution * 2)
        let texelsV = Float(state1.mapResolution)
        let probes: [SIMD3<Float>] = [
            SIMD3<Float>(0.05, -0.1, 0),
            SIMD3<Float>(-0.12, 0.07, 0.001),
            SIMD3<Float>(0, 0, 0)
        ]
        let cascades1 = [state1.shadowUniform.cascadeNear, state1.shadowUniform.cascadeFar]
        let cascades2 = [state2.shadowUniform.cascadeNear, state2.shadowUniform.cascadeFar]
        for cascadeIndex in 0..<2 {
            for w1 in probes {
                let w2 = SIMD3<Float>(w1.x + Float(contentShift.x),
                                      w1.y + Float(contentShift.y),
                                      w1.z)
                let uv1 = Self.projectUV(cascades1[cascadeIndex].worldToShadowTexture, w1)
                let uv2 = Self.projectUV(cascades2[cascadeIndex].worldToShadowTexture, w2)
                let dx = (uv1.x - uv2.x) * texelsU
                let dy = (uv1.y - uv2.y) * texelsV
                XCTAssertEqual(dx, dx.rounded(), accuracy: 0.05, "cascade \(cascadeIndex) slid along X")
                XCTAssertEqual(dy, dy.rounded(), accuracy: 0.05, "cascade \(cascadeIndex) slid along Y")
            }
        }
    }

    /// The receiver bias derives from the texel footprint: a finer map must
    /// bring the comparison bias down proportionally.
    func testReceiverBiasScalesWithTexelSize() throws {
        var scene = Self.makeScene()
        scene.shadows.mapResolution = 1024
        let coarse = try XCTUnwrap(Self.resolve(scene: scene))

        scene.shadows.mapResolution = 4096
        let fine = try XCTUnwrap(Self.resolve(scene: scene))

        for (coarseCascade, fineCascade) in [(coarse.shadowUniform.cascadeNear, fine.shadowUniform.cascadeNear),
                                             (coarse.shadowUniform.cascadeFar, fine.shadowUniform.cascadeFar)] {
            XCTAssertGreaterThan(coarseCascade.depthBias, 0)
            XCTAssertGreaterThan(fineCascade.depthBias, 0)
            XCTAssertEqual(coarseCascade.depthBias / fineCascade.depthBias, 4.0, accuracy: 0.2)
            XCTAssertLessThan(coarseCascade.depthBias, 0.01,
                              "Bias must stay a tiny fraction of the depth window")
        }
    }

    /// Near cascade uses a sub-texel anti-staircase spread, far the wide
    /// Poisson radius — both in atlas-UV units (u is a half of the texture).
    func testKernelRadiiPerCascade() throws {
        let state = try XCTUnwrap(Self.resolve())
        let resolution = Float(state.mapResolution)

        let nearExpected = ShadowFrameStateResolver.nearKernelRadiusTexels
        XCTAssertEqual(state.shadowUniform.cascadeNear.kernelRadiusUV.x, nearExpected * 0.5 / resolution, accuracy: 1e-9)
        XCTAssertEqual(state.shadowUniform.cascadeNear.kernelRadiusUV.y, nearExpected / resolution, accuracy: 1e-9)

        let farExpected = ShadowFrameStateResolver.farKernelRadiusTexels
        XCTAssertEqual(state.shadowUniform.cascadeFar.kernelRadiusUV.x, farExpected * 0.5 / resolution, accuracy: 1e-9)
        XCTAssertEqual(state.shadowUniform.cascadeFar.kernelRadiusUV.y, farExpected / resolution, accuracy: 1e-9)
    }

    /// Normal offsets are texel-driven but meter-capped (an uncapped far
    /// offset reaches 10+ meters and would push wall receivers past their real
    /// occluders), and each cascade publishes its texel size for the per-tap
    /// slope bias.
    func testNormalOffsetIsTexelDrivenButMeterCapped() throws {
        let state = try XCTUnwrap(Self.resolve())
        let near = state.shadowUniform.cascadeNear
        let far = state.shadowUniform.cascadeFar
        let unitsPerMeter = ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: 0,
                                                                     renderMapSize: Self.renderMapSize)
        let cap = Float(ShadowFrameStateResolver.normalOffsetMetersCap * unitsPerMeter)

        XCTAssertGreaterThan(near.normalOffsetWorld, 0)
        XCTAssertGreaterThanOrEqual(far.normalOffsetWorld, near.normalOffsetWorld)
        XCTAssertLessThanOrEqual(near.normalOffsetWorld, cap * 1.0001)
        XCTAssertLessThanOrEqual(far.normalOffsetWorld, cap * 1.0001)

        let expectedTexelUV = SIMD2<Float>(0.5 / Float(state.mapResolution),
                                           1.0 / Float(state.mapResolution))
        XCTAssertEqual(near.texelSizeUV, expectedTexelUV)
        XCTAssertEqual(far.texelSizeUV, expectedTexelUV)
        XCTAssertGreaterThan(near.gradientClamp, 0)
        XCTAssertGreaterThan(far.gradientClamp, 0)
    }

    func testAtlasRectsAndFadeFollowCameraDistance() throws {
        let eye = Self.makeEye(pitch: 30 * .pi / 180, bearing: 0.4, distance: 0.8)
        let state = try XCTUnwrap(Self.resolve(eye: eye))

        let near = state.shadowUniform.cascadeNear
        let far = state.shadowUniform.cascadeFar
        XCTAssertGreaterThan(near.uvMinimum.x, 0)
        XCTAssertLessThan(near.uvMaximum.x, 0.5)
        XCTAssertGreaterThan(far.uvMinimum.x, 0.5)
        XCTAssertLessThan(far.uvMaximum.x, 1.0)

        let expectedRadius = ImmersiveMapSettings.default.scene.shadows.coverageCameraDistances * simd_length(eye)
        XCTAssertEqual(state.shadowUniform.fadeEndDistance, expectedRadius, accuracy: expectedRadius * 1e-5)
        XCTAssertEqual(state.shadowUniform.fadeStartDistance, expectedRadius * 0.75, accuracy: expectedRadius * 1e-5)
        XCTAssertEqual(state.shadowUniform.eye, eye)

        // The geometric self-shadow test in the shaders relies on a normalized
        // sun direction.
        XCTAssertEqual(simd_length(state.shadowUniform.lightDirection), 1.0, accuracy: 1e-6)
        let expectedDirection = simd_normalize(ImmersiveMapSettings.default.scene.light.direction)
        XCTAssertEqual(simd_distance(state.shadowUniform.lightDirection, expectedDirection), 0, accuracy: 1e-6)
    }

    // MARK: - Helpers

    private static func makeScene() -> ImmersiveMapSettings.SceneSettings {
        ImmersiveMapSettings.default.scene
    }

    private static func makeEye(pitch: Float, bearing: Float, distance: Float) -> SIMD3<Float> {
        SIMD3<Float>(sin(bearing) * sin(pitch) * distance,
                     -cos(bearing) * sin(pitch) * distance,
                     cos(pitch) * distance)
    }

    private static func resolve(renderSurfaceMode: ViewMode = .flat,
                                eye: SIMD3<Float> = SIMD3<Float>(0.2, -0.35, 0.7),
                                flatRenderPan: SIMD2<Double> = SIMD2<Double>(0.312, -0.144),
                                scene: ImmersiveMapSettings.SceneSettings = ImmersiveMapSettings.default.scene) -> ShadowFrameState? {
        ShadowFrameStateResolver.resolve(renderSurfaceMode: renderSurfaceMode,
                                         cameraEye: eye,
                                         centerWorldMercator: equatorCenter,
                                         flatRenderPan: flatRenderPan,
                                         renderMapSize: renderMapSize,
                                         scene: scene)
    }

    private static func project(_ matrix: matrix_float4x4, _ point: SIMD3<Float>) -> SIMD3<Float> {
        let clip = matrix * SIMD4<Float>(point.x, point.y, point.z, 1)
        return SIMD3<Float>(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w)
    }

    private static func projectUV(_ matrix: matrix_float4x4, _ point: SIMD3<Float>) -> SIMD2<Float> {
        let projected = matrix * SIMD4<Float>(point.x, point.y, point.z, 1)
        return SIMD2<Float>(projected.x / projected.w, projected.y / projected.w)
    }
}

/// Deterministic generator for reproducible property tests.
private struct SplitMix64ShadowTests: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
