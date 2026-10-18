// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The sun on the globe: its settings, and the light a frame shades with.
final class GlobeLightTests: XCTestCase {
    func testTheDefaults() {
        let light = ImmersiveMapSettings.GlobeLightSettings()
        XCTAssertTrue(light.isEnabled)
        XCTAssertEqual(light.subsolarLatitudeDegrees, 10)
        XCTAssertEqual(light.subsolarLongitudeDegrees, -15)
        XCTAssertEqual(light.strength, [4: 0.6, 6: 0.3])
        XCTAssertEqual(light.terminatorSoftness, 0.25)
        XCTAssertEqual(light.nightColor, SIMD3<Float>(0.05, 0.08, 0.18))
        XCTAssertEqual(ImmersiveMapSettings.default.scene.globeLight, light)
        XCTAssertEqual(ImmersiveMapSettings.default.globeLight(strength: 1, nightColor: SIMD3<Float>(0, 0, 0)).scene.globeLight.strength, 1)
        XCTAssertFalse(ImmersiveMapSettings.default.globeLight(isEnabled: false).scene.globeLight.isEnabled)
    }

    /// The resting globe is lit by the normalized scene light at the
    /// curve's strength, the plane and the unrolled globe are not, and the
    /// light off leaves the surface as it is.
    func testTheLightIsTheGlobesAlone() {
        let settings = ImmersiveMapSettings.GlobeLightSettings(strength: [2: 0.8, 6: 0.2])
        let direction = SIMD3<Float>(-0.4, -0.6, 1.0)
        let resting = GlobeLightUniform.resolve(settings: settings, lightDirection: direction,
                                                renderSurfaceMode: .spherical, transition: 0, zoom: 2)
        XCTAssertEqual(resting.lightAndStrength.w, 0.8, accuracy: 1e-6)
        XCTAssertEqual(simd_length(SIMD3(resting.lightAndStrength.x, resting.lightAndStrength.y, resting.lightAndStrength.z)), 1,
                       accuracy: 1e-6)
        XCTAssertEqual(resting.nightColorAndSoftness.w, 0.25)
        let between = GlobeLightUniform.resolve(settings: settings, lightDirection: direction,
                                                renderSurfaceMode: .spherical, transition: 0, zoom: 4)
        XCTAssertEqual(between.lightAndStrength.w, 0.5, accuracy: 1e-6, "Linear between the stops")
        XCTAssertEqual(GlobeLightUniform.resolve(settings: settings, lightDirection: direction,
                                                 renderSurfaceMode: .flat, transition: 1, zoom: 2).lightAndStrength.w, 0,
                       "The plane has the hillshade and the shadows instead")
        XCTAssertEqual(GlobeLightUniform.resolve(settings: settings, lightDirection: direction,
                                                 renderSurfaceMode: .spherical, transition: 1, zoom: 2).lightAndStrength.w, 0,
                       "Unrolled, the globe is the plane")
        var off = settings
        off.isEnabled = false
        XCTAssertEqual(GlobeLightUniform.resolve(settings: off, lightDirection: direction,
                                                 renderSurfaceMode: .spherical, transition: 0, zoom: 2).lightAndStrength.w, 0)
        XCTAssertEqual(GlobeLightUniform.disabled.lightAndStrength.w, 0)
        XCTAssertEqual(MemoryLayout<GlobeLightUniform>.stride, 32, "Mirrors GlobeLight in GlobeLight.h")
    }

    /// The sun stands over its point whichever way the globe is turned:
    /// the world direction of the sun is the world direction of the
    /// planet's normal at the subsolar point, under any pan.
    func testTheSunIsFixedToTheEarth() {
        let settings = ImmersiveMapSettings.GlobeLightSettings(subsolarLatitudeDegrees: 23.4, subsolarLongitudeDegrees: 40)
        let subsolar = GlobeLightUniform.earthDirection(latitudeDegrees: 23.4, longitudeDegrees: 40)
        XCTAssertEqual(simd_length(subsolar), 1, accuracy: 1e-6)
        XCTAssertEqual(GlobeLightUniform.earthDirection(latitudeDegrees: 90, longitudeDegrees: 0).y, 1, accuracy: 1e-6,
                       "y is the pole axis")
        XCTAssertEqual(GlobeLightUniform.earthDirection(latitudeDegrees: 0, longitudeDegrees: 0).z, 1, accuracy: 1e-6,
                       "z toward longitude 0")
        XCTAssertEqual(GlobeLightUniform.earthDirection(latitudeDegrees: 0, longitudeDegrees: 90).x, 1, accuracy: 1e-6,
                       "x toward 90 degrees east")
        for (panX, panY) in [(Float(0), Float(0)), (0.3, -0.2), (-0.8, 0.5)] {
            let globe = GlobeUniform(panX: panX, panY: panY, radius: 0.3, transition: 0)
            let sun = GlobeLightUniform.sunWorldDirection(settings: settings, globe: globe)
            let frame = GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: matrix_identity_float4x4)
            let normalWorld = frame.sphereWorld * SIMD4<Float>(subsolar, 0)
            let normal = simd_normalize(SIMD3<Float>(normalWorld.x, normalWorld.y, normalWorld.z))
            XCTAssertEqual(simd_dot(sun, normal), 1, accuracy: 1e-5, "pan \(panX), \(panY): noon at the subsolar point")
        }
        // Turned a quarter of the way round, the sun has moved in the
        // world by the same quarter: a point under it is still under it.
        let east = GlobeLightUniform.sunWorldDirection(settings: settings, globe: GlobeUniform(panX: 0, panY: 0, radius: 1, transition: 0))
        let turned = GlobeLightUniform.sunWorldDirection(settings: settings, globe: GlobeUniform(panX: 0.5, panY: 0, radius: 1, transition: 0))
        XCTAssertNotEqual(east, turned, "The sun turns with the globe in the world")
    }

    func testThePanelsTitlesAndTab() {
        XCTAssertEqual(DebugOverlayGlobeLightSettingsPlanner.strengthTitle([2: 0.8, 6: 0.2], cameraZoom: 4), "Strength 0.50")
        XCTAssertEqual(DebugOverlayGlobeLightSettingsPlanner.softnessTitle(0.25), "Terminator softness 0.25")
        XCTAssertEqual(DebugOverlayGlobeLightSettingsPlanner.subsolarLatitudeTitle(10), "Sun latitude 10°")
        XCTAssertEqual(DebugOverlayGlobeLightSettingsPlanner.subsolarLongitudeTitle(-15), "Sun longitude -15°")
        XCTAssertTrue(DebugOverlayGlobeLightSettingsPlanner.softnessRange.contains(Double(ImmersiveMapSettings.GlobeLightSettings().terminatorSoftness)))
        XCTAssertEqual(DebugOverlayPanelCategory.globe.title, "Globe")
        var override = DebugOverlaySettingsOverride()
        override.globeLight = ImmersiveMapSettings.GlobeLightSettings(isEnabled: false)
        XCTAssertFalse(override.isEmpty)
        var settings = ImmersiveMapSettings.default
        settings.debug.enableDebugPanel = true
        XCTAssertFalse(override.applied(to: settings).scene.globeLight.isEnabled)
    }
}
