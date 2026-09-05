// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import simd
import XCTest

/// The shadow-map reuse contract: the sun is static and the buildings do not
/// move, so the rendered cascade atlas is re-rendered only when something it
/// depends on actually changed. The controller decides that from the fitted
/// windows (camera travel inside the margin reuses), the light, the map
/// resolution and texture identity, the caster tile set (a new tile
/// invalidates, a departed one does not), and the presence of animating
/// model casters.
final class ShadowMapReuseControllerTests: XCTestCase {
    private static let equatorCenter = SIMD2<Double>(0.5, 0.5)
    private static let renderMapSize = 2.0 * Double.pi * 0.14 * pow(2.0, 16)
    private static let basePan = SIMD2<Double>(0.312, -0.144)
    private static let baseEye = SIMD3<Float>(0.2, -0.35, 0.7)

    private final class DummyCaster {}

    private func resolve(_ controller: ShadowMapReuseController,
                         eye: SIMD3<Float> = baseEye,
                         pan: SIMD2<Double> = basePan,
                         scene: ImmersiveMapSettings.SceneSettings = ImmersiveMapSettings.default.scene) -> ShadowFrameState? {
        controller.resolveFrameState(renderSurfaceMode: .flat,
                                     cameraEye: eye,
                                     centerWorldMercator: Self.equatorCenter,
                                     flatRenderPan: pan,
                                     renderMapSize: Self.renderMapSize,
                                     scene: scene)
    }

