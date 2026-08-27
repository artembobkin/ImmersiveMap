// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// Value-level contract of the globe atmosphere: the setting, its modifiers,
/// how it reaches the pass plan and the per-frame uniforms, and how it is
/// applied to a live map.
final class AtmosphereSettingsTests: XCTestCase {
    func testAtmosphereIsOnByDefault() {
        XCTAssertTrue(ImmersiveMapSettings.default.scene.atmosphere.isEnabled)
        XCTAssertTrue(AtmosphereRenderSubsystem.isAtmosphereEnabled(settings: .default))
    }

    func testAtmosphereModifiersSetTheSettings() {
        XCTAssertFalse(ImmersiveMapSettings.default.atmosphere(isEnabled: false).scene.atmosphere.isEnabled)
        XCTAssertTrue(ImmersiveMapSettings.default.atmosphere(isEnabled: false).atmosphere().scene.atmosphere.isEnabled)

        let custom = ImmersiveMapSettings.AtmosphereSettings(isEnabled: true,
                                                              color: SIMD3<Float>(1, 0.5, 0.2),
                                                              intensity: 1.5,
                                                              thickness: 2,
                                                              sunInfluence: 0)
        XCTAssertEqual(ImmersiveMapSettings.default.atmosphereSettings(custom).scene.atmosphere, custom)
    }

    /// The halo lives in space, so transparent space takes it with the
    /// starfield: nothing outside the globe may be painted in that mode.
    func testTransparentSpaceDropsTheHalo() {
        let settings = ImmersiveMapSettings.default.transparentSpace()
        XCTAssertTrue(settings.scene.atmosphere.isEnabled,
                      "The atmosphere must be on, otherwise this test proves nothing")
        XCTAssertFalse(AtmosphereRenderSubsystem.isAtmosphereEnabled(settings: settings))
    }

    func testAtmosphereOffBySettingDropsTheHalo() {
        XCTAssertFalse(AtmosphereRenderSubsystem.isAtmosphereEnabled(settings: .default.atmosphere(isEnabled: false)))
    }

    /// The atmosphere is a per-frame uniform and a pass-plan flag, so changing
    /// it must not throw away tile caches or the renderer.
    func testAtmosphereChangesApplyLive() {
        var changed = ImmersiveMapSettings.default.atmosphere(isEnabled: false)
        changed.scene.atmosphere.color = SIMD3<Float>(1, 0, 0)
        changed.scene.atmosphere.thickness = 3
        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: .default, to: changed)

