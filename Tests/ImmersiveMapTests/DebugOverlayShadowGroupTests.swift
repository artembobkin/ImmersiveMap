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

    func testTitlesCarryTheValue() {
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.strengthTitle(0.22), "Strength 0.22")
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.coverageTitle(3), "Coverage 3.0x")
        XCTAssertEqual(DebugOverlayShadowSettingsPlanner.normalOffsetTitle(2.5), "Normal offset 2.5tx")
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
        // Nothing outside the two branches the panel edits may move.
        XCTAssertEqual(applied.tiles, resent.tiles)
        XCTAssertEqual(applied.camera, resent.camera)
        XCTAssertEqual(applied.scene.atmosphere, resent.scene.atmosphere)
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
