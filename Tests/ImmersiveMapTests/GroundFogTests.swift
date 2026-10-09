// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The fog on the ground of the flat map as a frame resolves it
/// (`GroundFogUniform`), and its settings.
final class GroundFogTests: XCTestCase {
    private static let eye = SIMD3<Float>(0, -300, 400)

    private func uniform(_ settings: ImmersiveMapSettings, surface: ViewMode = .flat) -> GroundFogUniform {
        GroundFogUniform.resolve(settings: settings, renderSurfaceMode: surface, cameraEye: Self.eye)
    }

    func testTheFogIsOffByDefaultAndOnTheGlobe() {
        let base = FixtureTiles.tilelessSettings()
        XCTAssertFalse(base.scene.groundFog.isEnabled)
        XCTAssertEqual(uniform(base).parameters.w, 0, "off by default")
        let on = base.groundFog()
        XCTAssertEqual(uniform(on).parameters.w, 1, "on, on the plane")
        XCTAssertEqual(uniform(on, surface: .spherical).parameters.w, 0, "the globe has no fog")
    }

    /// The lengths are camera distances: the uniform carries the eye and
    /// one over its distance from the point the camera looks at, the
    /// render world's origin.
    func testTheUniformCarriesTheCameraDistance() {
        let fogged = uniform(FixtureTiles.tilelessSettings().groundFog(density: 0.5, height: 0.2, startDistance: 3,
                                                                       maximumOpacity: 0.8))
        XCTAssertEqual(fogged.eyeAndInverseDistance.w, 1 / 500, accuracy: 1e-7)
        XCTAssertEqual(SIMD3(fogged.eyeAndInverseDistance.x, fogged.eyeAndInverseDistance.y, fogged.eyeAndInverseDistance.z),
                       Self.eye)
        XCTAssertEqual(fogged.colorAndDensity.w, 0.5)
        XCTAssertEqual(fogged.parameters, SIMD4<Float>(0.2, 3, 0.8, 1))
    }

    /// The fog takes the horizon's colour unless it states its own.
    func testTheColourIsTheHorizonsByDefault() {
        var settings = FixtureTiles.tilelessSettings().groundFog()
        settings.scene.fog.horizonColor = SIMD3(0.1, 0.2, 0.3)
        let horizon = uniform(settings).colorAndDensity
        XCTAssertEqual(SIMD3(horizon.x, horizon.y, horizon.z), SIMD3(0.1, 0.2, 0.3))
        let own = uniform(settings.groundFog(color: SIMD3(0.9, 0.8, 0.7))).colorAndDensity
        XCTAssertEqual(SIMD3(own.x, own.y, own.z), SIMD3(0.9, 0.8, 0.7))
    }

    func testTheModifierLeavesTheOtherValuesAsConfigured() {
        let base = FixtureTiles.tilelessSettings()
        let changed = base.groundFog(density: 1.2)
        XCTAssertTrue(changed.scene.groundFog.isEnabled)
        XCTAssertEqual(changed.scene.groundFog.density, 1.2)
        XCTAssertEqual(changed.scene.groundFog.height, base.scene.groundFog.height)
        XCTAssertEqual(changed.scene.groundFog.startDistance, base.scene.groundFog.startDistance)
        XCTAssertFalse(changed.groundFog(isEnabled: false).scene.groundFog.isEnabled)
    }

    func testAChangeAppliesLive() {
        let old = FixtureTiles.tilelessSettings()
        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: old, to: old.groundFog(height: 0.4))
        XCTAssertEqual(plan.actions, [.liveApply])
    }

    /// Every fogged shader reads the fog from the slot the uniform binds.
    func testTheShadersReadTheFogFromItsSlot() throws {
        XCTAssertEqual(MemoryLayout<GroundFogUniform>.stride, 48)
        let header = try String(contentsOf: Self.sourcesURL.appendingPathComponent("Render/Shaders/Shared/GroundFog.h"),
                                encoding: .utf8)
        XCTAssertTrue(header.contains("#define kGroundFogBufferIndex \(GroundFogUniform.bufferIndex)"))
        for shader in ["Tile/Shaders/Tile.metal", "Tile/Shaders/TileExtruded.metal", "Tile/Shaders/TileRaster.metal",
                       "SceneModels/Shaders/SceneModel.metal", "SceneModels/Shaders/ModelTile.metal",
                       "Labels/Shaders/Surface/SurfaceLabel.metal"] {
            let source = try String(contentsOf: Self.sourcesURL.appendingPathComponent(shader), encoding: .utf8)
            XCTAssertTrue(source.contains("[[buffer(kGroundFogBufferIndex)]]"), shader)
            XCTAssertTrue(source.contains("applyGroundFog("), shader)
        }
    }

    private static var sourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ImmersiveMap")
    }
}