        XCTAssertEqual(plan.changedDomains, [.scene])
        XCTAssertEqual(plan.actions, [.liveApply])
        XCTAssertFalse(plan.requiresRendererRecreation)
    }

    // MARK: - Uniforms

    /// Pins the byte layout of the Swift mirror of `Atmosphere` in
    /// Atmosphere.metal: a drifted offset would feed the shader a wrong radius
    /// or eye and the halo would sit off the planet.
    func testAtmosphereUniformMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.stride, 160)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.inverseViewProjection), 0)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.eye), 64)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.center), 80)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.color), 96)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.sunDirection), 112)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.radius), 128)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.transition), 132)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.intensity), 136)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.thickness), 140)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.sunInfluence), 144)
    }

    /// Mirror of `GlobeAtmosphere` in RenderUniforms.h, bound to the globe
    /// surface, its placeholder and the polar caps.
    func testGlobeAtmosphereUniformMatchesMetalLayout() {
        // A Metal float3 is 16 bytes wide, so the scalar after it lands at 16.
        XCTAssertEqual(MemoryLayout<GlobeAtmosphereUniform>.stride, 64)
        XCTAssertEqual(MemoryLayout<GlobeAtmosphereUniform>.offset(of: \.color), 0)
        XCTAssertEqual(MemoryLayout<GlobeAtmosphereUniform>.offset(of: \.intensity), 16)
        XCTAssertEqual(MemoryLayout<GlobeAtmosphereUniform>.offset(of: \.sunDirection), 32)
    }

    /// The surface glow disappears with the atmosphere: off, or at zero
    /// intensity, the sphere carries no glow and the limb is a hard edge.
    func testSurfaceGlowFollowsTheAtmosphereSetting() {
        XCTAssertEqual(GlobeAtmosphereUniform.make(settings: .init()).intensity, 1.0)
        XCTAssertEqual(GlobeAtmosphereUniform.make(settings: .init(isEnabled: false)).intensity, 0)
        XCTAssertEqual(GlobeAtmosphereUniform.make(settings: .init(intensity: 0)).intensity, 0)
        XCTAssertEqual(GlobeAtmosphereUniform.make(settings: .init(intensity: -2)).intensity, 0)
        XCTAssertEqual(GlobeAtmosphereUniform.make(settings: .init(color: SIMD3<Float>(2, -1, 0.5))).color,
                       SIMD3<Float>(1, 0, 0.5))
    }

    /// The surface uniform carries the sun in world space, through the same
    /// rotation the halo uses, so the rim light can tell a sun behind the
    /// planet from one behind the camera; without an earth scene it is zero.
    func testSurfaceUniformCarriesTheWorldSpaceSun() {
        var earthScene = EarthSceneUniform(settings: .init(), now: .distantPast)
        earthScene.sunDirection = SIMD3<Float>(0, 0, 1)
        let globe = GlobeUniform(panX: 0.5, panY: 0, radius: 1, transition: 0)

        let surface = GlobeAtmosphereUniform.make(settings: .init(), earthScene: earthScene, globe: globe)
        let halo = AtmosphereUniform.make(settings: .init(),
                                          earthScene: earthScene,
                                          globe: globe,
                                          projectionView: matrix_identity_float4x4,
                                          cameraEye: .zero)
        XCTAssertEqual(simd_length(surface.sunDirection - halo.sunDirection), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_length(surface.sunDirection), 1, accuracy: 1e-5)
        XCTAssertEqual(GlobeAtmosphereUniform.make(settings: .init()).sunDirection, .zero)
    }

    /// The halo takes the globe's geometry from the frame: the sphere center is
    /// one radius below the flat plane, and the geometry transition drives the
    /// fade through the unfurl.
    func testHaloUniformCarriesTheGlobeGeometry() {
        let globe = GlobeUniform(panX: 0.1, panY: 0.2, radius: 0.28, transition: 0.4)
        let uniform = AtmosphereUniform.make(settings: .init(),
                                             earthScene: .disabled,
                                             globe: globe,
                                             projectionView: matrix_identity_float4x4,
                                             cameraEye: SIMD3<Float>(0, 0, 3))

        XCTAssertEqual(uniform.radius, 0.28)
        XCTAssertEqual(uniform.center, SIMD3<Float>(0, 0, -0.28))
        XCTAssertEqual(uniform.transition, 0.4)
        XCTAssertEqual(uniform.eye, SIMD3<Float>(0, 0, 3))
        XCTAssertEqual(uniform.inverseViewProjection, matrix_identity_float4x4)
    }

    /// The inverse view-projection is the actual inverse: unprojecting a point
    /// the matrix projected gets the point back.
    func testHaloUniformInvertsTheCameraMatrix() {
        let projection = Matrix.perspectiveMatrix(fovRadians: .pi / 4, aspect: 1.5, near: 0.01, far: 200)
        let view = Matrix.lookAt(eye: SIMD3<Float>(0.3, -0.5, 2.0), center: .zero, up: SIMD3<Float>(0, 1, 0))
        let projectionView = projection * view
        let uniform = AtmosphereUniform.make(settings: .init(),
                                             earthScene: .disabled,
                                             globe: GlobeUniform(panX: 0, panY: 0, radius: 0.5, transition: 0),
                                             projectionView: projectionView,
                                             cameraEye: SIMD3<Float>(0.3, -0.5, 2.0))

        let world = SIMD4<Float>(0.2, -0.1, -0.4, 1)
        let clip = projectionView * world
        let back = uniform.inverseViewProjection * clip
        let unprojected = SIMD3<Float>(back.x, back.y, back.z) / back.w
        XCTAssertEqual(unprojected.x, world.x, accuracy: 1e-4)
        XCTAssertEqual(unprojected.y, world.y, accuracy: 1e-4)
        XCTAssertEqual(unprojected.z, world.z, accuracy: 1e-4)
    }

    /// The sun the halo follows is the scene's sun carried into world space by
    /// the globe rotation, so the lit side of the halo is the lit side of the
    /// sphere; with no earth scene, or no sun influence, there is no sun.
    func testHaloSunFollowsTheEarthSceneThroughTheGlobeRotation() {
        let globe = GlobeUniform(panX: 0.35, panY: -0.2, radius: 1, transition: 0)
        let earthScene = EarthSceneUniform(settings: .init(timeMode: .fixed(Date(timeIntervalSince1970: 1_749_000_000))))
        let uniform = AtmosphereUniform.make(settings: .init(),
                                             earthScene: earthScene,
                                             globe: globe,
                                             projectionView: matrix_identity_float4x4,
                                             cameraEye: .zero)

        let rotation = EarthSceneSunVisualState.globeRotationMatrix(globe: globe)
        let expected4 = simd_transpose(rotation) * SIMD4<Float>(simd_normalize(earthScene.sunDirection), 0)
        let expected = simd_normalize(SIMD3<Float>(expected4.x, expected4.y, expected4.z))
        XCTAssertEqual(uniform.sunDirection.x, expected.x, accuracy: 1e-5)
        XCTAssertEqual(uniform.sunDirection.y, expected.y, accuracy: 1e-5)
        XCTAssertEqual(uniform.sunDirection.z, expected.z, accuracy: 1e-5)
        XCTAssertEqual(simd_length(uniform.sunDirection), 1, accuracy: 1e-5)

        let noScene = AtmosphereUniform.make(settings: .init(),
                                             earthScene: .disabled,
                                             globe: globe,
                                             projectionView: matrix_identity_float4x4,
                                             cameraEye: .zero)
        XCTAssertEqual(noScene.sunDirection, .zero)

        let noInfluence = AtmosphereUniform.make(settings: .init(sunInfluence: 0),
                                                 earthScene: earthScene,
                                                 globe: globe,
                                                 projectionView: matrix_identity_float4x4,
                                                 cameraEye: .zero)
        XCTAssertEqual(noInfluence.sunDirection, .zero)
    }

    /// Out-of-range settings arrive at the shader clamped: colors to the unit
    /// range, the multipliers non-negative, the sun influence to `0...1`.
    func testHaloUniformClampsItsSettings() {
        let uniform = AtmosphereUniform.make(settings: .init(color: SIMD3<Float>(3, -1, 0.5),
                                                             intensity: -1,
                                                             thickness: -4,
                                                             sunInfluence: 7),
                                             earthScene: .disabled,
                                             globe: GlobeUniform(panX: 0, panY: 0, radius: 1, transition: 0),
                                             projectionView: matrix_identity_float4x4,
                                             cameraEye: .zero)

        XCTAssertEqual(uniform.color, SIMD3<Float>(1, 0, 0.5))
        XCTAssertEqual(uniform.intensity, 0)
        XCTAssertEqual(uniform.thickness, 0)
        XCTAssertEqual(uniform.sunInfluence, 1)
    }

    /// The halo's day/night asymmetry fades out with the terminator: past
    /// zoom 2 the surface shows no night, and a halo still dimmed on one side
    /// would read as a lopsided ring.
    func testHaloSunInfluenceFadesWithTheTerminator() {
        let settings = ImmersiveMapSettings.AtmosphereSettings(sunInfluence: 0.8)
        let earth = ImmersiveMapSettings.EarthSceneSettings(timeMode: .fixed(Date(timeIntervalSince1970: 1_749_000_000)))
        let globe = GlobeUniform(panX: 0, panY: 0, radius: 1, transition: 0)
        func influence(atZoom zoom: Double) -> Float {
            AtmosphereUniform.make(settings: settings,
                                   earthScene: EarthSceneUniform(settings: earth, zoom: zoom),
                                   globe: globe,
                                   projectionView: matrix_identity_float4x4,
                                   cameraEye: .zero).sunInfluence
        }

        XCTAssertEqual(influence(atZoom: 1.0), 0.8, accuracy: 1e-6)
        let midway = influence(atZoom: 1.5)
        XCTAssertGreaterThan(midway, 0)
        XCTAssertLessThan(midway, 0.8)
        XCTAssertEqual(influence(atZoom: 2.0), 0, accuracy: 1e-6)
        XCTAssertEqual(influence(atZoom: 4.0), 0, accuracy: 1e-6)
    }

    // MARK: - Shaders

    /// The surface glow and the halo are one thing seen from two sides of the
    /// limb: the tiled surface, its placeholder fill and the polar caps all
    /// shade from the same atmosphere uniform, and the halo shader reads the
    /// same tint. A surface path that forgot the uniform would leave a seam
    /// in the glow at the pole or under a still-loading tile.
    func testGlobeSurfacePlaceholderAndCapsShareTheAtmosphereGlow() throws {
        let source = try shaderSource("Render/Shaders/Globe/Globe.metal")

        XCTAssertEqual(source.components(separatedBy: "constant GlobeAtmosphere& atmosphere [[buffer(6)]]").count - 1, 3,
                       "The tiled surface, the placeholder fill and the cap each bind the atmosphere")
        XCTAssertEqual(source.components(separatedBy: "globeAtmosphereSurfaceGlow(facing, atmosphere)").count - 1, 2,
                       "The shared surface shade and the cap both add the glow")
        XCTAssertFalse(source.contains("half3(0.28h, 0.54h, 1.0h)"),
                       "The glow color comes from the atmosphere setting, not from a constant")
    }

    /// The halo fades with the unfurl and follows the sun: both are what the
    /// shader must do with the uniform it is handed.
    func testHaloShaderFadesThroughTheTransitionAndFollowsTheSun() throws {
        let source = try shaderSource("Render/Shaders/Atmosphere/Atmosphere.metal")

        XCTAssertTrue(source.contains("half fade = 1.0h - smoothstep(0.0h, kAtmosphereTransitionFadeEnd, half(atmosphere.transition));"))
        XCTAssertTrue(source.contains("if (atmosphere.sunInfluence > 0.0 && dot(atmosphere.sunDirection, atmosphere.sunDirection) > 0.5)"))
        // Held at zero inside the silhouette so the halo runs under the sphere
        // edge and the limb pixels never get a dark rim.
        XCTAssertTrue(source.contains("float miss = max((perpendicular - radius) / radius, 0.0);"))
    }

    /// Every shadow receiver applies the shadow through the tinted multiplier,
    /// so the ground, the buildings and the scene models take on one shadow
    /// color; a receiver still multiplying by the bare factor would cast a
    /// grey shadow next to a blue one.
    func testEveryShadowReceiverAppliesTheTintedMultiplier() throws {
        let ground = try shaderSource("Render/Tiles/Shaders/Tile.metal")
        let buildings = try shaderSource("Render/Tiles/Shaders/TileExtruded.metal")
        let models = try shaderSource("Render/SceneModels/Shaders/SceneModel.metal")

        XCTAssertTrue(ground.contains("color.rgb *= shadowColorMultiplier(shadow, half(shadowFactor));"))
        XCTAssertTrue(buildings.contains("in.color.rgb * appliedCue * shadowColorMultiplier(shadow, shadowFactor)"))
        XCTAssertTrue(models.contains("base.rgb * shadowColorMultiplier(shadow, shadowFactor)"))
    }

    private func shaderSource(_ relativePath: String) throws -> String {
        let packageRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRootURL.appendingPathComponent("ImmersiveMap").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
