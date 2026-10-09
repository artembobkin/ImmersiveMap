// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The arithmetic behind the debug panel's shadow group. The panel itself is
/// AppKit and cannot be asserted on here; what can be is that the sliders
/// address the sun correctly and that the map-size ladder never hands the
/// settings a value it did not offer.
final class DebugOverlayShadowGroupTests: XCTestCase {
    // MARK: - Sun angles

    func testCardinalDirections() {
        let north = DebugOverlaySunAngles.direction(azimuthDegrees: 0, elevationDegrees: 0)
        XCTAssertEqual(north.x, 0, accuracy: 1e-6)
        XCTAssertEqual(north.y, 1, accuracy: 1e-6)
        XCTAssertEqual(north.z, 0, accuracy: 1e-6)

        let east = DebugOverlaySunAngles.direction(azimuthDegrees: 90, elevationDegrees: 0)
        XCTAssertEqual(east.x, 1, accuracy: 1e-6)
        XCTAssertEqual(east.y, 0, accuracy: 1e-6)

        let overhead = DebugOverlaySunAngles.direction(azimuthDegrees: 123, elevationDegrees: 90)
        XCTAssertEqual(overhead.z, 1, accuracy: 1e-6)
    }

    func testAnglesRoundTripThroughTheDirection() {
        for azimuth in stride(from: 0.0, through: 350.0, by: 17.0) {
            for elevation in stride(from: 5.0, through: 85.0, by: 11.0) {
                let direction = DebugOverlaySunAngles.direction(azimuthDegrees: azimuth,
                                                                elevationDegrees: elevation)
                let angles = DebugOverlaySunAngles.angles(direction: direction)
                XCTAssertEqual(angles.azimuthDegrees, azimuth, accuracy: 1e-3,
                               "azimuth \(azimuth) elevation \(elevation)")
                XCTAssertEqual(angles.elevationDegrees, elevation, accuracy: 1e-3,
                               "azimuth \(azimuth) elevation \(elevation)")
            }
        }
    }

    /// The shipping default light must read back as a sun in the south-west,
    /// which is what every shadow in the example apps is aimed by.
    func testDefaultLightReadsAsASouthWesternSun() {
        let angles = DebugOverlaySunAngles.angles(
            direction: ImmersiveMapSettings.SceneLightSettings().direction)

        XCTAssertGreaterThan(angles.azimuthDegrees, 180)
        XCTAssertLessThan(angles.azimuthDegrees, 270)
        XCTAssertEqual(angles.elevationDegrees, 54.2, accuracy: 0.5)
    }

    /// A degenerate direction must not travel into a slider as a NaN.
    func testDegenerateDirectionReadsAsOverhead() {
        let angles = DebugOverlaySunAngles.angles(direction: .zero)

        XCTAssertEqual(angles.azimuthDegrees, 0)
        XCTAssertEqual(angles.elevationDegrees, 90)
    }

    func testUnnormalizedDirectionReadsTheSameAsItsNormal() {
        let direction = SIMD3<Float>(-0.4, -0.6, 1.0)
        let scaled = direction * 37

        let angles = DebugOverlaySunAngles.angles(direction: direction)
        let scaledAngles = DebugOverlaySunAngles.angles(direction: scaled)

        XCTAssertEqual(angles.azimuthDegrees, scaledAngles.azimuthDegrees, accuracy: 1e-3)
        XCTAssertEqual(angles.elevationDegrees, scaledAngles.elevationDegrees, accuracy: 1e-3)
    }

    // MARK: - The map-size ladder

    func testEveryLadderStepSelectsItself() {
        for (index, resolution) in DebugOverlayShadowSettingsPlanner.mapResolutions.enumerated() {
            XCTAssertEqual(DebugOverlayShadowSettingsPlanner.mapResolutionIndex(for: resolution), index)
            XCTAssertEqual(DebugOverlayShadowSettingsPlanner.mapResolution(atIndex: index), resolution)
        }
    }

