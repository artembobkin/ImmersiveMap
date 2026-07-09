// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class EarthSceneSunCalculatorTests: XCTestCase {
    func testMarchEquinoxNoonPlacesSunNearGreenwichEquator() throws {
        let date = try Date.utc(year: 2026, month: 3, day: 20, hour: 12, minute: 0, second: 0)

        let position = EarthSceneSunCalculator.subsolarPoint(at: date)

        XCTAssertEqual(position.latitudeDegrees, 0.0, accuracy: 1.2)
        XCTAssertEqual(position.longitudeDegrees, 0.0, accuracy: 5.0)
    }

    func testJuneSolsticePlacesSunNearTropicOfCancer() throws {
        let date = try Date.utc(year: 2026, month: 6, day: 21, hour: 12, minute: 0, second: 0)

        let position = EarthSceneSunCalculator.subsolarPoint(at: date)

        XCTAssertEqual(position.latitudeDegrees, 23.44, accuracy: 1.2)
    }

    func testSubsolarVectorIsUnitLength() throws {
        let date = try Date.utc(year: 2026, month: 6, day: 9, hour: 9, minute: 0, second: 0)

        let direction = EarthSceneSunCalculator.earthFixedSunDirection(at: date)

        XCTAssertEqual(simd_length(direction), 1.0, accuracy: 0.0001)
    }

    func testEarthFixedDirectionUsesGlobeBasis() {
        let greenwichEquator = EarthSceneSunCalculator.earthFixedDirection(latitudeDegrees: 0.0, longitudeDegrees: 0.0)
        let eastEquator = EarthSceneSunCalculator.earthFixedDirection(latitudeDegrees: 0.0, longitudeDegrees: 90.0)

        XCTAssertEqual(greenwichEquator.x, 0.0, accuracy: 0.0001)
        XCTAssertEqual(greenwichEquator.y, 0.0, accuracy: 0.0001)
        XCTAssertEqual(greenwichEquator.z, 1.0, accuracy: 0.0001)
        XCTAssertEqual(eastEquator.x, 1.0, accuracy: 0.0001)
        XCTAssertEqual(eastEquator.y, 0.0, accuracy: 0.0001)
        XCTAssertEqual(eastEquator.z, 0.0, accuracy: 0.0001)
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
