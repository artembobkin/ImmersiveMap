// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMap
import XCTest

final class ImmersiveMapCityTests: XCTestCase {
    /// Every city has a name of its own and a coordinate on the map.
    func testEveryCityHasANameAndACoordinate() {
        XCTAssertEqual(Set(ImmersiveMapCity.allCases.map(\.name)).count, ImmersiveMapCity.allCases.count)
        for city in ImmersiveMapCity.allCases {
            XCTAssertFalse(city.name.isEmpty, city.rawValue)
            XCTAssertTrue((-85.0 ... 85.0).contains(city.coordinate.latitude), city.rawValue)
            XCTAssertTrue((-180.0 ... 180.0).contains(city.coordinate.longitude), city.rawValue)
        }
    }

    /// No two cities share a place: a pasted row would.
    func testNoTwoCitiesShareACoordinate() {
        XCTAssertEqual(Set(ImmersiveMapCity.allCases.map(\.coordinate)).count, ImmersiveMapCity.allCases.count)
    }

    func testACitysCameraPositionIsOverItsCentre() {
        let position = ImmersiveMapCameraPosition.city(.paris)
        XCTAssertEqual(position.latitudeDegrees, ImmersiveMapCity.paris.coordinate.latitude)
        XCTAssertEqual(position.longitudeDegrees, ImmersiveMapCity.paris.coordinate.longitude)
        XCTAssertEqual(position.zoom, ImmersiveMapCameraPosition.cityZoom)
        XCTAssertEqual(position.bearing, 0)
        XCTAssertEqual(position.pitch, 0)

        let tilted = ImmersiveMapCameraPosition.city(.tokyo, zoom: 13, bearing: 0.5, pitch: 1)
        XCTAssertEqual(tilted.zoom, 13)
        XCTAssertEqual(tilted.bearing, 0.5)
        XCTAssertEqual(tilted.pitch, 1)
    }
}