    /// A resolution set in code need not be on the ladder; the segment then
    /// shows the nearest step rather than falling back to the first one.
    func testOffLadderResolutionSelectsTheNearestStep() {
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.mapResolutionIndex(for: 1000), 1)
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.mapResolutionIndex(for: 1900), 2)
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.mapResolutionIndex(for: 100), 0)
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.mapResolutionIndex(for: 99_999), 3)
    }

    func testOutOfBoundsSegmentFallsBackToTheFirstStep() {
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.mapResolution(atIndex: -1), 512)
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.mapResolution(atIndex: 99), 512)
    }

    /// The ladder must stay inside what the resolver accepts, or a segment
    /// would silently clamp and the panel would show a size the map is not
    /// rendering at.
    func testTheLadderStaysInsideTheResolverRange() {
        for resolution in DebugOverlayShadowSettingsPlanner.mapResolutions {
            XCTAssertTrue(ShadowFrameStateResolver.mapResolutionRange.contains(resolution),
                          "\(resolution) is outside the resolver's clamp")
        }
    }

    /// The default the package ships must be a step on the ladder, so opening
    /// the panel does not itself change the map.
    func testTheShippingDefaultIsOnTheLadder() {
        let defaultResolution = ImmersiveMapSettings.ShadowSettings().mapResolution
        let index = DebugOverlayShadowSettingsPlanner.mapResolutionIndex(for: defaultResolution)

        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.mapResolution(atIndex: index), defaultResolution)
    }

    func testCoverageSliderCoversTheShippingDefault() {
        let defaultCoverage = Double(ImmersiveMapSettings.ShadowSettings().coverageCameraDistances)

        XCTAssertTrue(DebugOverlayShadowSettingsPlanner.coverageRange.contains(defaultCoverage))
    }

    /// The slider reaches the resolver's floor, which is what makes winding
    /// the window right down possible from the panel.
    func testCoverageSliderReachesTheResolverFloor() {
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.coverageRange.lowerBound,
                       Double(ShadowFrameStateResolver.coverageRange.lowerBound))
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.coverageRange.lowerBound, 0.25)
        XCTAssertLessThanOrEqual(DebugOverlayShadowSettingsPlanner.coverageRange.upperBound,
                                 Double(ShadowFrameStateResolver.coverageRange.upperBound))
    }

    /// The elevation slider must not reach the angle at which the resolver
    /// drops shadows: a slider whose end silently turns the feature off reads
    /// as a bug rather than as a setting.
    func testElevationSliderStaysAboveTheResolverCutoff() {
        let lowest = DebugOverlaySunAngles.direction(
            azimuthDegrees: 0,
            elevationDegrees: DebugOverlayShadowSettingsPlanner.elevationRange.lowerBound)

        XCTAssertGreaterThan(lowest.z, ShadowFrameStateResolver.minimumLightDirectionZ)
    }

    /// The slider must reach every value the setting accepts and none it does
    /// not, or it reports a number the renderer is not using.
    func testTheNormalOffsetSliderMatchesTheResolverClamp() {
        let range = ShadowFrameStateResolver.normalOffsetTexelsRange

        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.normalOffsetRange.lowerBound,
                       Double(range.lowerBound))
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.normalOffsetRange.upperBound,
                       Double(range.upperBound))
        XCTAssertTrue(DebugOverlayShadowSettingsPlanner.normalOffsetRange
            .contains(Double(ImmersiveMapSettings.ShadowSettings().normalOffsetTexels)))
    }

    func testTheCasterHeightSliderMatchesTheResolverClamp() {
        let range = ShadowFrameStateResolver.maxCasterHeightRange

        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.casterHeightRange.lowerBound,
                       Double(range.lowerBound))
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.casterHeightRange.upperBound,
                       Double(range.upperBound))
        XCTAssertTrue(DebugOverlayShadowSettingsPlanner.casterHeightRange
            .contains(Double(ImmersiveMapSettings.ShadowSettings().maxCasterHeightMeters)))
    }

    func testTheSoftnessSliderMatchesTheResolverClamp() {
        let range = ShadowFrameStateResolver.softnessRange

        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.softnessRange.lowerBound,
                       Double(range.lowerBound))
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.softnessRange.upperBound,
                       Double(range.upperBound))
        XCTAssertTrue(DebugOverlayShadowSettingsPlanner.softnessRange
            .contains(Double(ImmersiveMapSettings.ShadowSettings().softness)))
    }

    func testTitlesCarryTheValue() {
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.strengthTitle(0.22), "Strength 0.22")
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.coverageTitle(3), "Coverage 3.0x")
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.normalOffsetTitle(2.5), "Normal offset 2.5tx")
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.casterHeightTitle(50), "Caster height 50 m")
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.softnessTitle(1.75), "Softness 1.75x")
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.azimuthTitle(213.7), "Sun azimuth 214°")
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.elevationTitle(54.2), "Sun elevation 54°")
    }
}

