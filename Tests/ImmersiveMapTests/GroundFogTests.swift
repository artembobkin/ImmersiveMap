// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The fog on the ground of the flat map as a frame resolves it
/// (`GroundFogUniform`), its settings and their zoom curves.
final class GroundFogTests: XCTestCase {
    private static let eye = SIMD3<Float>(0, -3, 4)
    /// One render unit is 100 m.
    private static let worldUnitsPerMeter = 0.01

    private func uniform(_ settings: ImmersiveMapSettings,
                         surface: ViewMode = .flat,
                         zoom: Double = 16) -> GroundFogUniform {
        GroundFogUniform.resolve(settings: settings,
                                 renderSurfaceMode: surface,
                                 cameraEye: Self.eye,
                                 worldUnitsPerMeter: Self.worldUnitsPerMeter,
                                 zoom: zoom)
    }

    func testTheFogIsOnByDefaultAndOffTheGlobe() {
        let base = FixtureTiles.tilelessSettings()
        XCTAssertTrue(base.scene.groundFog.isEnabled)
        XCTAssertEqual(uniform(base).parameters.w, 1, "on, on the plane")
        XCTAssertEqual(uniform(base, surface: .spherical).parameters.w, 0, "the globe has no fog")
        XCTAssertEqual(uniform(base.groundFog(isEnabled: false)).parameters.w, 0, "off")
    }

    /// The lengths are meters: the uniform carries the eye in render units
    /// and the meters one unit spans, and the density per meter.
    func testTheUniformCarriesMeters() {
        let fogged = uniform(FixtureTiles.tilelessSettings().groundFog(densityPerKilometer: 2,
                                                                       heightMeters: 50,
                                                                       startDistanceMeters: 300,
                                                                       startSoftnessMeters: 700,
                                                                       maximumOpacity: 0.8))
        XCTAssertEqual(fogged.eyeAndMetersPerUnit.w, 100, accuracy: 1e-4)
        XCTAssertEqual(SIMD3(fogged.eyeAndMetersPerUnit.x, fogged.eyeAndMetersPerUnit.y, fogged.eyeAndMetersPerUnit.z),
                       Self.eye)
        XCTAssertEqual(fogged.colorAndDensity.w, 0.002, accuracy: 1e-9)
        XCTAssertEqual(fogged.parameters, SIMD4<Float>(50, 300, 0.8, 1))
        XCTAssertEqual(fogged.startSoftness.x, 700)
    }

    /// Every value is read off its curve at the frame's camera zoom: the
    /// lengths and the density geometrically, the same ratio per zoom, the
    /// opacity on a smoothstep.
    func testTheValuesFollowTheZoom() {
        let settings = FixtureTiles.tilelessSettings().groundFog(densityPerKilometer: [12: 0.1, 16: 1.6],
                                                                 heightMeters: [12: 2000, 16: 125],
                                                                 startDistanceMeters: [12: 3200, 16: 200],
                                                                 maximumOpacity: [12: 0.5, 16: 1])
        let low = uniform(settings, zoom: 10)
        XCTAssertEqual(low.colorAndDensity.w, 0.0001, accuracy: 1e-9)
        XCTAssertEqual(low.parameters, SIMD4<Float>(2000, 3200, 0.5, 1))
        let high = uniform(settings, zoom: 18)
        XCTAssertEqual(high.parameters, SIMD4<Float>(125, 200, 1, 1))
        let middle = uniform(settings, zoom: 14)
        XCTAssertEqual(middle.colorAndDensity.w, 0.0004, accuracy: 1e-8, "Halfway in zoom, halfway in ratio")
        XCTAssertEqual(middle.parameters.x, 500, accuracy: 1e-2)
        XCTAssertEqual(middle.parameters.y, 800, accuracy: 1e-2)
        XCTAssertEqual(middle.parameters.z, 0.75, accuracy: 1e-6)
    }

    /// A fog brought in by its opacity is nothing where the opacity is 0.
    func testAZeroOpacityIsNoFog() {
        let settings = FixtureTiles.tilelessSettings().groundFog(maximumOpacity: [14: 0, 15: 1])
        XCTAssertEqual(uniform(settings, zoom: 13).parameters.w, 0)
        XCTAssertEqual(uniform(settings, zoom: 15).parameters.w, 1)
    }

    /// The sphere draws no fog, so on a map with the globe the plane brings
    /// it in over a tenth of the transition span past the morph's end
    /// rather than at its first frame.
    func testTheFogComesInPastTheGlobesMorph() {
        let presentation = ImmersiveMapSettings.default.presentation
        let planeZoom = presentation.automaticTransitionStartZoom + presentation.automaticTransitionSpan
        let width = presentation.automaticTransitionSpan * GroundFogUniform.morphFadeSpanShare
        XCTAssertEqual(GroundFogUniform.morphFade(presentation: presentation, zoom: planeZoom), 0)
        XCTAssertEqual(GroundFogUniform.morphFade(presentation: presentation, zoom: planeZoom + width / 2), 0.5,
                       accuracy: 1e-6)
        XCTAssertEqual(GroundFogUniform.morphFade(presentation: presentation, zoom: planeZoom + width), 1)
        var flatOnly = presentation
        flatOnly.isGlobeEnabled = false
        XCTAssertEqual(GroundFogUniform.morphFade(presentation: flatOnly, zoom: 0), 1, "No globe, no morph to wait for")
        XCTAssertEqual(uniform(FixtureTiles.tilelessSettings(), zoom: planeZoom).parameters.w, 0)
    }

