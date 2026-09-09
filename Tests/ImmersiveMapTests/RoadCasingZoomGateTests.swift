// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The road casing draws from street zoom up only.
final class RoadCasingZoomGateTests: XCTestCase {
    func testTheCasingDrawsFromStreetZoomUp() {
        XCTAssertEqual(RoadCasingZoomGate.minimumZoom, 16)
        XCTAssertTrue(RoadCasingZoomGate.drawsCasing(cameraZoom: 16))
        XCTAssertTrue(RoadCasingZoomGate.drawsCasing(cameraZoom: 17.3))
        XCTAssertFalse(RoadCasingZoomGate.drawsCasing(cameraZoom: 15.99))
        XCTAssertFalse(RoadCasingZoomGate.drawsCasing(cameraZoom: 12))
    }
}