/// The panel's live edits have to survive SwiftUI handing the map its own
/// settings value again, which is what `updateNSView` does on every
/// re-evaluation of the hierarchy.
final class DebugOverlaySettingsOverrideTests: XCTestCase {
    private func settingsWithDebugPanel(_ isEnabled: Bool) -> ImmersiveMapSettings {
        var settings = ImmersiveMapSettings.default
        settings.debug.enableDebugPanel = isEnabled
        return settings
    }

    func testAnEmptyOverrideChangesNothing() {
        let settings = settingsWithDebugPanel(true)

        XCTAssertEqual(DebugOverlaySettingsOverride().applied(to: settings), settings)
    }

    func testTheOverrideSurvivesTheAppResendingItsOwnSettings() {
        var override = DebugOverlaySettingsOverride()
        var dragged = ImmersiveMapSettings.ShadowSettings()
        dragged.strength = 0.71
        dragged.coverageCameraDistances = 8
        override.shadows = dragged
        override.sunDirection = DebugOverlaySunAngles.direction(azimuthDegrees: 30, elevationDegrees: 20)

        // The app's own value, which SwiftUI re-sends unchanged.
        let resent = settingsWithDebugPanel(true)
        let applied = override.applied(to: resent)

        XCTAssertEqual(applied.scene.shadows.strength, 0.71)
        XCTAssertEqual(applied.scene.shadows.coverageCameraDistances, 8)
        XCTAssertEqual(DebugOverlaySunAngles.angles(direction: applied.scene.light.direction).azimuthDegrees,
                       30,
                       accuracy: 1e-3)
        // Nothing outside the branches the panel edits may move.
        XCTAssertEqual(applied.tiles, resent.tiles)
        XCTAssertEqual(applied.camera, resent.camera)
        XCTAssertEqual(applied.scene.atmosphere, resent.scene.atmosphere)
        XCTAssertEqual(applied.scene.fog, resent.scene.fog)
    }

    func testTheAtmosphereOverrideRidesOnTopLikeTheOthers() {
        var override = DebugOverlaySettingsOverride()
        var dragged = ImmersiveMapSettings.AtmosphereSettings()
        dragged.intensity = 1.6
        dragged.thickness = 0.5
        override.atmosphere = dragged
        let resent = settingsWithDebugPanel(true)

        let applied = override.applied(to: resent)

        XCTAssertEqual(applied.scene.atmosphere, dragged)
        XCTAssertEqual(applied.scene.fog, resent.scene.fog)
        XCTAssertEqual(applied.scene.shadows, resent.scene.shadows)
        XCTAssertFalse(override.isEmpty)
        override.clear()
        XCTAssertNil(override.atmosphere)
    }

    func testTheFogOverrideRidesOnTopLikeTheShadows() {
        var override = DebugOverlaySettingsOverride()
        var dragged = ImmersiveMapSettings.FogSettings()
        dragged.horizonColor = SIMD3<Float>(0.9, 0.8, 0.7)
        dragged.skyColor = SIMD3<Float>(0.1, 0.2, 0.9)
        override.fog = dragged
        let resent = settingsWithDebugPanel(true)

        let applied = override.applied(to: resent)

        XCTAssertEqual(applied.scene.fog, dragged)
        XCTAssertEqual(applied.scene.shadows, resent.scene.shadows)
        XCTAssertEqual(applied.scene.light, resent.scene.light)
        XCTAssertFalse(override.isEmpty)
        override.clear()
        XCTAssertNil(override.fog)
    }

