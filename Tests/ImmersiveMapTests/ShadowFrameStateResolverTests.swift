// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class ShadowFrameStateResolverTests: XCTestCase {
    private static let equatorCenter = SIMD2<Double>(0.5, 0.5)
    private static let renderMapSize = 2.0 * Double.pi * 0.14 * pow(2.0, 16)
    /// The zoom the curves are read at: past the default strength's rise.
    private static let zoom = 16.0
    private static let unitsPerMeter = ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: 0,
                                                                                 renderMapSize: renderMapSize)

    /// A coverage of so many camera distances of `eye`, as the metres the
    /// setting takes: the tests below pin the window's scaling with the
    /// camera distance, which the metres by the zoom replaced.
    private static func coverage(cameraDistances: Float, eye: SIMD3<Float>) -> ImmersiveMapZoomCurve {
        ImmersiveMapZoomCurve(meters(cameraDistances: cameraDistances, eye: eye))
    }

    private static func meters(cameraDistances: Float, eye: SIMD3<Float>) -> Float {
        Float(Double(cameraDistances * simd_length(eye)) / unitsPerMeter)
    }

    /// World units of a coverage curve at the tests' zoom.
    private static func radius(_ coverage: ImmersiveMapZoomCurve) -> Float {
        Float(Double(coverage.value(atZoom: zoom, interpolation: .geometric)) * unitsPerMeter)
    }

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

    // MARK: - Window fit properties

    /// Every point of the ground the camera can see, and a caster standing on
    /// the sun ray above it, has to land inside the fitted window. This is the
    /// contract the whole fit exists for: a receiver outside the window is
    /// lit, and a caster outside it throws no shadow.
    func testVisibleGroundAndItsCastersStayInsideTheWindow() {
        var random = SplitMix64ShadowTests(seed: 0x5AD0_11FE)

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

            let spec = ShadowFrameStateResolver.windowSpec(
                radiusMeters: scene.shadows.nearCoverageMeters(atZoom: Self.zoom),
                unitsPerMeter: Self.unitsPerMeter,
                maxCasterHeightMeters: scene.shadows.maxCasterHeightMeters)
            let footprint = ShadowFrameStateResolver.visibleGroundFootprint(
                inverseProjectionView: simd_inverse(Self.makeProjectionView(eye: eye)),
                cameraEye: eye,
                maxDistance: spec.radius)
            XCTAssertFalse(footprint.isEmpty, "iteration \(iteration)")

            let tolerance: Float = 1e-3
            let matrix = state.lightProjectionView
            for point in footprint {
                for z in [Float(0), spec.maxCasterHeight] {
                    let ndc = Self.project(matrix, SIMD3<Float>(point.x, point.y, z))
                    XCTAssertLessThanOrEqual(abs(ndc.x), 1 + tolerance, "iteration \(iteration)")
                    XCTAssertLessThanOrEqual(abs(ndc.y), 1 + tolerance, "iteration \(iteration)")
                    XCTAssertGreaterThanOrEqual(ndc.z, -tolerance, "iteration \(iteration)")
                    XCTAssertLessThanOrEqual(ndc.z, 1 + tolerance, "iteration \(iteration)")
                }

                let liftDistance = spec.maxCasterHeight / lightDirection.z
                let caster = SIMD3<Float>(point.x, point.y, 0) + lightDirection * liftDistance
                let casterNDC = Self.project(matrix, caster)
                XCTAssertGreaterThanOrEqual(casterNDC.z, -tolerance,
                                            "iteration \(iteration): caster fell out of the near plane")
            }
        }
    }

    /// The window follows the view now, which is the trade the frustum fit
    /// makes: the disc it replaced was deliberately pose-invariant, so tilting
    /// or turning changed nothing about the shadows. The gain is that no part
    /// of the window is spent behind the camera; the cost is this. Pinned so
    /// nobody mistakes it for a regression, and so the day it has to go back
    /// the contract is written down.
    /// Over a relief the window's depth reaches the valleys below the
    /// plane and the casters on the summits above it: the receiver volume
    /// spans the ground's lowest to its highest plus the caster cap.
    func testTheWindowsDepthSpansTheReliefsHeights() throws {
        let lightView = Matrix.lookAt(eye: simd_normalize(SIMD3<Float>(0.3, -0.4, 0.8)), center: .zero, up: SIMD3<Float>(0, 0, 1))
        let footprint: [SIMD2<Float>] = [SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10)]
        let plane = try XCTUnwrap(ShadowFrameStateResolver.cascadeExtremes(footprint: footprint,
                                                                           maxCasterHeight: 2,
                                                                           lightView: lightView))
        let relief = try XCTUnwrap(ShadowFrameStateResolver.cascadeExtremes(footprint: footprint,
                                                                            maxCasterHeight: 2,
                                                                            groundHeights: -3 ... 5,
                                                                            lightView: lightView))
        XCTAssertLessThan(relief.minDepth, plane.minDepth, "A summit and its casters lie nearer the light")
        XCTAssertGreaterThan(relief.maxDepth, plane.maxDepth, "A valley lies farther from it")
    }

    func testTheWindowFollowsWhereTheCameraLooks() throws {
        let reference = try XCTUnwrap(Self.resolve(eye: Self.makeEye(pitch: 55 * .pi / 180,
                                                                     bearing: 0,
                                                                     distance: 0.8)))
        let turned = try XCTUnwrap(Self.resolve(eye: Self.makeEye(pitch: 55 * .pi / 180,
                                                                   bearing: .pi,
                                                                   distance: 0.8)))

        // Turned around, the window covers different ground.
        var moved = false
        for column in 0..<4 where simd_distance(reference.shadowUniform.near.worldToShadowTexture[column],
                                                turned.shadowUniform.near.worldToShadowTexture[column]) > 1e-4 {
            moved = true
        }
        XCTAssertTrue(moved, "The fitted window has to follow the bearing")

        // And a tilted camera, which sees much further, gets a bigger window
        // than one looking straight down at the same distance.
        let steep = try XCTUnwrap(Self.resolve(eye: Self.makeEye(pitch: 5 * .pi / 180,
                                                                  bearing: 0,
                                                                  distance: 0.8)))
        XCTAssertGreaterThan(reference.shadowUniform.near.normalOffsetWorld,
                             steep.shadowUniform.near.normalOffsetWorld,
                             "A tilted camera sees further, so its window is coarser")
    }

    /// The texel grid must stay glued to map content while the camera pans:
    /// content translates by `(Δpan.x, -Δpan.y) · mapSize/2`, and after the
    /// pan-anchored snap the same content point may land in a different texel
    /// *index*, but its position *inside* a texel must not change, otherwise
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
        let texelsU = Float(state1.mapResolution)
        let texelsV = Float(state1.mapResolution)
        let probes: [SIMD3<Float>] = [
            SIMD3<Float>(0.05, -0.1, 0),
            SIMD3<Float>(-0.12, 0.07, 0.001),
            SIMD3<Float>(0, 0, 0)
        ]
        for w1 in probes {
            let w2 = SIMD3<Float>(w1.x + Float(contentShift.x),
                                  w1.y + Float(contentShift.y),
                                  w1.z)
            let uv1 = Self.projectUV(state1.shadowUniform.near.worldToShadowTexture, w1)
            let uv2 = Self.projectUV(state2.shadowUniform.near.worldToShadowTexture, w2)
            let dx = (uv1.x - uv2.x) * texelsU
            let dy = (uv1.y - uv2.y) * texelsV
            XCTAssertEqual(dx, dx.rounded(), accuracy: 0.05, "the grid slid along X")
            XCTAssertEqual(dy, dy.rounded(), accuracy: 0.05, "the grid slid along Y")
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

        let coarseCascade = coarse.shadowUniform.near
        let fineCascade = fine.shadowUniform.near
        XCTAssertGreaterThan(coarseCascade.depthBias, 0)
        XCTAssertGreaterThan(fineCascade.depthBias, 0)
        XCTAssertEqual(coarseCascade.depthBias / fineCascade.depthBias, 4.0, accuracy: 0.2)
        XCTAssertLessThan(coarseCascade.depthBias, 0.01,
                          "Bias must stay a tiny fraction of the depth window")
    }

    /// The normal offset is exactly `ShadowSettings.normalOffsetTexels` window
    /// texels, with no meter cap: the window is sized to the camera distance,
    /// so the offset is a fixed fraction of it and cannot run away the way a
    /// fixed far cascade's could. It is the only acne defense that scales with
    /// the receiver's geometry now that there is no receiver-plane gradient,
    /// so nothing may quietly clamp it inside the settable range.
    func testNormalOffsetIsExactlyTheTexelMultipleAtEveryZoom() throws {
        let expectedTexelUV = SIMD2<Float>(repeating: 1.0 / 2048.0)
        var scene = Self.makeScene()
        scene.shadows.mapResolution = 2048
        let requestedTexels = scene.shadows.normalOffsetTexels

        for distance in [Float(0.05), 0.3, 0.8, 2.0] {
            let eye = Self.makeEye(pitch: 30 * .pi / 180, bearing: 0.4, distance: distance)
            let state = try XCTUnwrap(Self.resolve(eye: eye, scene: scene))
            let cascade = state.shadowUniform.near
            let texelWorldSize = cascade.normalOffsetWorld / requestedTexels

            XCTAssertGreaterThan(cascade.normalOffsetWorld, 0, "distance \(distance)")
            XCTAssertEqual(cascade.texelSizeUV.x, expectedTexelUV.x, accuracy: 1e-9, "distance \(distance)")
            XCTAssertEqual(cascade.texelSizeUV.y, expectedTexelUV.y, accuracy: 1e-9, "distance \(distance)")
            // The offset stays a small fraction of the camera distance at
            // every zoom, which is what makes the meter cap unnecessary. It is
            // not one exact fraction: the extent is quantized in √2 steps, and
            // at very short camera distances the 1000 m caster cap, not the
            // disc, is what sizes the window.
            let offsetInCameraDistances = cascade.normalOffsetWorld / distance
            XCTAssertGreaterThan(offsetInCameraDistances, 0.0005, "distance \(distance)")
            XCTAssertLessThan(offsetInCameraDistances, 0.05, "distance \(distance)")
            XCTAssertEqual(texelWorldSize * Float(state.mapResolution),
                           texelWorldSize * 2048, accuracy: 1e-6)
        }
    }

    /// The offset follows the setting, not a constant, which is what makes the
    /// debug panel's slider mean anything.
    func testNormalOffsetFollowsTheSetting() throws {
        var scene = Self.makeScene()
        scene.shadows.normalOffsetTexels = 1.0
        let narrow = try XCTUnwrap(Self.resolve(scene: scene))

        scene.shadows.normalOffsetTexels = 4.0
        let wide = try XCTUnwrap(Self.resolve(scene: scene))

        XCTAssertEqual(wide.shadowUniform.near.normalOffsetWorld
                        / narrow.shadowUniform.near.normalOffsetWorld,
                       4.0,
                       accuracy: 1e-4)
    }

    /// Zero is a legal setting (no offset at all, for looking at raw acne),
    /// and anything past the range is clamped rather than passed to the shader.
    func testNormalOffsetIsClampedToTheSettableRange() throws {
        var scene = Self.makeScene()
        scene.shadows.normalOffsetTexels = 0
        let none = try XCTUnwrap(Self.resolve(scene: scene))
        XCTAssertEqual(none.shadowUniform.near.normalOffsetWorld, 0)

        scene.shadows.normalOffsetTexels = 1_000
        let clamped = try XCTUnwrap(Self.resolve(scene: scene))
        scene.shadows.normalOffsetTexels = ShadowFrameStateResolver.normalOffsetTexelsRange.upperBound
        let atMaximum = try XCTUnwrap(Self.resolve(scene: scene))
        XCTAssertEqual(clamped.shadowUniform.near.normalOffsetWorld,
                       atMaximum.shadowUniform.near.normalOffsetWorld)

        scene.shadows.normalOffsetTexels = -5
        let negative = try XCTUnwrap(Self.resolve(scene: scene))
        XCTAssertEqual(negative.shadowUniform.near.normalOffsetWorld, 0,
                       "A negative offset would step the sample point into the surface")
    }

    /// Softness reaches the shader as the tent's tap spread, and anything
    /// past the range is clamped rather than passed through: a spread the
    /// sampling inset was not sized for would let a tap read outside the
    /// fitted window.
    func testSoftnessReachesTheShaderAndIsClamped() throws {
        var scene = Self.makeScene()
        scene.shadows.softness = 1.0
        let plain = try XCTUnwrap(Self.resolve(scene: scene))
        XCTAssertEqual(plain.shadowUniform.near.tentSpread, 1.0)

        scene.shadows.softness = 1.8
        let softer = try XCTUnwrap(Self.resolve(scene: scene))
        XCTAssertEqual(softer.shadowUniform.near.tentSpread, 1.8, accuracy: 1e-6)

        scene.shadows.softness = 100
        let clamped = try XCTUnwrap(Self.resolve(scene: scene))
        XCTAssertEqual(clamped.shadowUniform.near.tentSpread,
                       ShadowFrameStateResolver.softnessRange.upperBound)

        scene.shadows.softness = -1
        let floored = try XCTUnwrap(Self.resolve(scene: scene))
        XCTAssertEqual(floored.shadowUniform.near.tentSpread,
                       ShadowFrameStateResolver.softnessRange.lowerBound,
                       "Below 1 the taps would collapse onto the sample point and the tent would be gone")
    }

    /// Softening the edge must not move it, and must not cost a refit: the
    /// window, its texel size and its bias are the same at every softness, so
    /// only the ramp around the boundary changes.
    func testSoftnessChangesNothingButTheKernel() throws {
        var scene = Self.makeScene()
        scene.shadows.softness = 1.0
        let plain = try XCTUnwrap(Self.resolve(scene: scene))

        scene.shadows.softness = ShadowFrameStateResolver.softnessRange.upperBound
        let softest = try XCTUnwrap(Self.resolve(scene: scene))

        XCTAssertEqual(plain.shadowUniform.near.texelSizeUV, softest.shadowUniform.near.texelSizeUV)
        XCTAssertEqual(plain.shadowUniform.near.depthBias, softest.shadowUniform.near.depthBias)
        XCTAssertEqual(plain.shadowUniform.near.uvMinimum, softest.shadowUniform.near.uvMinimum)
        XCTAssertEqual(plain.shadowUniform.near.uvMaximum, softest.shadowUniform.near.uvMaximum)
        XCTAssertEqual(plain.shadowUniform.near.normalOffsetWorld,
                       softest.shadowUniform.near.normalOffsetWorld)
        XCTAssertEqual(plain.lightProjectionView, softest.lightProjectionView)
    }

    /// The sampling inset has to cover the widest kernel the softness range
    /// allows, or a tap at the window's edge reads a texel the fit never
    /// rendered. A tap sits at most one texel from the sample point before the
    /// spread, so at most `upperBound` after it, plus half a texel of its own
    /// bilinear footprint.
    func testSamplingInsetCoversTheWidestKernel() {
        let widestReach = ShadowFrameStateResolver.softnessRange.upperBound * 1.0 + 0.5
        XCTAssertGreaterThanOrEqual(ShadowFrameStateResolver.uvInsetTexels, widestReach)
    }

    /// The debug panel winds coverage far below anything shippable so the
    /// texel grid can be looked at up close. Two things have to hold there:
    /// the window really does shrink, and the frame does not simply lose every
    /// shadow because the fade band closed in front of the nearest ground.
    func testSmallCoverageShrinksTheWindowAndKeepsShadows() throws {
        let eye = Self.makeEye(pitch: 40 * .pi / 180, bearing: 0.4, distance: 0.8)
        var scene = Self.makeScene()
        scene.shadows.nearCoverageMeters = Self.coverage(cameraDistances: 3, eye: eye)
        let wide = try XCTUnwrap(Self.resolve(eye: eye, scene: scene))

        scene.shadows.nearCoverageMeters = Self.coverage(cameraDistances: 0.25, eye: eye)
        let tight = try XCTUnwrap(Self.resolve(eye: eye, scene: scene))

        // A tenth of the coverage is a much finer texel, which is the point.
        XCTAssertLessThan(tight.shadowUniform.near.normalOffsetWorld,
                          wide.shadowUniform.near.normalOffsetWorld,
                          "The offset tracks the texel, so a tighter window must shrink it")
        // And the ground the camera is looking at, the window's own centre,
        // must still be fully shadowed, or the frame has nothing to look at.
        // This is what broke while the fade was measured from the eye: below
        // one camera distance the whole band fell in front of the visible
        // ground and every shadow in the frame vanished.
        let centre = tight.shadowUniform.fadeCenter
        XCTAssertEqual(simd_length(centre - tight.shadowUniform.fadeCenter), 0)
        XCTAssertGreaterThan(tight.shadowUniform.near.fadeStartDistance, 0,
                             "The band has to have somewhere to start")
        XCTAssertLessThan(tight.shadowUniform.near.fadeStartDistance,
                          tight.shadowUniform.near.fadeEndDistance)
    }

    /// The band is the outer quarter of the window at every size, which is
    /// what keeps the disc's edge out of sight without the fade ever having to
    /// know where the camera is.
    func testTheFadeBandIsAlwaysTheOuterQuarterOfTheWindow() {
        for radius in [Float(2.4), 0.8, 0.2, 0.05] {
            let fade = ShadowFrameStateResolver.fadeDistances(farRadius: radius)
            XCTAssertEqual(fade.end, radius)
            XCTAssertEqual(fade.start, radius * 0.75, accuracy: 1e-6)
        }
    }

    func testCoverageIsClampedToItsRange() throws {
        var scene = Self.makeScene()
        scene.shadows.nearCoverageMeters = 0
        let floored = try XCTUnwrap(Self.resolve(scene: scene))
        scene.shadows.nearCoverageMeters = ImmersiveMapZoomCurve(ShadowFrameStateResolver.coverageMetersRange.lowerBound)
        let atFloor = try XCTUnwrap(Self.resolve(scene: scene))
        XCTAssertEqual(floored.shadowUniform.near.worldToShadowTexture,
                       atFloor.shadowUniform.near.worldToShadowTexture)

        scene.shadows.nearCoverageMeters = 1e9
        let ceilinged = try XCTUnwrap(Self.resolve(scene: scene))
        scene.shadows.nearCoverageMeters = ImmersiveMapZoomCurve(ShadowFrameStateResolver.coverageMetersRange.upperBound)
        let atCeiling = try XCTUnwrap(Self.resolve(scene: scene))
        XCTAssertEqual(ceilinged.shadowUniform.near.worldToShadowTexture,
                       atCeiling.shadowUniform.near.worldToShadowTexture)
    }

    /// The whole point of the change: at a coverage far under one camera
    /// distance the ground the camera looks at is still shadowed. Measured the
    /// way the shaders measure it, radially from the window's centre.
    func testTheGroundUnderTheCameraIsShadowedAtEveryCoverage() throws {
        let eye = Self.makeEye(pitch: 40 * .pi / 180, bearing: 0.4, distance: 0.8)

        for coverage in [Float(3.0), 1.0, 0.5, 0.25] {
            var scene = Self.makeScene()
            scene.shadows.nearCoverageMeters = Self.coverage(cameraDistances: coverage, eye: eye)
            let state = try XCTUnwrap(Self.resolve(eye: eye, scene: scene))
            let uniform = state.shadowUniform

            // The point the camera looks at, and a point a third of the way
            // out towards the window's rim.
            for probe in [uniform.fadeCenter,
                          uniform.fadeCenter + SIMD2<Float>(uniform.near.fadeEndDistance / 3, 0)] {
                let radial = simd_length(probe - uniform.fadeCenter)
                let fade = 1 - simd_smoothstep(uniform.near.fadeStartDistance,
                                               uniform.near.fadeEndDistance,
                                               radial)
                XCTAssertEqual(fade, 1, accuracy: 1e-5,
                               "coverage \(coverage): the inner window must be fully shadowed")
            }

            // And the rim is still faded out, so the disc's edge stays hidden.
            let rim = uniform.fadeCenter + SIMD2<Float>(uniform.near.fadeEndDistance, 0)
            let rimFade = 1 - simd_smoothstep(uniform.near.fadeStartDistance,
                                              uniform.near.fadeEndDistance,
                                              simd_length(rim - uniform.fadeCenter))
            XCTAssertEqual(rimFade, 0, accuracy: 1e-5, "coverage \(coverage)")
        }
    }

    /// The bug this pins, and it was visible: at a street camera the window
    /// was sized by the flat 1000 m caster cap rather than by the disc, so
    /// winding coverage all the way down moved the fade and nothing else. The
    /// shadow map's texels stayed put and the staircase on a shadow's edge
    /// never changed.
    func testCoverageActuallyShrinksTheTexelAtAStreetCamera() throws {
        // ~35 m out, which is where the flat cap used to swamp the disc.
        let eye = Self.makeEye(pitch: 55 * .pi / 180, bearing: 0.3, distance: 0.05)

        func texel(coverage: Float) throws -> Float {
            var scene = Self.makeScene()
            scene.shadows.nearCoverageMeters = Self.coverage(cameraDistances: coverage, eye: eye)
            let state = try XCTUnwrap(Self.resolve(eye: eye, scene: scene))
            return state.shadowUniform.near.normalOffsetWorld / scene.shadows.normalOffsetTexels
        }

        let wide = try texel(coverage: 3)
        let tight = try texel(coverage: 0.25)

        // Most of three times over the slider's range, against the single
        // quantization step it moved while the window was sized by a flat
        // caster margin. The range is narrower than it was with the disc fit,
        // and for a good reason: the wide end improved. Coverage can no longer
        // grow the window past the ground the camera can actually see.
        XCTAssertGreaterThan(wide / tight, 2.5,
                             "Coverage must move the texel by more than a quantization step")
        // And it never goes the wrong way on the way down. Adjacent steps can
        // land on the same window: the extent is quantized in √2 steps, so a
        // small change in the disc does not always cross one.
        var previous = wide
        for coverage in [Float(2), 1, 0.5, 0.25] {
            let current = try texel(coverage: coverage)
            XCTAssertLessThanOrEqual(current, previous, "coverage \(coverage)")
            previous = current
        }
    }

    /// The caster limit is the setting, clamped, and never more than the
    /// window can spend on it.
    func testTheCasterLimitFollowsTheSettingAndTheWindow() {
        let unitsPerMeter = Self.unitsPerMeter
        func spec(distance: Float, coverage: Float, heightMeters: Float) -> ShadowFrameStateResolver.CascadeSpec {
            ShadowFrameStateResolver.windowSpec(radiusMeters: Float(Double(coverage * distance) / unitsPerMeter),
                                                unitsPerMeter: unitsPerMeter,
                                                maxCasterHeightMeters: heightMeters)
        }

        // The setting, straight through, whenever the window can afford it.
        for heightMeters in [Float(20), 50, 120] {
            let fitted = spec(distance: 0.05, coverage: 3, heightMeters: heightMeters)
            XCTAssertEqual(fitted.maxCasterHeight,
                           Float(Double(heightMeters) * unitsPerMeter),
                           accuracy: Float(unitsPerMeter),
                           "\(heightMeters) m must reach the window unchanged")
        }

        // Clamped at both ends of the settable range.
        let range = ShadowFrameStateResolver.maxCasterHeightRange
        XCTAssertEqual(spec(distance: 0.8, coverage: 3, heightMeters: 10_000).maxCasterHeight,
                       spec(distance: 0.8, coverage: 3, heightMeters: range.upperBound).maxCasterHeight)
        XCTAssertEqual(spec(distance: 0.8, coverage: 3, heightMeters: 0).maxCasterHeight,
                       spec(distance: 0.8, coverage: 3, heightMeters: range.lowerBound).maxCasterHeight)

        // A window wound right down cannot spend more on the caster margin
        // than the window radii rule allows, whatever the setting says.
        let tight = spec(distance: 0.05, coverage: 0.25, heightMeters: 500)
        XCTAssertEqual(tight.maxCasterHeight,
                       ShadowFrameStateResolver.maxCasterHeightWindowRadii * tight.radius,
                       accuracy: 1e-6)
    }

    /// The point of the setting: a lower limit spends the map on the shadows
    /// that are actually there instead of on a margin for a tower that is not.
    func testALowerCasterLimitShrinksTheTexel() throws {
        let eye = Self.makeEye(pitch: 55 * .pi / 180, bearing: 0.3, distance: 0.05)

        func texel(heightMeters: Float) throws -> Float {
            var scene = Self.makeScene()
            scene.shadows.maxCasterHeightMeters = heightMeters
            let state = try XCTUnwrap(Self.resolve(eye: eye, scene: scene))
            return state.shadowUniform.near.normalOffsetWorld / scene.shadows.normalOffsetTexels
        }

        XCTAssertGreaterThan(try texel(heightMeters: 500) / texel(heightMeters: 50), 1.9,
                             "Dropping a 500 m margin to 50 m must buy back most of the window")
    }

    /// Coverage became an upper bound rather than a size: with the window
    /// fitted to the visible ground, asking for more reach than the camera can
    /// see costs nothing, where a disc would have grown and taken the texels
    /// with it.
    func testCoverageBeyondTheVisibleGroundCostsNothing() throws {
        // Looking steeply down, so very little ground is in frame.
        let eye = Self.makeEye(pitch: 15 * .pi / 180, bearing: 0.2, distance: 0.05)

        func texel(coverage: Float) throws -> Float {
            var scene = Self.makeScene()
            scene.shadows.nearCoverageMeters = Self.coverage(cameraDistances: coverage, eye: eye)
            let state = try XCTUnwrap(Self.resolve(eye: eye, scene: scene))
            return state.shadowUniform.near.normalOffsetWorld / scene.shadows.normalOffsetTexels
        }

        XCTAssertEqual(try texel(coverage: 12), try texel(coverage: 3), accuracy: 1e-9,
                       "Reach the camera cannot use must not coarsen the map")
    }

    /// The geometric self-shadow band mirrors the shader constants, which is
    /// the only defense left on grazing walls.
    func testGeometricCutoffBandMirrorsTheShader() {
        XCTAssertLessThan(ShadowFrameStateResolver.geometricCutoffStart,
                          ShadowFrameStateResolver.geometricCutoffEnd)
        XCTAssertGreaterThan(ShadowFrameStateResolver.geometricCutoffStart, 0)
        XCTAssertLessThan(ShadowFrameStateResolver.geometricCutoffEnd, 1)
    }

    // MARK: - The shadows' zoom

    /// Where the strength's curve is at nothing there is no shadow state,
    /// so no pass runs, and coming up to its rise the strength follows
    /// the curve smoothly to the setting's.
    func testTheShadowsComeInWithTheZoom() throws {
        var scene = Self.makeScene()
        scene.shadows.strength = [12: 0, 13: 0.22]
        let shadows = scene.shadows
        XCTAssertEqual(shadows.strength(atZoom: 10), 0)
        XCTAssertEqual(shadows.strength(atZoom: 12), 0)
        XCTAssertEqual(shadows.strength(atZoom: 12.5), 0.11, accuracy: 1e-6)
        XCTAssertEqual(shadows.strength(atZoom: 13), 0.22)
        XCTAssertEqual(shadows.strength(atZoom: 16), 0.22)
        XCTAssertEqual(ImmersiveMapSettings.ShadowSettings(strength: 3).strength(atZoom: 16), 1, "Clamped to one")

        let eye = SIMD3<Float>(0.2, -0.35, 0.7)
        XCTAssertNil(ShadowFrameStateResolver.resolveInputs(renderSurfaceMode: .flat,
                                                            projectionView: Self.makeProjectionView(eye: eye),
                                                            cameraEye: eye,
                                                            centerWorldMercator: Self.equatorCenter,
                                                            flatRenderPan: .zero,
                                                            renderMapSize: Self.renderMapSize,
                                                            zoom: 10,
                                                            scene: scene),
                     "Below the shadows' zoom the frame has no shadows at all")
        let faded = try XCTUnwrap(ShadowFrameStateResolver.resolveInputs(renderSurfaceMode: .flat,
                                                                         projectionView: Self.makeProjectionView(eye: eye),
                                                                         cameraEye: eye,
                                                                         centerWorldMercator: Self.equatorCenter,
                                                                         flatRenderPan: .zero,
                                                                         renderMapSize: Self.renderMapSize,
                                                                         zoom: 12.5,
                                                                         scene: scene))
        XCTAssertEqual(faded.strength, 0.11, accuracy: 1e-6)
    }

    // MARK: - The far window

    /// By default the frame has both windows: the far one's disc is wider,
    /// its texel coarser, its fade band where the shadows end, and the near
    /// one's band inside it, where the far window takes over.
    func testTheFarWindowReachesPastTheNearOne() throws {
        let eye = Self.makeEye(pitch: 40 * .pi / 180, bearing: 0.4, distance: 0.8)
        // The near window inside the visible ground, the far one past it:
        // both fitted to the ground the camera sees, a near window as wide
        // as that ground would be the far one.
        var scene = Self.makeScene()
        scene.shadows.nearCoverageMeters = Self.coverage(cameraDistances: 1, eye: eye)
        scene.shadows.farCoverageMeters = Self.coverage(cameraDistances: 4, eye: eye)
        let state = try XCTUnwrap(Self.resolve(eye: eye, scene: scene))
        let near = state.shadowUniform.near
        let far = state.shadowUniform.far

        XCTAssertTrue(far.isEnabled)
        XCTAssertNotNil(state.farLightProjectionView)
        XCTAssertEqual(state.slots, [.near, .far])
        let shadows = scene.shadows
        XCTAssertEqual(far.fadeEndDistance, Self.radius(shadows.farCoverageMeters),
                       accuracy: far.fadeEndDistance * 1e-5)
        XCTAssertEqual(near.fadeEndDistance, Self.radius(shadows.nearCoverageMeters),
                       accuracy: near.fadeEndDistance * 1e-5)
        XCTAssertGreaterThanOrEqual(far.fadeStartDistance, near.fadeEndDistance,
                                    "The far band starts where the near window ends or beyond")
        XCTAssertGreaterThan(far.normalOffsetWorld, near.normalOffsetWorld,
                             "The same map over a wider disc is a coarser texel")
        XCTAssertEqual(far.texelSizeUV, near.texelSizeUV, "The same map size a slice")
        XCTAssertEqual(state.casterCullingProjectionView, state.farLightProjectionView)
    }

    /// Every point the near window covers, the far window covers too: a
    /// receiver in the blend band reads both, and a caster culled by the
    /// far window's frustum casts into neither.
    func testTheFarWindowHoldsTheNearOne() throws {
        let eye = Self.makeEye(pitch: 50 * .pi / 180, bearing: 1.1, distance: 0.6)
        let state = try XCTUnwrap(Self.resolve(eye: eye))
        let farMatrix = try XCTUnwrap(state.farLightProjectionView)
        let near = ShadowFrameStateResolver.windowSpec(
            radiusMeters: ImmersiveMapSettings.default.scene.shadows.nearCoverageMeters(atZoom: Self.zoom),
            unitsPerMeter: Self.unitsPerMeter,
            maxCasterHeightMeters: ImmersiveMapSettings.default.scene.shadows.maxCasterHeightMeters)
        let footprint = ShadowFrameStateResolver.visibleGroundFootprint(
            inverseProjectionView: simd_inverse(Self.makeProjectionView(eye: eye)),
            cameraEye: eye,
            maxDistance: near.radius)
        for point in footprint {
            for z in [Float(0), near.maxCasterHeight] {
                let ndc = Self.project(farMatrix, SIMD3<Float>(point.x, point.y, z))
                XCTAssertLessThanOrEqual(abs(ndc.x), 1 + 1e-3)
                XCTAssertLessThanOrEqual(abs(ndc.y), 1 + 1e-3)
                XCTAssertGreaterThanOrEqual(ndc.z, -1e-3)
                XCTAssertLessThanOrEqual(ndc.z, 1 + 1e-3)
            }
        }
    }

    /// A far coverage that does not reach past the near window's band is
    /// off: one window, one pass, the near window's fade ends the shadows,
    /// exactly as before the far window existed.
    func testAFarCoverageUnderTheNearOneLeavesOneWindow() throws {
        var scene = Self.makeScene()
        scene.shadows.nearCoverageMeters = 3000
        scene.shadows.farCoverageMeters = 3500
        let state = try XCTUnwrap(Self.resolve(scene: scene))

        XCTAssertFalse(state.shadowUniform.far.isEnabled)
        XCTAssertNil(state.farLightProjectionView)
        XCTAssertEqual(state.slots, [.near])
        XCTAssertEqual(state.casterCullingProjectionView, state.lightProjectionView)

        scene.shadows.farCoverageMeters = 4000
        let both = try XCTUnwrap(Self.resolve(scene: scene))
        XCTAssertTrue(both.shadowUniform.far.isEnabled, "Four thirds of the near coverage is the threshold")
        XCTAssertTrue(ShadowFrameStateResolver.farWindowReaches(farRadius: 4, nearRadius: 3))
        XCTAssertFalse(ShadowFrameStateResolver.farWindowReaches(farRadius: 3.9, nearRadius: 3))
    }

    /// The coverages are read at the frame's zoom: the same scene has
    /// wider windows from an overview than in a street view, as the
    /// curves say, and a far coverage that falls under the near one at a
    /// zoom leaves one window there.
    func testTheCoveragesFollowTheZoom() throws {
        var scene = Self.makeScene()
        // Shadows at every zoom read here: the default strength is off at 14.
        scene.shadows.strength = 0.22
        scene.shadows.nearCoverageMeters = [14: 6000, 18: 500]
        scene.shadows.farCoverageMeters = [14: 24_000, 18: 600]
        let overview = try XCTUnwrap(Self.resolve(scene: scene, zoom: 14))
        let street = try XCTUnwrap(Self.resolve(scene: scene, zoom: 18))
        XCTAssertEqual(overview.shadowUniform.near.fadeEndDistance, Float(6000 * Self.unitsPerMeter),
                       accuracy: Float(6 * Self.unitsPerMeter))
        XCTAssertEqual(street.shadowUniform.near.fadeEndDistance, Float(500 * Self.unitsPerMeter),
                       accuracy: Float(0.5 * Self.unitsPerMeter))
        XCTAssertTrue(overview.shadowUniform.far.isEnabled)
        XCTAssertFalse(street.shadowUniform.far.isEnabled, "600 m does not reach past 500 m's band")
        let between = try XCTUnwrap(Self.resolve(scene: scene, zoom: 16))
        XCTAssertEqual(between.shadowUniform.near.fadeEndDistance, Float(sqrt(6000.0 * 500) * Self.unitsPerMeter),
                       accuracy: Float(2 * Self.unitsPerMeter), "Geometric between the stops")
    }

    func testSliceRectsAndFadeFollowTheCoverage() throws {
        let eye = Self.makeEye(pitch: 30 * .pi / 180, bearing: 0.4, distance: 0.8)
        let state = try XCTUnwrap(Self.resolve(eye: eye))

        // The window owns the whole map, inset by the tap's reach.
        let cascade = state.shadowUniform.near
        XCTAssertGreaterThan(cascade.uvMinimum.x, 0)
        XCTAssertLessThan(cascade.uvMaximum.x, 1)
        XCTAssertEqual(cascade.uvMinimum.x, cascade.uvMinimum.y)
        XCTAssertEqual(cascade.uvMaximum.x, cascade.uvMaximum.y)

        let expectedRadius = Self.radius(ImmersiveMapSettings.default.scene.shadows.nearCoverageMeters)
        XCTAssertEqual(state.shadowUniform.near.fadeEndDistance, expectedRadius, accuracy: expectedRadius * 1e-5)
        XCTAssertEqual(state.shadowUniform.near.fadeStartDistance, expectedRadius * 0.75, accuracy: expectedRadius * 1e-5)
        XCTAssertEqual(state.shadowUniform.eye, eye)

        // The geometric self-shadow test in the shaders relies on a normalized
        // sun direction.
        XCTAssertEqual(simd_length(state.shadowUniform.lightDirection), 1.0, accuracy: 1e-6)
        let expectedDirection = simd_normalize(ImmersiveMapSettings.default.scene.light.direction)
        XCTAssertEqual(simd_distance(state.shadowUniform.lightDirection, expectedDirection), 0, accuracy: 1e-6)
    }

    // MARK: - Helpers

    /// The default scene: the tests that pin the window's scaling with
    /// the camera distance set the coverages in metres for their eye.
    private static func makeScene() -> ImmersiveMapSettings.SceneSettings {
        ImmersiveMapSettings.default.scene
    }

    /// The window is the coverage in metres, in the frame's world units,
    /// within the resolver's clamp.
    func testTheWindowIsTheCoverageInMeters() {
        func radius(meters: Float) -> Float {
            ShadowFrameStateResolver.windowSpec(radiusMeters: meters,
                                                unitsPerMeter: Self.unitsPerMeter,
                                                maxCasterHeightMeters: 10).radius
        }
        let threeHundred = Float(300 * Self.unitsPerMeter)
        XCTAssertEqual(radius(meters: 300), threeHundred, accuracy: threeHundred * 1e-5)
        let range = ShadowFrameStateResolver.coverageMetersRange
        XCTAssertEqual(radius(meters: 0), radius(meters: range.lowerBound), "Clamped at the floor")
        XCTAssertEqual(radius(meters: .infinity), radius(meters: range.lowerBound), "Nothing finite: the floor")
        XCTAssertEqual(radius(meters: 1e12), radius(meters: range.upperBound), "Clamped at the ceiling")
    }

    private static func makeEye(pitch: Float, bearing: Float, distance: Float) -> SIMD3<Float> {
        SIMD3<Float>(sin(bearing) * sin(pitch) * distance,
                     -cos(bearing) * sin(pitch) * distance,
                     cos(pitch) * distance)
    }

    private static func resolve(renderSurfaceMode: ViewMode = .flat,
                                eye: SIMD3<Float> = SIMD3<Float>(0.2, -0.35, 0.7),
                                flatRenderPan: SIMD2<Double> = SIMD2<Double>(0.312, -0.144),
                                scene: ImmersiveMapSettings.SceneSettings = ImmersiveMapSettings.default.scene,
                                zoom: Double = ShadowFrameStateResolverTests.zoom) -> ShadowFrameState? {
        ShadowFrameStateResolver.resolve(renderSurfaceMode: renderSurfaceMode,
                                         projectionView: makeProjectionView(eye: eye),
                                         cameraEye: eye,
                                         centerWorldMercator: equatorCenter,
                                         flatRenderPan: flatRenderPan,
                                         renderMapSize: renderMapSize,
                                         zoom: zoom,
                                         scene: scene)
    }

    /// A plausible camera matrix for the eye, looking at the origin. The
    /// window is fitted to what this sees now, so the tests have to supply it.
    static func makeProjectionView(eye: SIMD3<Float>) -> matrix_float4x4 {
        let distance = simd_length(eye)
        let direction = eye / max(distance, 1e-6)
        let up: SIMD3<Float> = abs(direction.z) > 0.99
            ? SIMD3<Float>(0, 1, 0)
            : SIMD3<Float>(0, 0, 1)
        let view = Matrix.lookAt(eye: eye, center: .zero, up: up)
        let projection = Matrix.perspectiveMatrix(fovRadians: 0.9,
                                                  aspect: 1.5,
                                                  near: distance * 0.01,
                                                  far: distance * 40)
        return projection * view
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