    /// Above the line the fog takes the sky's colour in the direction of
    /// the view, as the horizon paints it, so a building veiled in full is
    /// the sky behind it. With the sky off it keeps its own colour.
    func testAboveTheLineTheFogIsTheSky() {
        let settings = FixtureTiles.tilelessSettings()
        let fog = uniform(settings)
        let horizon = settings.scene.fog.horizonColor
        let sky = settings.scene.fog.skyColor
        XCTAssertEqual(fog.skyColorAndGradient.w, HorizonFrameResolver.skyGradientRadians)
        XCTAssertEqual(fog.color(elevation: -0.1), horizon, "Under the line: the fog's own colour")
        XCTAssertEqual(fog.color(elevation: 0), horizon, "At the line: the horizon's colour")
        let high = fog.color(elevation: .pi / 4)
        XCTAssertEqual(high.x, sky.x, accuracy: 1e-3, "Far above the line: the sky colour")
        XCTAssertEqual(high.z, sky.z, accuracy: 1e-3)
        let skyOff = uniform(settings.fog(isEnabled: false))
        XCTAssertEqual(skyOff.color(elevation: .pi / 4), horizon, "No sky painted: the fog keeps its colour")
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
        let changed = base.groundFog(densityPerKilometer: 1.2)
        XCTAssertTrue(changed.scene.groundFog.isEnabled)
        XCTAssertEqual(changed.scene.groundFog.densityPerKilometer, 1.2)
        XCTAssertEqual(changed.scene.groundFog.heightMeters, base.scene.groundFog.heightMeters)
        XCTAssertEqual(changed.scene.groundFog.startDistanceMeters, base.scene.groundFog.startDistanceMeters)
        XCTAssertFalse(changed.groundFog(isEnabled: false).scene.groundFog.isEnabled)
    }

    /// The buildings and the models draw clear of the fog unless asked.
    func testTheBuildingsStandClearByDefault() {
        let base = FixtureTiles.tilelessSettings()
        XCTAssertFalse(base.scene.groundFog.veilsBuildings)
        XCTAssertTrue(base.groundFog(veilsBuildings: true).scene.groundFog.veilsBuildings)
        XCTAssertTrue(base.groundFog(veilsBuildings: true).groundFog(densityPerKilometer: 2).scene.groundFog.veilsBuildings,
                      "An omitted value is left as configured")
    }

    func testAChangeAppliesLive() {
        let old = FixtureTiles.tilelessSettings()
        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: old, to: old.groundFog(heightMeters: 40))
        XCTAssertEqual(plan.actions, [.liveApply])
    }

    /// Every fogged shader reads the fog from the slot the uniform binds.
    func testTheShadersReadTheFogFromItsSlot() throws {
        XCTAssertEqual(MemoryLayout<GroundFogUniform>.stride, 80)
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

/// A value over the camera zoom (`ImmersiveMapZoomCurve`).
final class ImmersiveMapZoomCurveTests: XCTestCase {
    func testASingleValueIsTheSameAtEveryZoom() {
        let curve: ImmersiveMapZoomCurve = 0.3
        XCTAssertEqual(curve.value(atZoom: 0), 0.3)
        XCTAssertEqual(curve.value(atZoom: 22), 0.3)
        XCTAssertEqual(curve.constantValue, 0.3)
    }

    /// The ends hold past the first and the last stop, and between two
    /// stops the value eases in and out on a smoothstep.
    func testStopsBlendSmoothly() {
        let curve: ImmersiveMapZoomCurve = [16: 1, 12: 0]
        XCTAssertEqual(curve.stops.map(\.zoom), [12, 16], "The stops are kept in increasing zoom")
        XCTAssertNil(curve.constantValue)
        XCTAssertEqual(curve.value(atZoom: 10), 0)
        XCTAssertEqual(curve.value(atZoom: 12), 0)
        XCTAssertEqual(curve.value(atZoom: 14), 0.5, accuracy: 1e-6)
        XCTAssertEqual(curve.value(atZoom: 13), 0.15625, accuracy: 1e-6, "A smoothstep, not a line")
        XCTAssertEqual(curve.value(atZoom: 16), 1)
        XCTAssertEqual(curve.value(atZoom: 20), 1)
    }

    func testEachSegmentBlendsBetweenItsOwnStops() {
        let curve: ImmersiveMapZoomCurve = [13: 4, 14: 1, 15: 0.15]
        XCTAssertEqual(curve.value(atZoom: 13.5), 2.5, accuracy: 1e-6)
        XCTAssertEqual(curve.value(atZoom: 14), 1)
        XCTAssertEqual(curve.value(atZoom: 14.5), 0.575, accuracy: 1e-6)
    }

    /// Geometrically the value changes by the same ratio for every step of
    /// zoom, the way the map's scale does, and a stop not above zero falls
    /// back to the smoothstep.
    func testGeometricStopsKeepARatioPerZoom() {
        let curve: ImmersiveMapZoomCurve = [12: 3200, 16: 200]
        XCTAssertEqual(curve.value(atZoom: 13, interpolation: .geometric), 1600, accuracy: 0.01)
        XCTAssertEqual(curve.value(atZoom: 14, interpolation: .geometric), 800, accuracy: 0.01)
        XCTAssertEqual(curve.value(atZoom: 15, interpolation: .geometric), 400, accuracy: 0.01)
        let withZero: ImmersiveMapZoomCurve = [12: 0, 16: 1]
        XCTAssertEqual(withZero.value(atZoom: 14, interpolation: .geometric), 0.5, accuracy: 1e-6)
    }
}