    private func makeTexture() throws -> MTLTexture {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth16Unorm,
                                                                  width: 4,
                                                                  height: 4,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func makeKeys(_ objects: [AnyObject]) -> Set<ShadowMapReuseController.CasterKey> {
        Set(objects.map { ShadowMapReuseController.CasterKey(tile: ObjectIdentifier($0), loop: 0) })
    }

    func testHoldRendersOnceAndThenReuses() throws {
        let controller = ShadowMapReuseController()
        let texture = try makeTexture()
        let caster = DummyCaster()
        let keys = makeKeys([caster])

        let first = try XCTUnwrap(resolve(controller))
        XCTAssertTrue(controller.planShadowRender(casterKeys: keys, hasModelCasters: false, texture: texture))

        let second = try XCTUnwrap(resolve(controller))
        XCTAssertFalse(controller.planShadowRender(casterKeys: keys, hasModelCasters: false, texture: texture),
                       "Nothing changed: the rendered map must be reused")
        XCTAssertEqual(first.lightProjectionView, second.lightProjectionView,
                       "A static camera materializes an identical light matrix")
    }

    func testSmallPanReusesAndKeepsContentGlued() throws {
        let controller = ShadowMapReuseController()
        let texture = try makeTexture()
        let keys = makeKeys([DummyCaster()])
        let pan2 = Self.basePan + SIMD2<Double>(3.7e-7, -2.2e-7)

        let state1 = try XCTUnwrap(resolve(controller, pan: Self.basePan))
        XCTAssertTrue(controller.planShadowRender(casterKeys: keys, hasModelCasters: false, texture: texture))
        let state2 = try XCTUnwrap(resolve(controller, pan: pan2))
        XCTAssertFalse(controller.planShadowRender(casterKeys: keys, hasModelCasters: false, texture: texture),
                       "A pan inside the fitted margin must reuse the rendered map")

        // The same piece of map content must read back from the same texels
        // of the reused atlas: shift a probe by exactly the content shift
        // the pan produced and require identical UVs (not merely
        // whole-texel-aligned, as a refit would give).
        let halfMapSize = Self.renderMapSize * 0.5
        let contentShift = SIMD2<Double>((pan2.x - Self.basePan.x) * halfMapSize,
                                         -(pan2.y - Self.basePan.y) * halfMapSize)
        let probe = SIMD3<Float>(0.05, -0.1, 0)
        let shifted = SIMD3<Float>(probe.x + Float(contentShift.x),
                                   probe.y + Float(contentShift.y),
                                   probe.z)
        do {
            let uv1 = projectUV(state1.shadowUniform.cascade.worldToShadowTexture, probe)
            let uv2 = projectUV(state2.shadowUniform.cascade.worldToShadowTexture, shifted)
            XCTAssertEqual(uv1.x, uv2.x, accuracy: 1e-5)
            XCTAssertEqual(uv1.y, uv2.y, accuracy: 1e-5)
        }
    }

    func testPanBeyondTheMarginRefits() throws {
        let controller = ShadowMapReuseController()
        let texture = try makeTexture()
        let keys = makeKeys([DummyCaster()])

        XCTAssertNotNil(resolve(controller, pan: Self.basePan))
        XCTAssertTrue(controller.planShadowRender(casterKeys: keys, hasModelCasters: false, texture: texture))
        // ~0.6 world units of travel against a ~0.08-unit margin budget.
        let farPan = Self.basePan + SIMD2<Double>(2e-5, 0)
        XCTAssertNotNil(resolve(controller, pan: farPan))
        XCTAssertTrue(controller.planShadowRender(casterKeys: keys, hasModelCasters: false, texture: texture),
                      "Travel beyond the fitted margin must refit and re-render")
    }

    func testStrongZoomInRefitsForSharpness() throws {
        let controller = ShadowMapReuseController()
        let texture = try makeTexture()
        let keys = makeKeys([DummyCaster()])

        XCTAssertNotNil(resolve(controller, eye: Self.baseEye))
        XCTAssertTrue(controller.planShadowRender(casterKeys: keys, hasModelCasters: false, texture: texture))
        // Halving the camera distance halves the needed windows: the cached
        // fit still contains them, but its texels are now twice too coarse.
        XCTAssertNotNil(resolve(controller, eye: Self.baseEye * 0.5))
        XCTAssertTrue(controller.planShadowRender(casterKeys: keys, hasModelCasters: false, texture: texture),
                      "A large zoom-in must refit: the cached texels are visibly too coarse")
    }

    func testSlightZoomOutReuses() throws {
        let controller = ShadowMapReuseController()
        let texture = try makeTexture()
        let keys = makeKeys([DummyCaster()])

        XCTAssertNotNil(resolve(controller, eye: Self.baseEye))
        XCTAssertTrue(controller.planShadowRender(casterKeys: keys, hasModelCasters: false, texture: texture))
        XCTAssertNotNil(resolve(controller, eye: Self.baseEye * 1.03))
        XCTAssertFalse(controller.planShadowRender(casterKeys: keys, hasModelCasters: false, texture: texture),
                       "A slight zoom-out stays inside the fitted margin")
    }

    func testLightChangeRefits() throws {
        let controller = ShadowMapReuseController()
        let texture = try makeTexture()
        let keys = makeKeys([DummyCaster()])

        XCTAssertNotNil(resolve(controller))
        XCTAssertTrue(controller.planShadowRender(casterKeys: keys, hasModelCasters: false, texture: texture))
        var scene = ImmersiveMapSettings.default.scene
        scene.light.direction = simd_normalize(SIMD3<Float>(0.5, 0.2, 0.8))
        XCTAssertNotNil(resolve(controller, scene: scene))
        XCTAssertTrue(controller.planShadowRender(casterKeys: keys, hasModelCasters: false, texture: texture),
                      "A different sun renders a different map")
    }

    func testCasterSetRules() throws {
        let controller = ShadowMapReuseController()
        let texture = try makeTexture()
        let stayingCaster = DummyCaster()
        let departingCaster = DummyCaster()
        let arrivingCaster = DummyCaster()

        XCTAssertNotNil(resolve(controller))
        XCTAssertTrue(controller.planShadowRender(casterKeys: makeKeys([stayingCaster, departingCaster]),
                                                  hasModelCasters: false,
                                                  texture: texture))
        XCTAssertNotNil(resolve(controller))
        XCTAssertFalse(controller.planShadowRender(casterKeys: makeKeys([stayingCaster]),
                                                   hasModelCasters: false,
                                                   texture: texture),
                       "A departed caster leaves a correct baked image behind")
        XCTAssertNotNil(resolve(controller))
        XCTAssertTrue(controller.planShadowRender(casterKeys: makeKeys([stayingCaster, arrivingCaster]),
                                                  hasModelCasters: false,
                                                  texture: texture),
                      "A caster tile the map has never seen must be rendered in")
    }

    func testModelCastersAlwaysRender() throws {
        let controller = ShadowMapReuseController()
        let texture = try makeTexture()
        let keys = makeKeys([DummyCaster()])

        XCTAssertNotNil(resolve(controller))
        XCTAssertTrue(controller.planShadowRender(casterKeys: keys, hasModelCasters: true, texture: texture))
        XCTAssertNotNil(resolve(controller))
        XCTAssertTrue(controller.planShadowRender(casterKeys: keys, hasModelCasters: true, texture: texture),
                      "Scene models animate: their casters re-render every frame")
    }

    func testTextureIdentityChangeForcesRender() throws {
        let controller = ShadowMapReuseController()
        let texture = try makeTexture()
        let replacement = try makeTexture()
        let keys = makeKeys([DummyCaster()])

        XCTAssertNotNil(resolve(controller))
        XCTAssertTrue(controller.planShadowRender(casterKeys: keys, hasModelCasters: false, texture: texture))
        XCTAssertNotNil(resolve(controller))
        XCTAssertTrue(controller.planShadowRender(casterKeys: keys, hasModelCasters: false, texture: replacement),
                      "A recreated (blank) atlas texture must be rendered before use")
    }

    private func projectUV(_ matrix: matrix_float4x4, _ point: SIMD3<Float>) -> SIMD2<Float> {
        let projected = matrix * SIMD4<Float>(point.x, point.y, point.z, 1)
        return SIMD2<Float>(projected.x / projected.w, projected.y / projected.w)
    }
}
