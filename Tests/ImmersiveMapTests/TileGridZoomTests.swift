// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Which zoom's tiles the tile grid shows at a camera zoom, and when it
/// hides.
final class TileGridZoomTests: XCTestCase {
    private func settings(_ range: ClosedRange<Int>,
                          minimum: Float = 48,
                          labelMinimum: Float = 96) -> ImmersiveMapSettings.TileGridSettings {
        ImmersiveMapSettings.TileGridSettings(zoomRange: range,
                                              minimumTileScreenPoints: minimum,
                                              labelMinimumTileScreenPoints: labelMinimum)
    }

    func testTheGridFollowsTheCameraInsideTheRange() {
        let settings = settings(12 ... 15)
        XCTAssertEqual(TileGridZoom.resolve(cameraZoom: 13.7, baseTileScreenPoints: 400, settings: settings)?.zoom, 13)
        XCTAssertEqual(TileGridZoom.resolve(cameraZoom: 18.2, baseTileScreenPoints: 400, settings: settings)?.zoom, 15)
        XCTAssertEqual(TileGridZoom.resolve(cameraZoom: 11.5, baseTileScreenPoints: 400, settings: settings)?.zoom, 12)
    }

    func testARangeOfOneZoomShowsThatZoomAlone() {
        let settings = settings(15 ... 15)
        for cameraZoom in [13.0, 15.0, 15.9, 19.0] {
            XCTAssertEqual(TileGridZoom.resolve(cameraZoom: cameraZoom, baseTileScreenPoints: 400, settings: settings)?.zoom,
                           15)
        }
    }

    func testATileSpansTwiceAsMuchForEveryZoomTheCameraIsDeeper() throws {
        let settings = settings(15 ... 15)
        let level = try XCTUnwrap(TileGridZoom.resolve(cameraZoom: 15, baseTileScreenPoints: 400, settings: settings))
        let deeper = try XCTUnwrap(TileGridZoom.resolve(cameraZoom: 17, baseTileScreenPoints: 400, settings: settings))
        XCTAssertEqual(level.tileScreenPoints, 400, accuracy: 1e-9)
        XCTAssertEqual(deeper.tileScreenPoints, 1600, accuracy: 1e-9)
    }

    func testTheGridHidesWhileItsTilesAreTooSmall() {
        let settings = settings(15 ... 15, minimum: 50, labelMinimum: 100)
        // 400 points at zoom 15: 100 at 13, 50 at 12, 25 at 11.
        XCTAssertNil(TileGridZoom.resolve(cameraZoom: 11, baseTileScreenPoints: 400, settings: settings))
        XCTAssertEqual(TileGridZoom.resolve(cameraZoom: 12, baseTileScreenPoints: 400, settings: settings)?.drawsLabels,
                       false, "Shown, its texts too small to read")
        XCTAssertEqual(TileGridZoom.resolve(cameraZoom: 13, baseTileScreenPoints: 400, settings: settings)?.drawsLabels,
                       true)
        XCTAssertNil(TileGridZoom.resolve(cameraZoom: 15, baseTileScreenPoints: 0, settings: settings))
        XCTAssertNil(TileGridZoom.resolve(cameraZoom: .nan, baseTileScreenPoints: 400, settings: settings))
    }
}