    func testOneBranchOverriddenLeavesTheOtherAlone() {
        var override = DebugOverlaySettingsOverride()
        override.sunDirection = DebugOverlaySunAngles.direction(azimuthDegrees: 90, elevationDegrees: 45)
        let settings = settingsWithDebugPanel(true)

        let applied = override.applied(to: settings)

        XCTAssertEqual(applied.scene.shadows, settings.scene.shadows)
        XCTAssertNotEqual(applied.scene.light.direction, settings.scene.light.direction)
    }

    /// With the panel off the app is back in charge, whatever was dragged
    /// while it was open.
    func testTheOverrideDoesNotApplyWithTheDebugPanelOff() {
        var override = DebugOverlaySettingsOverride()
        override.shadows = ImmersiveMapSettings.ShadowSettings(isEnabled: false)
        let settings = settingsWithDebugPanel(false)

        XCTAssertEqual(override.applied(to: settings), settings)
    }

    func testClearingDropsEverything() {
        var override = DebugOverlaySettingsOverride()
        override.shadows = ImmersiveMapSettings.ShadowSettings()
        override.sunDirection = SIMD3<Float>(0, 0, 1)
        XCTAssertFalse(override.isEmpty)

        override.clear()

        XCTAssertTrue(override.isEmpty)
        let settings = settingsWithDebugPanel(true)
        XCTAssertEqual(override.applied(to: settings), settings)
    }
}

/// The debug panel's ground fog group: graphs whose axes cover every stop of
/// the shipping curves, and titles that carry the value at the camera's zoom.
final class DebugOverlayGroundFogGroupTests: XCTestCase {
    private typealias Planner = DebugOverlayGroundFogSettingsPlanner

    func testTheGraphsCoverTheShippingDefault() {
        let fog = ImmersiveMapSettings.GroundFogSettings()
        for (curve, axes) in [(fog.densityPerKilometer, Planner.densityAxes), (fog.heightMeters, Planner.heightAxes),
                              (fog.startDistanceMeters, Planner.startDistanceAxes),
                              (fog.startSoftnessMeters, Planner.startSoftnessAxes),
                              (fog.maximumOpacity, Planner.maximumOpacityAxes)] {
            for stop in curve.stops {
                XCTAssertTrue(axes.valueRange.contains(Double(stop.value)), "\(stop.value) outside \(axes.valueRange)")
                XCTAssertTrue(axes.zoomRange.contains(stop.zoom), "\(stop.zoom) outside \(axes.zoomRange)")
            }
        }
    }

    func testTitlesCarryTheValueAtTheCameraZoom() {
        XCTAssertEqual(Planner.densityTitle(0.45, cameraZoom: 12), "Density 0.45/km")
        XCTAssertEqual(Planner.startDistanceTitle(400, cameraZoom: 12), "From 400 m")
        XCTAssertEqual(Planner.startDistanceTitle([12: 3200, 16: 200], cameraZoom: 13), "From 1.6 km",
                       "Geometric between the stops, as the fog reads it")
        XCTAssertEqual(Planner.heightTitle([13: 4000, 15: 150], cameraZoom: 16), "Height 150 m")
        XCTAssertEqual(Planner.startSoftnessTitle(25_000, cameraZoom: 12), "Soft start 25 km")
        XCTAssertEqual(Planner.maximumOpacityTitle([18: 1, 19: 0], cameraZoom: 15), "Max opacity 1.00")
    }
}

