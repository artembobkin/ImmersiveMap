// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class EarthSceneSettingsTests: XCTestCase {
    func testDefaultEarthSceneIsEnabledWithRealtimeSunAndNightLights() {
        let earth = ImmersiveMapSettings.default.scene.earth

        XCTAssertTrue(earth.isEnabled)
        XCTAssertEqual(earth.timeMode, .realtime)
        XCTAssertEqual(earth.daySideMinimumBrightness, 0.82, accuracy: 0.0001)
        XCTAssertEqual(earth.nightSideBrightness, 0.18, accuracy: 0.0001)
        XCTAssertEqual(earth.terminatorFadeWidth, 0.12, accuracy: 0.0001)
        XCTAssertTrue(earth.nightLights.isEnabled)
        XCTAssertEqual(earth.nightLights.intensity, 1.0, accuracy: 0.0001)
        XCTAssertEqual(earth.nightLights.terminatorFadeWidth, 0.18, accuracy: 0.0001)
        XCTAssertTrue(earth.sun.isEnabled)
        XCTAssertEqual(earth.sun.diskAngularSize, 0.075, accuracy: 0.0001)
        XCTAssertEqual(earth.sun.diskIntensity, 1.0, accuracy: 0.0001)
        XCTAssertEqual(earth.sun.glowIntensity, 0.75, accuracy: 0.0001)
        XCTAssertEqual(earth.sun.edgeGlareIntensity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(earth.sun.limbHaloIntensity, 0.35, accuracy: 0.0001)
        XCTAssertEqual(earth.sun.limbHaloWidth, 0.10, accuracy: 0.0001)
    }

    func testEarthSceneEnabledControlsFullSunTerminatorAndNightLightsPackage() {
        let settings = ImmersiveMapSettings.EarthSceneSettings(
            isEnabled: false,
            nightLights: .init(isEnabled: true, intensity: 1.0),
            sun: .init(isEnabled: true, diskIntensity: 1.0, glowIntensity: 1.0)
        )

        XCTAssertFalse(settings.isEnabled)
        XCTAssertTrue(settings.nightLights.isEnabled)
        XCTAssertTrue(settings.sun.isEnabled)
    }

    func testFixedTimeModeStoresDate() throws {
        let date = try Date.utc(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5)
        let settings = ImmersiveMapSettings.EarthSceneSettings(timeMode: .fixed(date))

        XCTAssertEqual(settings.timeMode, .fixed(date))
    }
}

private extension Date {
    static func utc(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) throws -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return try XCTUnwrap(components.date)
    }
}