/// The zoom curve graph's axes and the edits a pointer makes on it.
final class DebugOverlayZoomCurveEditingTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 220, height: 100)
    private let axes = DebugOverlayZoomCurveAxes(zoomRange: 0...22, valueRange: 0...1)

    /// Zoom runs left to right, the value bottom to top, and a point maps
    /// back onto the half zoom grid and the hundredths.
    func testTheAxesRoundTripOnTheGrid() {
        XCTAssertEqual(axes.x(zoom: 11, in: rect), 110)
        XCTAssertEqual(axes.y(value: 0, in: rect), 100)
        XCTAssertEqual(axes.y(value: 1, in: rect), 0)
        XCTAssertEqual(axes.zoom(x: 112, in: rect), 11, "11.2 snaps to the half zoom grid")
        XCTAssertEqual(axes.zoom(x: 116, in: rect), 11.5)
        XCTAssertEqual(axes.zoom(x: -40, in: rect), 0, "Clamped to the range")
        XCTAssertEqual(axes.value(y: 25.3, in: rect), 0.75, accuracy: 1e-9)
        XCTAssertEqual(axes.value(y: 400, in: rect), 0, "Clamped to the range")
    }

    /// A logarithmic axis puts each decade at the same height.
    func testALogarithmicAxisSpacesDecadesEvenly() {
        let log = DebugOverlayZoomCurveAxes(zoomRange: 0...22, valueRange: 0.01...1, isLogarithmic: true)
        XCTAssertEqual(log.y(value: 0.1, in: rect), 50, accuracy: 1e-6)
        XCTAssertEqual(log.value(y: 50, in: rect), 0.1, accuracy: 1e-9)
    }

    func testAStopIsFoundNearThePointer() {
        let curve: ImmersiveMapZoomCurve = [11: 0.5, 13: 1]
        let near = CGPoint(x: 112, y: 52)
        XCTAssertEqual(DebugOverlayZoomCurveEditing.stopIndex(at: near, curve: curve, axes: axes, rect: rect, radius: 8), 0)
        XCTAssertNil(DebugOverlayZoomCurveEditing.stopIndex(at: CGPoint(x: 60, y: 50), curve: curve, axes: axes,
                                                            rect: rect, radius: 8))
    }

    /// A click adds a stop, or sets the value of the stop already at that
    /// zoom.
    func testSettingAStopAddsOrReplaces() {
        let curve: ImmersiveMapZoomCurve = [11: 0.5, 13: 1]
        let added = DebugOverlayZoomCurveEditing.settingStop(curve, zoom: 12, value: 0.2)
        XCTAssertEqual(added.curve, [11: 0.5, 12: 0.2, 13: 1])
        XCTAssertEqual(added.index, 1)
        let replaced = DebugOverlayZoomCurveEditing.settingStop(curve, zoom: 13, value: 0.3)
        XCTAssertEqual(replaced.curve, [11: 0.5, 13: 0.3])
    }

    /// A dragged stop moves, its index following it. Dropped onto another
    /// stop's zoom it keeps its own zoom and takes only the value.
    func testMovingAStopNeverSwallowsANeighbour() {
        let curve: ImmersiveMapZoomCurve = [11: 0.5, 13: 1]
        let moved = DebugOverlayZoomCurveEditing.movingStop(curve, at: 0, toZoom: 14, value: 0.4)
        XCTAssertEqual(moved.curve, [13: 1, 14: 0.4])
        XCTAssertEqual(moved.index, 1)
        let blocked = DebugOverlayZoomCurveEditing.movingStop(curve, at: 0, toZoom: 13, value: 0.4)
        XCTAssertEqual(blocked.curve, [11: 0.4, 13: 1])
    }

    func testTheLastStopStays() {
        let curve: ImmersiveMapZoomCurve = [11: 0.5, 13: 1]
        XCTAssertEqual(DebugOverlayZoomCurveEditing.removingStop(curve, at: 0), [13: 1])
        XCTAssertNil(DebugOverlayZoomCurveEditing.removingStop([13: 1], at: 0))
    }
}

/// The debug panel's tabs.
final class DebugOverlayPanelCategoryTests: XCTestCase {
    func testAllShowsEveryCategoryAndATabOnlyItsOwn() {
        for category in DebugOverlayPanelCategory.allCases {
            XCTAssertTrue(DebugOverlayPanelCategory.all.shows(category))
        }
        XCTAssertTrue(DebugOverlayPanelCategory.sky.shows(.sky))
        XCTAssertFalse(DebugOverlayPanelCategory.sky.shows(.tiles))
    }
}

/// The Export tab's file: the tuned values as the modifiers that set them.
final class DebugOverlaySettingsExportTests: XCTestCase {
    func testNumbersCarryOnlyTheirDecimals() {
        XCTAssertEqual(DebugOverlaySettingsExport.number(0.3), "0.3")
        XCTAssertEqual(DebugOverlaySettingsExport.number(3), "3")
        XCTAssertEqual(DebugOverlaySettingsExport.number(0.03), "0.03")
        XCTAssertEqual(DebugOverlaySettingsExport.number(-0.4), "-0.4")
    }

    func testACurveIsWrittenAsItsLiteral() {
        XCTAssertEqual(DebugOverlaySettingsExport.curve(1.7), "1.7")
        XCTAssertEqual(DebugOverlaySettingsExport.curve([8: 0, 12: 3]), "[8: 0, 12: 3]")
        XCTAssertEqual(DebugOverlaySettingsExport.curve([12: 5, 16.5: 0.03]), "[12: 5, 16.5: 0.03]")
    }

    func testAZoomFadeIsWrittenAsItsFactory() {
        XCTAssertEqual(DebugOverlaySettingsExport.zoomFade(.none), ".none")
        XCTAssertEqual(DebugOverlaySettingsExport.zoomFade(.fadeOut(from: 17, to: 18)), ".fadeOut(from: 17, to: 18)")
        XCTAssertEqual(DebugOverlaySettingsExport.zoomFade(.fadeIn(from: 3, to: 4)), ".fadeIn(from: 3, to: 4)")
    }

    func testTheGroundFogIsWrittenWithItsCurves() {
        let settings = FixtureTiles.tilelessSettings().groundFog(densityPerKilometer: [12: 0.45, 16: 17],
                                                                 startDistanceMeters: 400)
        let code = DebugOverlaySettingsExport.swiftCode(settings: settings,
                                                        date: Date(timeIntervalSince1970: 0),
                                                        cameraLines: ["Zoom 12.3"])
        XCTAssertTrue(code.contains("// Zoom 12.3"))
        XCTAssertTrue(code.contains("ImmersiveMapView()"))
        XCTAssertTrue(code.contains(".groundFog(isEnabled: true, densityPerKilometer: [12: 0.45, 16: 17], heightMeters: "),
                      code)
        XCTAssertTrue(code.contains("startDistanceMeters: 400"), code)
        XCTAssertFalse(code.contains("http"), "No tile address, and so no request header, is written")
    }
}

/// The arithmetic behind the debug panel's atmosphere group: ranges that
/// cover the shipping defaults, and titles that carry the value.
final class DebugOverlayAtmosphereGroupTests: XCTestCase {
    func testTheSlidersCoverTheShippingDefault() {
        let atmosphere = ImmersiveMapSettings.AtmosphereSettings()
        XCTAssertTrue(DebugOverlayAtmosphereSettingsPlanner.intensityRange.contains(Double(atmosphere.intensity)))
        XCTAssertTrue(DebugOverlayAtmosphereSettingsPlanner.thicknessRange.contains(Double(atmosphere.thickness)))
        XCTAssertTrue(DebugOverlayAtmosphereSettingsPlanner.sunInfluenceRange.contains(Double(atmosphere.sunInfluence)))
    }

    func testTitlesCarryTheValue() {
        XCTAssertEqual(DebugOverlayAtmosphereSettingsPlanner.intensityTitle(1), "Intensity 1.00")
        XCTAssertEqual(DebugOverlayAtmosphereSettingsPlanner.thicknessTitle(2), "Thickness 2.00x")
        XCTAssertEqual(DebugOverlayAtmosphereSettingsPlanner.sunInfluenceTitle(0.6), "Sun influence 0.60")
    }
}
